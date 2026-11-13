#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any


def selected_toolchain_app() -> Path:
    """Return the Xcode that DEVELOPER_DIR or xcode-select selects.

    Falls back to the default install location when the selection is not inside
    an Xcode app, as with the standalone Command Line Tools.
    """
    result = subprocess.run(
        ["xcode-select", "-p"], capture_output=True, text=True, check=False
    )
    developer_dir = result.stdout.strip()
    if result.returncode == 0 and developer_dir:
        app = Path(developer_dir).parents[1]
        if app.suffix == ".app":
            return app
    return Path("/Applications/Xcode.app")


DEFAULT_TOOLCHAIN_APP = selected_toolchain_app()
SOURCE_MODEL_RESOURCE_SUFFIX = Path(
    "Contents/SharedFrameworks/SourceModel.framework/Versions/A/Resources"
)
LANGUAGE_SPEC_DIRNAME = "LanguageSpecifications"
LANGUAGE_METADATA_DIRNAME = "LanguageMetadata"
SUPPORTED_LANGUAGE_IDENTIFIERS = {
    "Xcode.SourceCodeLanguage.ARM-Assembly",
    "Xcode.SourceCodeLanguage.CSS",
    "Xcode.SourceCodeLanguage.HTML",
    "Xcode.SourceCodeLanguage.JavaScript",
    "Xcode.SourceCodeLanguage.JSON",
    "Xcode.SourceCodeLanguage.Objective-C",
    "Xcode.SourceCodeLanguage.Swift",
    "Xcode.SourceCodeLanguage.TOML_INI",
    "Xcode.SourceCodeLanguage.XML",
}


REFERENCE_KEYS = {
    "BasedOn",
    "Tokenizer",
    "IncludeRules",
    "Rules",
    "Start",
    "End",
    "Until",
    "AltUntil",
    "AltEnd",
    "AltToken",
    "EntityNameMap",
}


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Extract all xclangspec definitions into a normalized JSON snapshot."
    )
    parser.add_argument(
        "--xcode",
        default=str(DEFAULT_TOOLCHAIN_APP),
        help="Path to the local developer tool app bundle.",
    )
    parser.add_argument(
        "--spec-dir",
        help="Override LanguageSpecifications directory.",
    )
    parser.add_argument(
        "--metadata-dir",
        help="Override LanguageMetadata directory.",
    )
    parser.add_argument(
        "--language",
        action="append",
        default=[],
        help=(
            "Limit derived language closures. Accepts source language identifier, "
            "language name, or language specification identifier. May be repeated."
        ),
    )
    parser.add_argument(
        "--all-languages",
        action="store_true",
        help="Include every source language metadata entry instead of SyntaxEditorUI-supported languages.",
    )
    parser.add_argument(
        "--pretty",
        action="store_true",
        help="Pretty-print JSON output.",
    )
    return parser.parse_args()


def load_plist(path: Path) -> Any:
    result = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(path)],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return json.loads(result.stdout)


def default_resource_root(toolchain_app: Path) -> Path:
    return toolchain_app / SOURCE_MODEL_RESOURCE_SUFFIX


def language_matches(metadata: dict[str, Any], filters: set[str]) -> bool:
    if not filters:
        return True
    values = {
        str(metadata.get("identifier", "")).lower(),
        str(metadata.get("languageName", "")).lower(),
        str(metadata.get("languageSpecification", "")).lower(),
    }
    values.update(str(ext).lower() for ext in metadata.get("fileExtensions", []) or [])
    return bool(values.intersection(filters))


def as_list(value: Any) -> list[Any]:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


def reference_values(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        refs: list[str] = []
        for item in value:
            refs.extend(reference_values(item))
        return refs
    if isinstance(value, dict):
        refs = []
        for nested in value.values():
            refs.extend(reference_values(nested))
        return refs
    return []


def identifiers_in_rule_expression(expression: str, rule_index: dict[str, dict[str, Any]]) -> list[str]:
    if expression in rule_index:
        return [expression]

    identifiers: list[str] = []
    seen: set[str] = set()
    current: list[str] = []

    def flush() -> None:
        if not current:
            return
        identifier = "".join(current)
        current.clear()
        if identifier in rule_index and identifier not in seen:
            seen.add(identifier)
            identifiers.append(identifier)

    for character in expression:
        if character.isascii() and (character.isalnum() or character in ".-_"):
            current.append(character)
        else:
            flush()
    flush()

    return identifiers


def append_reference_expressions(
    references: list[str],
    expressions: list[str],
    rule_index: dict[str, dict[str, Any]],
) -> None:
    seen = set(references)
    for expression in expressions:
        for identifier in identifiers_in_rule_expression(expression, rule_index):
            if identifier in seen:
                continue
            seen.add(identifier)
            references.append(identifier)


def rule_entry(rule_record: dict[str, Any]) -> dict[str, Any]:
    entry = rule_record.get("entry")
    return entry if isinstance(entry, dict) else rule_record


def direct_rule_references(rule_record: dict[str, Any], rule_index: dict[str, dict[str, Any]]) -> list[str]:
    references: list[str] = []
    rule = rule_entry(rule_record)

    for key in ("BasedOn",):
        append_reference_expressions(references, reference_values(rule.get(key)), rule_index)

    syntax = rule.get("Syntax")
    if not isinstance(syntax, dict):
        return references

    for key in REFERENCE_KEYS:
        if key not in syntax:
            continue
        append_reference_expressions(references, reference_values(syntax.get(key)), rule_index)

    language_embeddings = syntax.get("LanguageEmbeddings")
    if isinstance(language_embeddings, dict):
        append_reference_expressions(references, sorted(map(str, language_embeddings.keys())), rule_index)

    return references


def collect_rule_closure(root_identifier: str, rule_index: dict[str, dict[str, Any]]) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []
    stack = [root_identifier]

    while stack:
        identifier = stack.pop()
        if identifier in seen:
            continue
        rule = rule_index.get(identifier)
        if rule is None:
            continue
        seen.add(identifier)
        ordered.append(identifier)
        for reference in reversed(direct_rule_references(rule, rule_index)):
            if reference not in seen:
                stack.append(reference)

    return ordered


def syntax_types_for_rules(rule_identifiers: list[str], rule_index: dict[str, dict[str, Any]]) -> list[str]:
    syntax_types: set[str] = set()
    for identifier in rule_identifiers:
        syntax = rule_entry(rule_index[identifier]).get("Syntax", {})
        if not isinstance(syntax, dict):
            continue
        for key in ("Type", "AltType"):
            value = syntax.get(key)
            if isinstance(value, str) and value.startswith("xcode.syntax."):
                syntax_types.add(value)
        for value in as_list(syntax.get("CaptureTypes")):
            if isinstance(value, str) and value.startswith("xcode.syntax."):
                syntax_types.add(value)
    return sorted(syntax_types)


def specification_files(spec_dir: Path) -> list[Path]:
    return sorted(spec_dir.glob("*.xclangspec")) + sorted(spec_dir.glob("*.xcsynspec"))


def build_snapshot(args: argparse.Namespace) -> dict[str, Any]:
    toolchain_app = Path(args.xcode).expanduser()
    resource_root = default_resource_root(toolchain_app)
    spec_dir = Path(args.spec_dir).expanduser() if args.spec_dir else resource_root / LANGUAGE_SPEC_DIRNAME
    metadata_dir = (
        Path(args.metadata_dir).expanduser()
        if args.metadata_dir
        else resource_root / LANGUAGE_METADATA_DIRNAME
    )

    if not spec_dir.is_dir():
        raise FileNotFoundError(f"Language specification directory not found: {spec_dir}")
    if not metadata_dir.is_dir():
        raise FileNotFoundError(f"Language metadata directory not found: {metadata_dir}")

    specifications: list[dict[str, Any]] = []
    rule_index: dict[str, dict[str, Any]] = {}
    duplicate_identifiers: dict[str, list[str]] = {}

    for path in specification_files(spec_dir):
        entries = load_plist(path)
        if not isinstance(entries, list):
            entries = [entries]
        relative_path = str(path.relative_to(resource_root))
        specifications.append(
            {
                "path": relative_path,
                "entryCount": len(entries),
                "entries": entries,
            }
        )
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            identifier = entry.get("Identifier")
            if not isinstance(identifier, str):
                continue
            indexed_entry = {
                "identifier": identifier,
                "path": relative_path,
                "entry": entry,
            }
            if identifier in rule_index:
                duplicate_identifiers.setdefault(identifier, [rule_index[identifier]["path"]]).append(
                    relative_path
                )
            rule_index[identifier] = indexed_entry

    metadata_entries: list[dict[str, Any]] = []
    if args.all_languages:
        language_filters: set[str] = set()
    elif args.language:
        language_filters = {value.lower() for value in args.language}
    else:
        language_filters = {identifier.lower() for identifier in SUPPORTED_LANGUAGE_IDENTIFIERS}
    for path in sorted(metadata_dir.glob("*.plist")):
        metadata = load_plist(path)
        if not isinstance(metadata, dict):
            continue
        metadata["path"] = str(path.relative_to(resource_root))
        metadata_entries.append(metadata)

    languages: list[dict[str, Any]] = []
    for metadata in sorted(metadata_entries, key=lambda item: str(item.get("identifier", ""))):
        if not language_matches(metadata, language_filters):
            continue
        language_specification = metadata.get("languageSpecification")
        rule_identifiers = (
            collect_rule_closure(language_specification, rule_index)
            if isinstance(language_specification, str)
            else []
        )
        languages.append(
            {
                "identifier": metadata.get("identifier"),
                "languageName": metadata.get("languageName"),
                "languageSpecification": language_specification,
                "fileExtensions": metadata.get("fileExtensions", []),
                "fileDataTypeIdentifiers": metadata.get("fileDataTypeIdentifiers", []),
                "ruleIdentifiers": rule_identifiers,
                "syntaxTypes": syntax_types_for_rules(rule_identifiers, rule_index),
                "metadata": metadata,
            }
        )

    return {
        "source": {
            "toolchainApp": str(toolchain_app),
            "resourceRoot": str(resource_root),
            "languageSpecificationsDirectory": str(spec_dir),
            "languageMetadataDirectory": str(metadata_dir),
        },
        "specifications": specifications,
        "rulesByIdentifier": rule_index,
        "duplicateRuleIdentifiers": duplicate_identifiers,
        "languages": languages,
    }


def main() -> int:
    args = parse_arguments()
    try:
        snapshot = build_snapshot(args)
    except Exception as error:
        print(f"xclangspec_snapshot: {error}", file=sys.stderr)
        return 1

    indent = 2 if args.pretty else None
    print(json.dumps(snapshot, indent=indent, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
