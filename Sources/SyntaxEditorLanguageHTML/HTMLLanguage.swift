import Foundation
import SyntaxEditorCoreTypes
import SyntaxEditorLanguageCSS
import SyntaxEditorLanguageJavaScript
import SyntaxEditorLanguageSupport
import SwiftTreeSitter
import TreeSitterHTML

package struct HTMLLanguage: SyntaxLanguageSupport {
    package init() {}

    package var language: SyntaxLanguage { .html }
    package var displayName: String { "HTML" }
    package var aliases: Set<String> { ["html", "htm"] }
    package var treeSitterSupport: SyntaxLanguageTreeSitterSupport? {
        SyntaxLanguageTreeSitterSupport(
            name: "HTML",
            bundleName: "TreeSitterHTML_TreeSitterHTML",
            queryDirectories: Self.queryDirectories,
            makeLanguage: { unsafe Language(tree_sitter_html()) }
        )
    }

    package func toggleComment(source: String, selection: NSRange) -> SyntaxLanguage.EditResult? {
        let nsSource = source as NSString
        let safeSelection = SyntaxEditorRangeUtilities.clampedRange(selection, utf16Length: nsSource.length)
        let selectionEnd = safeSelection.location + safeSelection.length

        if safeSelection.length == 0,
           Self.lineStartsWithLegacyScriptWrapperMarker(in: nsSource, location: safeSelection.location)
        {
            return nil
        }

        if case .closingTagPrefix = Self.rawTextLocationState(in: nsSource, location: safeSelection.location) {
            return nil
        }

        if case .closingTagPrefix = Self.rawTextLocationState(in: nsSource, location: selectionEnd) {
            return nil
        }

        if Self.selectionTouchesRawTextClosingTag(in: nsSource, selection: safeSelection) {
            return nil
        }

        if Self.selectionTouchesUnsupportedRawText(in: nsSource, selection: safeSelection) {
            return nil
        }

        if Self.selectionTouchesLegacyScriptWrapper(in: nsSource, selection: safeSelection) {
            return nil
        }

        if let context = Self.embeddedRawTextContext(in: source, selection: safeSelection) {
            return embeddedRawTextCommentEdit(
                source: source,
                selection: safeSelection,
                context: context
            )
        }

        if Self.selectionTouchesRawTextRegion(in: nsSource, selection: safeSelection) {
            return nil
        }

        let targetLinesRange = SyntaxLanguageTextUtilities.selectedLineEnvelope(
            in: nsSource,
            selection: safeSelection
        )
        let segment = nsSource.substring(with: targetLinesRange)
        if SyntaxLanguageTextUtilities.shouldRejectMarkupCommentWrapping(segment) {
            return nil
        }

        return SyntaxLanguageTextUtilities.toggleWrappedComment(
            source: source,
            selection: safeSelection,
            openMarker: "<!--",
            closeMarker: "-->"
        )
    }

    package func isInsideLiteralOrComment(source: String, location: Int) -> Bool {
        let nsSource = source as NSString
        let clampedLocation = max(0, min(location, nsSource.length))

        switch Self.rawTextLocationState(in: nsSource, location: clampedLocation) {
        case .content(let rawTextElementName, let rawTextContentStart):
            guard let embeddedLanguage = Self.embeddedLanguage(
                in: nsSource,
                rawTextElementName: rawTextElementName,
                rawTextContentStart: rawTextContentStart
            ) else {
                break
            }
            let embeddedRange = NSRange(
                location: rawTextContentStart,
                length: clampedLocation - rawTextContentStart
            )
            let embeddedPrefix = nsSource.substring(with: embeddedRange)
            return Self.isInsideEmbeddedLiteralOrComment(
                language: embeddedLanguage,
                source: embeddedPrefix,
                location: embeddedPrefix.utf16.count
            )
        case .closingTagPrefix:
            return true
        case .outside:
            break
        }

        var analysis = PrefixAnalysis()
        var cursor = 0
        PrefixAnalyzer.advance(
            &analysis,
            in: nsSource,
            cursor: &cursor,
            limit: clampedLocation,
            limitIsEndOfText: true
        )
        return analysis.shouldSuppressQuoteAutoPair
    }
}

private extension HTMLLanguage {
    static var queryDirectories: [URL] {
        BundledLanguageQueryResources.directories(in: .module, named: "HTMLQueries")
    }
}

private extension HTMLLanguage {
    struct EmbeddedRawTextContext {
        let range: NSRange
        let language: SyntaxLanguage
    }

    enum RawTextLocationState {
        case outside
        case closingTagPrefix
        case content(rawTextElementName: String, rawTextContentStart: Int)
    }

    static func embeddedSupport(for language: SyntaxLanguage) -> (any SyntaxLanguageSupport)? {
        switch language {
        case .css:
            CSSLanguage()
        case .javascript:
            JavaScriptLanguage()
        default:
            nil
        }
    }

    static func isInsideEmbeddedLiteralOrComment(
        language: SyntaxLanguage,
        source: String,
        location: Int
    ) -> Bool {
        embeddedSupport(for: language)?.isInsideLiteralOrComment(source: source, location: location) ?? false
    }

    func embeddedRawTextCommentEdit(
        source: String,
        selection: NSRange,
        context: EmbeddedRawTextContext
    ) -> SyntaxLanguage.EditResult? {
        let nsSource = source as NSString
        let embeddedSource = nsSource.substring(with: context.range)
        let embeddedSelection = NSRange(
            location: selection.location - context.range.location,
            length: selection.length
        )
        guard let embeddedEdit = Self.embeddedSupport(for: context.language)?.toggleComment(
            source: embeddedSource,
            selection: embeddedSelection
        ) else {
            return nil
        }

        let edits = embeddedEdit.edits.map {
            SyntaxEditorTextChange.Replacement(
                range: NSRange(
                    location: context.range.location + $0.range.location,
                    length: $0.range.length
                ),
                replacement: $0.replacement
            )
        }
        return SyntaxLanguage.EditResult(
            edits: edits,
            selectedRange: NSRange(
                location: context.range.location + embeddedEdit.selectedRange.location,
                length: embeddedEdit.selectedRange.length
            )
        )
    }

    struct PrefixAnalysis {
        var inTag = false
        var inComment = false
        var inSingleQuotedAttributeValue = false
        var inDoubleQuotedAttributeValue = false
        var inUnquotedAttributeValue = false
        var canStartAttributeValue = false
        var sawSelfClosingSlash = false
        var rawTextElementName: String?
        var rawTextContentStart: Int?
        var currentTagName = ""
        var currentTagIsClosing = false
        var currentClosingTagCanTerminateRawText = false
        var currentTagStart: Int?
        var supportedRawTextState: SupportedEmbeddedRawTextState?

        var shouldSuppressQuoteAutoPair: Bool {
            if inComment || inSingleQuotedAttributeValue || inDoubleQuotedAttributeValue {
                return true
            }

            if inTag {
                return !canStartAttributeValue
            }

            return true
        }
    }

    enum PrefixAnalyzer {
        /// `limitIsEndOfText` treats `limit` as the end of the analyzed text
        /// (no lookahead past it), matching what analyzing a prefix substring
        /// would see. Leave it `false` for streaming callers that keep
        /// advancing the same cursor with growing limits.
        static func advance(
            _ analysis: inout PrefixAnalysis,
            in source: NSString,
            cursor: inout Int,
            limit: Int,
            limitIsEndOfText: Bool = false
        ) {
            let upperBound = max(0, min(limit, source.length))
            let end = limitIsEndOfText ? upperBound : source.length

            while cursor < upperBound {
                if analysis.inComment {
                    if Self.hasPrefix("-->", in: source, at: cursor, end: end) {
                        analysis.inComment = false
                        cursor = min(cursor + 3, upperBound)
                    } else {
                        cursor += 1
                    }
                    continue
                }

                if analysis.inSingleQuotedAttributeValue {
                    if source.character(at: cursor) == 39 {
                        analysis.inSingleQuotedAttributeValue = false
                        analysis.inTag = true
                    }
                    cursor += 1
                    continue
                }

                if analysis.inDoubleQuotedAttributeValue {
                    if source.character(at: cursor) == 34 {
                        analysis.inDoubleQuotedAttributeValue = false
                        analysis.inTag = true
                    }
                    cursor += 1
                    continue
                }

                if analysis.inTag {
                    let codeUnit = source.character(at: cursor)

                    if codeUnit == 62 {
                        if analysis.currentTagIsClosing {
                            if analysis.currentClosingTagCanTerminateRawText,
                               analysis.rawTextElementName == analysis.currentTagName
                            {
                                analysis.rawTextElementName = nil
                                analysis.rawTextContentStart = nil
                                analysis.supportedRawTextState = nil
                            }
                        } else if Self.isRawTextElementName(analysis.currentTagName) {
                            analysis.rawTextElementName = analysis.currentTagName
                            analysis.rawTextContentStart = cursor + 1
                            analysis.supportedRawTextState = HTMLLanguage.supportedRawTextState(
                                in: source,
                                rawTextElementName: analysis.currentTagName,
                                tagStart: analysis.currentTagStart,
                                tagEnd: cursor
                            )
                        }

                        analysis.inTag = false
                        analysis.canStartAttributeValue = false
                        analysis.inUnquotedAttributeValue = false
                        analysis.sawSelfClosingSlash = false
                        analysis.currentTagName = ""
                        analysis.currentTagIsClosing = false
                        analysis.currentClosingTagCanTerminateRawText = false
                        analysis.currentTagStart = nil
                        cursor += 1
                        continue
                    }

                    if analysis.currentTagIsClosing {
                        if codeUnit == 32 || codeUnit == 9 || codeUnit == 10 || codeUnit == 13 {
                            cursor += 1
                            continue
                        }

                        analysis.currentClosingTagCanTerminateRawText = false
                        cursor += 1
                        continue
                    }

                    if analysis.inUnquotedAttributeValue {
                        if codeUnit == 32 || codeUnit == 9 || codeUnit == 10 || codeUnit == 13 {
                            analysis.inUnquotedAttributeValue = false
                            cursor += 1
                            continue
                        }

                        cursor += 1
                        continue
                    }

                    if codeUnit == 32 || codeUnit == 9 || codeUnit == 10 || codeUnit == 13 {
                        cursor += 1
                        continue
                    }

                    if codeUnit == 61 {
                        analysis.canStartAttributeValue = true
                        analysis.sawSelfClosingSlash = false
                        cursor += 1
                        continue
                    }

                    if codeUnit == 39 {
                        if analysis.canStartAttributeValue {
                            analysis.inSingleQuotedAttributeValue = true
                            analysis.canStartAttributeValue = false
                        }
                        analysis.sawSelfClosingSlash = false
                        cursor += 1
                        continue
                    }

                    if codeUnit == 34 {
                        if analysis.canStartAttributeValue {
                            analysis.inDoubleQuotedAttributeValue = true
                            analysis.canStartAttributeValue = false
                        }
                        analysis.sawSelfClosingSlash = false
                        cursor += 1
                        continue
                    }

                    if analysis.canStartAttributeValue {
                        analysis.inUnquotedAttributeValue = true
                        analysis.canStartAttributeValue = false
                        analysis.sawSelfClosingSlash = false
                        cursor += 1
                        continue
                    }

                    if codeUnit == 47 {
                        analysis.sawSelfClosingSlash = true
                        cursor += 1
                        continue
                    }

                    analysis.canStartAttributeValue = false
                    analysis.sawSelfClosingSlash = false
                    cursor += 1
                    continue
                }

                if let rawTextElementName = analysis.rawTextElementName {
                    let descriptor = HTMLLanguage.rawTextTagDescriptor(in: source, at: cursor, end: end)
                    if descriptor.isClosing,
                       descriptor.name == rawTextElementName
                    {
                        let isSuppressed = analysis.supportedRawTextState.map {
                            $0.isInsideLiteralOrComment || $0.isInsideLegacyScriptWrapper
                        } ?? false
                        guard isSuppressed == false else {
                            if var state = analysis.supportedRawTextState {
                                state.advance()
                                analysis.supportedRawTextState = state
                                cursor = (analysis.rawTextContentStart ?? 0) + state.literalCursor
                            } else {
                                cursor += 1
                            }
                            continue
                        }
                        analysis.inTag = true
                        analysis.canStartAttributeValue = false
                        analysis.currentTagName = rawTextElementName
                        analysis.currentTagIsClosing = true
                        analysis.currentClosingTagCanTerminateRawText = true
                        analysis.currentTagStart = cursor
                        cursor = descriptor.nextCursor
                        continue
                    }

                    if var state = analysis.supportedRawTextState {
                        state.advance()
                        analysis.supportedRawTextState = state
                        cursor = (analysis.rawTextContentStart ?? 0) + state.literalCursor
                    } else {
                        cursor += 1
                    }
                    continue
                }

                if Self.hasPrefix("<!--", in: source, at: cursor, end: end) {
                    analysis.inComment = true
                    cursor += 4
                    continue
                }

                if Self.startsTag(in: source, at: cursor, end: end) {
                    analysis.inTag = true
                    analysis.canStartAttributeValue = false
                    let tag = Self.tagDescriptor(in: source, at: cursor, end: end)
                    analysis.currentTagName = tag.name
                    analysis.currentTagIsClosing = tag.isClosing
                    analysis.currentClosingTagCanTerminateRawText = tag.isClosing
                    analysis.currentTagStart = cursor
                    cursor = tag.nextCursor
                    continue
                }

                cursor += 1
            }
        }

        private static func startsTag(in source: NSString, at offset: Int, end: Int) -> Bool {
            guard offset >= 0, offset < end, source.character(at: offset) == 60 else {
                return false
            }

            let nextOffset = offset + 1
            guard nextOffset < end else { return false }
            let next = source.character(at: nextOffset)

            return isASCIIAlpha(next) || next == 47 || next == 63
        }

        private static func tagDescriptor(
            in source: NSString,
            at offset: Int,
            end: Int
        ) -> (name: String, isClosing: Bool, nextCursor: Int) {
            var cursor = offset + 1
            var isClosing = false

            if cursor < end, source.character(at: cursor) == 47 {
                isClosing = true
                cursor += 1
            }

            while cursor < end {
                let codeUnit = source.character(at: cursor)
                if codeUnit == 32 || codeUnit == 9 || codeUnit == 10 || codeUnit == 13 {
                    cursor += 1
                    continue
                }
                break
            }

            let nameStart = cursor
            while cursor < end, isTagNameCharacter(source.character(at: cursor)) {
                cursor += 1
            }

            let name: String
            if cursor > nameStart {
                name = source.substring(with: NSRange(location: nameStart, length: cursor - nameStart)).lowercased()
            } else {
                name = ""
            }

            return (name: name, isClosing: isClosing, nextCursor: cursor)
        }

        private static func hasPrefix(_ literal: String, in source: NSString, at offset: Int, end: Int) -> Bool {
            guard offset + literal.utf16.count <= end else {
                return false
            }
            return HTMLLanguage.hasPrefix(literal, in: source, at: offset)
        }

        private static func isASCIIAlpha(_ codeUnit: unichar) -> Bool {
            (65...90).contains(Int(codeUnit)) || (97...122).contains(Int(codeUnit))
        }

        private static func isTagNameCharacter(_ codeUnit: unichar) -> Bool {
            isASCIIAlpha(codeUnit) || (48...57).contains(Int(codeUnit)) || codeUnit == 45 || codeUnit == 58
        }

        private static func isRawTextElementName(_ name: String) -> Bool {
            name == "script" || name == "style"
        }

    }

    enum SupportedEmbeddedLiteralState {
        case javascript(JavaScriptLanguage.PrefixAnalysis)
        case css(CSSLanguage.PrefixAnalysis)

        var isInsideLiteralOrComment: Bool {
            switch self {
            case .javascript(let analysis):
                return analysis.isInsideLiteralOrComment
            case .css(let analysis):
                return analysis.isInsideLiteralOrComment
            }
        }
    }

    struct SupportedEmbeddedRawTextState {
        let rawTextElementName: String
        let source: NSString
        let contentStart: Int
        var literalState: SupportedEmbeddedLiteralState
        var literalCursor = 0
        var isInsideLegacyScriptWrapper = false
        var isAtLineStart = true

        var isInsideLiteralOrComment: Bool {
            literalState.isInsideLiteralOrComment
        }

        mutating func advance() {
            let absoluteCursor = contentStart + literalCursor
            guard absoluteCursor < source.length else {
                return
            }

            updateLegacyScriptWrapperIfNeeded()

            let codeUnit = source.character(at: absoluteCursor)
            let nextLimit = min(absoluteCursor + 1, source.length)
            var nextCursor = absoluteCursor
            switch literalState {
            case .javascript(var analysis):
                JavaScriptLanguage.PrefixAnalyzer.advance(
                    &analysis,
                    in: source,
                    cursor: &nextCursor,
                    limit: nextLimit
                )
                literalState = .javascript(analysis)
            case .css(var analysis):
                CSSLanguage.PrefixAnalyzer.advance(
                    &analysis,
                    in: source,
                    cursor: &nextCursor,
                    limit: nextLimit
                )
                literalState = .css(analysis)
            }

            literalCursor = nextCursor - contentStart
            if codeUnit == 10 || codeUnit == 13 {
                isAtLineStart = true
            }
        }

        private mutating func updateLegacyScriptWrapperIfNeeded() {
            let absoluteCursor = contentStart + literalCursor
            guard rawTextElementName == "script", isAtLineStart, absoluteCursor < source.length else {
                return
            }

            let codeUnit = source.character(at: absoluteCursor)
            if codeUnit == 10 || codeUnit == 13 {
                return
            }
            if codeUnit == 32 || codeUnit == 9 {
                return
            }

            if isInsideLiteralOrComment == false {
                if HTMLLanguage.hasPrefix("<!--", in: source, at: absoluteCursor) {
                    isInsideLegacyScriptWrapper = true
                } else if HTMLLanguage.hasPrefix("//-->", in: source, at: absoluteCursor) ||
                            HTMLLanguage.hasPrefix("-->", in: source, at: absoluteCursor)
                {
                    isInsideLegacyScriptWrapper = false
                }
            }

            isAtLineStart = false
        }
    }

    static func hasPrefix(_ literal: String, in source: NSString, at offset: Int) -> Bool {
        let length = literal.utf16.count
        guard offset >= 0, offset + length <= source.length else {
            return false
        }

        return source.substring(with: NSRange(location: offset, length: length)) == literal
    }

    static func supportedRawTextState(
        in source: NSString,
        rawTextElementName: String,
        tagStart: Int?,
        tagEnd: Int
    ) -> SupportedEmbeddedRawTextState? {
        guard let tagStart, tagStart <= tagEnd else {
            return nil
        }

        let startTagText = source.substring(
            with: NSRange(location: tagStart, length: tagEnd - tagStart + 1)
        )
        let embeddedLanguage: SyntaxLanguage?
        switch rawTextElementName {
        case "script":
            embeddedLanguage = scriptEmbeddedLanguage(forStartTagText: startTagText)
        case "style":
            embeddedLanguage = styleEmbeddedLanguage(forStartTagText: startTagText)
        default:
            embeddedLanguage = nil
        }

        return supportedRawTextState(
            rawTextElementName: rawTextElementName,
            embeddedLanguage: embeddedLanguage,
            in: source,
            contentStart: tagEnd + 1
        )
    }

    static func supportedRawTextState(
        rawTextElementName: String,
        embeddedLanguage: SyntaxLanguage?,
        in source: NSString,
        contentStart: Int
    ) -> SupportedEmbeddedRawTextState? {
        guard let embeddedLanguage else {
            return nil
        }

        switch embeddedLanguage {
        case .javascript where rawTextElementName == "script":
            return SupportedEmbeddedRawTextState(
                rawTextElementName: rawTextElementName,
                source: source,
                contentStart: contentStart,
                literalState: .javascript(JavaScriptLanguage.PrefixAnalysis())
            )
        case .css where rawTextElementName == "style":
            return SupportedEmbeddedRawTextState(
                rawTextElementName: rawTextElementName,
                source: source,
                contentStart: contentStart,
                literalState: .css(CSSLanguage.PrefixAnalysis())
            )
        default:
            return nil
        }
    }

    static func embeddedRawTextContext(in source: String, selection: NSRange) -> EmbeddedRawTextContext? {
        let nsSource = source as NSString
        let safeSelection = SyntaxEditorRangeUtilities.clampedRange(selection, utf16Length: nsSource.length)
        let selectionEnd = safeSelection.location + safeSelection.length
        guard case .content(let rawTextElementName, let rawTextContentStart) =
                rawTextLocationState(in: nsSource, location: safeSelection.location),
              case .content(let selectionEndElementName, let selectionEndContentStart) =
                rawTextLocationState(in: nsSource, location: selectionEnd),
              rawTextElementName == selectionEndElementName,
              rawTextContentStart == selectionEndContentStart,
              let language = embeddedLanguage(
                in: nsSource,
                rawTextElementName: rawTextElementName,
                rawTextContentStart: rawTextContentStart
              )
        else {
            return nil
        }

        let contextEnd = rawTextContextEnd(
            in: nsSource,
            rawTextElementName: rawTextElementName,
            rawTextContentStart: rawTextContentStart
        )
        guard selectionEnd <= contextEnd else {
            return nil
        }

        return EmbeddedRawTextContext(
            range: NSRange(location: rawTextContentStart, length: contextEnd - rawTextContentStart),
            language: language
        )
    }

    static func isInsideRawTextClosingTagPrefix(
        _ rawTextPrefix: String,
        rawTextElementName: String,
        embeddedLanguage: SyntaxLanguage
    ) -> Bool {
        let nsPrefix = rawTextPrefix as NSString
        let closingTagStart = nsPrefix.range(
            of: "</",
            options: [.backwards, .caseInsensitive]
        )
        guard closingTagStart.location != NSNotFound else {
            return false
        }

        var cursor = closingTagStart.location + closingTagStart.length
        while cursor < nsPrefix.length {
            let codeUnit = nsPrefix.character(at: cursor)
            if codeUnit == 32 || codeUnit == 9 || codeUnit == 10 || codeUnit == 13 {
                cursor += 1
                continue
            }
            break
        }

        let nameStart = cursor
        while cursor < nsPrefix.length {
            let codeUnit = nsPrefix.character(at: cursor)
            let isTagNameCharacter =
                (65...90).contains(Int(codeUnit)) ||
                (97...122).contains(Int(codeUnit)) ||
                (48...57).contains(Int(codeUnit)) ||
                codeUnit == 45 ||
                codeUnit == 58
            guard isTagNameCharacter else {
                break
            }
            cursor += 1
        }

        let typedName = nsPrefix
            .substring(with: NSRange(location: nameStart, length: cursor - nameStart))
            .lowercased()
        guard rawTextElementName.hasPrefix(typedName) else {
            return false
        }
        guard Self.isInsideEmbeddedLiteralOrComment(
                    language: embeddedLanguage,
            source: rawTextPrefix,
            location: closingTagStart.location
        ) == false else {
            return false
        }
        if rawTextElementName == "script",
           isInsideLegacyScriptWrapper(rawTextPrefix)
        {
            return false
        }

        while cursor < nsPrefix.length {
            let codeUnit = nsPrefix.character(at: cursor)
            guard codeUnit == 32 || codeUnit == 9 || codeUnit == 10 || codeUnit == 13 else {
                return false
            }
            cursor += 1
        }

        return true
    }

    static func isInsideLegacyScriptWrapper(_ rawTextPrefix: String) -> Bool {
        let nsPrefix = rawTextPrefix as NSString
        var insideWrapper = false
        var cursor = 0

        while cursor < nsPrefix.length {
            let lineRange = nsPrefix.lineRange(for: NSRange(location: cursor, length: 0))
            var contentCursor = lineRange.location
            let lineEnd = NSMaxRange(lineRange)

            while contentCursor < lineEnd {
                let codeUnit = nsPrefix.character(at: contentCursor)
                if codeUnit == 32 || codeUnit == 9 || codeUnit == 10 || codeUnit == 13 {
                    contentCursor += 1
                    continue
                }
                break
            }

            let linePrefix = nsPrefix.substring(
                with: NSRange(location: contentCursor, length: max(0, lineEnd - contentCursor))
            )
            let isInsideEmbeddedLiteralOrComment = Self.isInsideEmbeddedLiteralOrComment(
                language: .javascript,
                source: rawTextPrefix,
                location: contentCursor
            )

            if linePrefix.hasPrefix("<!--"), isInsideEmbeddedLiteralOrComment == false {
                insideWrapper = true
            } else if (linePrefix.hasPrefix("//-->") || linePrefix.hasPrefix("-->")),
                      isInsideEmbeddedLiteralOrComment == false
            {
                insideWrapper = false
            }

            cursor = lineEnd
        }

        return insideWrapper
    }

    static func selectionTouchesLegacyScriptWrapper(
        in source: NSString,
        selection: NSRange
    ) -> Bool {
        let inspectedRange: NSRange
        if selection.length == 0 {
            let lineRange = source.lineRange(for: NSRange(location: selection.location, length: 0))
            inspectedRange = lineRange
        } else {
            inspectedRange = selection
        }

        var cursor = inspectedRange.location
        let inspectedEnd = NSMaxRange(inspectedRange)

        while cursor < inspectedEnd {
            let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
            var contentCursor = lineRange.location
            let lineEnd = min(source.length, NSMaxRange(lineRange))

            while contentCursor < lineEnd {
                let codeUnit = source.character(at: contentCursor)
                if codeUnit == 32 || codeUnit == 9 || codeUnit == 10 || codeUnit == 13 {
                    contentCursor += 1
                    continue
                }
                break
            }

            let linePrefix = source.substring(
                with: NSRange(location: contentCursor, length: max(0, lineEnd - contentCursor))
            )
            let isWrapperMarkerLine =
                linePrefix.hasPrefix("<!--") ||
                linePrefix.hasPrefix("//-->") ||
                linePrefix.hasPrefix("-->")
            if isWrapperMarkerLine,
               case .content(let rawTextElementName, let rawTextContentStart) =
                    rawTextLocationState(in: source, location: contentCursor),
               rawTextElementName == "script",
               let embeddedLanguage = embeddedLanguage(
                in: source,
                rawTextElementName: rawTextElementName,
                rawTextContentStart: rawTextContentStart
               )
            {
                let rawTextPrefix = source.substring(
                    with: NSRange(
                        location: rawTextContentStart,
                        length: max(0, contentCursor - rawTextContentStart)
                    )
                )
                if Self.isInsideEmbeddedLiteralOrComment(
                    language: embeddedLanguage,
                    source: rawTextPrefix,
                    location: rawTextPrefix.utf16.count
                ) == false {
                    return true
                }
            }

            cursor = lineRange.location + lineRange.length
        }

        return false
    }

    static func selectionTouchesUnsupportedRawText(
        in source: NSString,
        selection: NSRange
    ) -> Bool {
        var cursor = 0

        while let startTag = nextUnsupportedRawTextStartTag(in: source, from: cursor) {
            let contentStart = NSMaxRange(startTag.range)
            let contentEnd = rawTextClosingTagStart(
                in: source,
                rawTextElementName: startTag.name,
                from: contentStart
            ) ?? source.length
            let protectedRange = NSRange(location: contentStart, length: max(0, contentEnd - contentStart))

            if selectionIntersectsProtectedRange(
                selection,
                protectedRange: protectedRange,
                treatsEOFBoundaryAsInside: contentEnd == source.length
            ) {
                return true
            }

            cursor = max(contentStart + 1, contentEnd)
        }

        return false
    }

    static func selectionTouchesRawTextClosingTag(
        in source: NSString,
        selection: NSRange
    ) -> Bool {
        var cursor = 0

        while let startTag = nextRawTextStartTag(in: source, from: cursor) {
            let contentStart = NSMaxRange(startTag.range)
            let startTagText = source.substring(with: startTag.range)
            let embeddedLanguage: SyntaxLanguage?
            switch startTag.name {
            case "script":
                embeddedLanguage = scriptEmbeddedLanguage(forStartTagText: startTagText)
            case "style":
                embeddedLanguage = styleEmbeddedLanguage(forStartTagText: startTagText)
            default:
                embeddedLanguage = nil
            }

            let closingTagStart: Int?
            if let embeddedLanguage {
                closingTagStart = rawTextClosingTagStart(
                    in: source,
                    rawTextElementName: startTag.name,
                    searchFrom: contentStart,
                    embeddedLanguage: embeddedLanguage
                )
            } else {
                closingTagStart = rawTextClosingTagStart(
                    in: source,
                    rawTextElementName: startTag.name,
                    from: contentStart
                )
            }

            guard let closingTagStart else {
                break
            }

            let descriptor = rawTextTagDescriptor(in: source, at: closingTagStart, end: source.length)
            guard descriptor.isClosing,
                  descriptor.name == startTag.name,
                  let closingTagEnd = endOfClosingRawTextTag(in: source, after: descriptor.nextCursor)
            else {
                cursor = closingTagStart + 1
                continue
            }

            let closingTagRange = NSRange(
                location: closingTagStart,
                length: closingTagEnd - closingTagStart + 1
            )
            if selectionIntersectsProtectedRange(selection, protectedRange: closingTagRange) {
                return true
            }

            cursor = closingTagEnd + 1
        }

        return false
    }

    static func selectionTouchesRawTextRegion(
        in source: NSString,
        selection: NSRange
    ) -> Bool {
        var cursor = 0

        while let startTag = nextRawTextStartTag(in: source, from: cursor) {
            let contentStart = NSMaxRange(startTag.range)
            let startTagText = source.substring(with: startTag.range)
            let embeddedLanguage: SyntaxLanguage?
            switch startTag.name {
            case "script":
                embeddedLanguage = scriptEmbeddedLanguage(forStartTagText: startTagText)
            case "style":
                embeddedLanguage = styleEmbeddedLanguage(forStartTagText: startTagText)
            default:
                embeddedLanguage = nil
            }

            let protectedEnd: Int
            if let embeddedLanguage,
               let closingTagStart = rawTextClosingTagStart(
                in: source,
                rawTextElementName: startTag.name,
                searchFrom: contentStart,
                embeddedLanguage: embeddedLanguage
               )
            {
                let descriptor = rawTextTagDescriptor(in: source, at: closingTagStart, end: source.length)
                if let closingTagEnd = endOfClosingRawTextTag(in: source, after: descriptor.nextCursor) {
                    protectedEnd = closingTagEnd + 1
                } else {
                    protectedEnd = source.length
                }
            } else if let closingTagStart = rawTextClosingTagStart(
                in: source,
                rawTextElementName: startTag.name,
                from: contentStart
            ) {
                let descriptor = rawTextTagDescriptor(in: source, at: closingTagStart, end: source.length)
                if let closingTagEnd = endOfClosingRawTextTag(in: source, after: descriptor.nextCursor) {
                    protectedEnd = closingTagEnd + 1
                } else {
                    protectedEnd = source.length
                }
            } else {
                protectedEnd = source.length
            }

            let protectedRange = NSRange(
                location: startTag.range.location,
                length: max(0, protectedEnd - startTag.range.location)
            )
            if selectionIntersectsProtectedRange(selection, protectedRange: protectedRange) {
                return true
            }

            cursor = max(contentStart + 1, protectedEnd)
        }

        return false
    }

    static func lineStartsWithLegacyScriptWrapperMarker(
        in source: NSString,
        location: Int
    ) -> Bool {
        let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
        var contentCursor = lineRange.location
        let lineEnd = NSMaxRange(lineRange)

        while contentCursor < lineEnd {
            let codeUnit = source.character(at: contentCursor)
            if codeUnit == 32 || codeUnit == 9 || codeUnit == 10 || codeUnit == 13 {
                contentCursor += 1
                continue
            }
            break
        }

        let linePrefix = source.substring(
            with: NSRange(location: contentCursor, length: max(0, lineEnd - contentCursor))
        )
        let caretPrefix = source.substring(
            with: NSRange(location: location, length: max(0, lineEnd - location))
        )
        let startsWithLegacyWrapperMarker =
            linePrefix.hasPrefix("<!--") ||
            linePrefix.hasPrefix("//-->") ||
            linePrefix.hasPrefix("-->") ||
            caretPrefix.hasPrefix("<!--") ||
            caretPrefix.hasPrefix("//-->") ||
            caretPrefix.hasPrefix("-->")
        guard startsWithLegacyWrapperMarker else {
            return false
        }

        let markerLocation: Int
        if caretPrefix.hasPrefix("<!--") || caretPrefix.hasPrefix("//-->") || caretPrefix.hasPrefix("-->") {
            markerLocation = location
        } else {
            markerLocation = contentCursor
        }

        guard case .content(let rawTextElementName, let rawTextContentStart) =
                rawTextLocationState(in: source, location: markerLocation),
              rawTextElementName == "script",
              let embeddedLanguage = embeddedLanguage(
                in: source,
                rawTextElementName: rawTextElementName,
                rawTextContentStart: rawTextContentStart
              )
        else {
            return false
        }

        let rawTextPrefix = source.substring(
            with: NSRange(
                location: rawTextContentStart,
                length: max(0, markerLocation - rawTextContentStart)
            )
        )
        guard Self.isInsideEmbeddedLiteralOrComment(
                    language: embeddedLanguage,
            source: rawTextPrefix,
            location: rawTextPrefix.utf16.count
        ) == false else {
            return false
        }

        return true
    }

    static func rawTextLocationState(in source: NSString, location: Int) -> RawTextLocationState {
        let clampedLocation = max(0, min(location, source.length))
        var analysis = PrefixAnalysis()
        var cursor = 0
        PrefixAnalyzer.advance(
            &analysis,
            in: source,
            cursor: &cursor,
            limit: clampedLocation,
            limitIsEndOfText: true
        )
        guard let rawTextElementName = analysis.rawTextElementName,
              let rawTextContentStart = analysis.rawTextContentStart
        else {
            return .outside
        }

        let embeddedPrefix = source.substring(
            with: NSRange(
                location: rawTextContentStart,
                length: clampedLocation - rawTextContentStart
            )
        )
        guard let embeddedLanguage = embeddedLanguage(
            in: source,
            rawTextElementName: rawTextElementName,
            rawTextContentStart: rawTextContentStart
        ) else {
            return .outside
        }
        if isInsideRawTextClosingTagPrefix(
            embeddedPrefix,
            rawTextElementName: rawTextElementName,
            embeddedLanguage: embeddedLanguage
        ) {
            return .closingTagPrefix
        }

        return .content(
            rawTextElementName: rawTextElementName,
            rawTextContentStart: rawTextContentStart
        )
    }

    static func rawTextContextEnd(
        in source: NSString,
        rawTextElementName: String,
        rawTextContentStart: Int
    ) -> Int {
        guard let embeddedLanguage = embeddedLanguage(
            in: source,
            rawTextElementName: rawTextElementName,
            rawTextContentStart: rawTextContentStart
        ) else {
            return source.length
        }
        if let closingTagStart = rawTextClosingTagStart(
            in: source,
            rawTextElementName: rawTextElementName,
            searchFrom: rawTextContentStart,
            embeddedLanguage: embeddedLanguage
        ) {
            return closingTagStart
        }

        return source.length
    }

    static func rawTextClosingTagStart(
        in source: NSString,
        rawTextElementName: String,
        searchFrom: Int,
        embeddedLanguage: SyntaxLanguage,
        mutableSource: NSMutableString? = nil
    ) -> Int? {
        let clampedSearchFrom = max(0, min(searchFrom, source.length))
        if let state = supportedRawTextState(
            rawTextElementName: rawTextElementName,
            embeddedLanguage: embeddedLanguage,
            in: source,
            contentStart: clampedSearchFrom
        ) {
            var state = state
            var absoluteCursor = clampedSearchFrom

            while absoluteCursor < source.length {
                let descriptor = rawTextTagDescriptor(in: source, at: absoluteCursor, end: source.length)
                if descriptor.isClosing,
                   descriptor.name == rawTextElementName
                {
                    if state.isInsideLiteralOrComment || state.isInsideLegacyScriptWrapper {
                        mutableSource?.replaceCharacters(
                            in: NSRange(location: absoluteCursor, length: 1),
                            with: " "
                        )
                    } else if endOfClosingRawTextTag(in: source, after: descriptor.nextCursor) != nil {
                        return absoluteCursor
                    }
                }

                state.advance()
                absoluteCursor = clampedSearchFrom + state.literalCursor
            }

            return nil
        }

        var searchRange = NSRange(
            location: clampedSearchFrom,
            length: source.length - clampedSearchFrom
        )

        while searchRange.length > 0 {
            let candidate = source.range(
                of: "</",
                options: [.caseInsensitive],
                range: searchRange
            )
            guard candidate.location != NSNotFound else {
                return nil
            }

            var cursor = candidate.location + candidate.length
            while cursor < source.length {
                let codeUnit = source.character(at: cursor)
                if codeUnit == 32 || codeUnit == 9 || codeUnit == 10 || codeUnit == 13 {
                    cursor += 1
                    continue
                }
                break
            }

            let nameStart = cursor
            while cursor < source.length {
                let codeUnit = source.character(at: cursor)
                let isTagNameCharacter =
                    (65...90).contains(Int(codeUnit)) ||
                    (97...122).contains(Int(codeUnit)) ||
                    (48...57).contains(Int(codeUnit)) ||
                    codeUnit == 45 ||
                    codeUnit == 58
                guard isTagNameCharacter else {
                    break
                }
                cursor += 1
            }

            let name = source
                .substring(with: NSRange(location: nameStart, length: cursor - nameStart))
                .lowercased()

            if name == rawTextElementName {
                let embeddedPrefix = source.substring(
                    with: NSRange(
                        location: clampedSearchFrom,
                        length: candidate.location - clampedSearchFrom
                    )
                )
                if Self.isInsideEmbeddedLiteralOrComment(
                    language: embeddedLanguage,
                    source: embeddedPrefix,
                    location: embeddedPrefix.utf16.count
                ) || (rawTextElementName == "script" && isInsideLegacyScriptWrapper(embeddedPrefix)) {
                    mutableSource?.replaceCharacters(
                        in: NSRange(location: candidate.location, length: 1),
                        with: " "
                    )
                    let nextLocation = candidate.location + candidate.length
                    searchRange = NSRange(
                        location: nextLocation,
                        length: source.length - nextLocation
                    )
                    continue
                }

                while cursor < source.length {
                    let codeUnit = source.character(at: cursor)
                    if codeUnit == 32 || codeUnit == 9 || codeUnit == 10 || codeUnit == 13 {
                        cursor += 1
                        continue
                    }
                    if codeUnit == 62 {
                        return candidate.location
                    }
                    break
                }
            }

            let nextLocation = candidate.location + candidate.length
            searchRange = NSRange(
                location: nextLocation,
                length: source.length - nextLocation
            )
        }

        return nil
    }

    static func embeddedLanguage(
        in source: NSString,
        rawTextElementName: String,
        rawTextContentStart: Int
    ) -> SyntaxLanguage? {
        guard let startTagText = rawTextStartTagText(
            in: source,
            rawTextContentStart: rawTextContentStart
        ) else {
            return embeddedLanguage(named: rawTextElementName)
        }

        switch rawTextElementName {
        case "script", "script_element":
            return scriptEmbeddedLanguage(forStartTagText: startTagText)
        case "style", "style_element":
            return styleEmbeddedLanguage(forStartTagText: startTagText)
        default:
            return nil
        }
    }

    static func embeddedLanguage(named name: String) -> SyntaxLanguage? {
        switch name {
        case "script", "script_element":
            return SyntaxLanguage.javascript
        case "style", "style_element":
            return SyntaxLanguage.css
        default:
            return nil
        }
    }

    static func rawTextStartTagText(
        in source: NSString,
        rawTextContentStart: Int
    ) -> String? {
        var cursor = 0

        while let startTag = nextRawTextStartTag(in: source, from: cursor) {
            let contentStart = NSMaxRange(startTag.range)
            if contentStart == rawTextContentStart {
                return source.substring(with: startTag.range)
            }
            if contentStart > rawTextContentStart {
                return nil
            }

            cursor = contentStart
        }

        return nil
    }

    private static let supportedScriptTypeEssences: Set<String> = [
        "",
        "application/ecmascript",
        "application/javascript",
        "application/x-ecmascript",
        "application/x-javascript",
        "module",
        "text/ecmascript",
        "text/javascript",
        "text/javascript1.0",
        "text/javascript1.1",
        "text/javascript1.2",
        "text/javascript1.3",
        "text/javascript1.4",
        "text/javascript1.5",
        "text/jscript",
        "text/livescript",
        "text/x-ecmascript",
        "text/x-javascript",
    ]

    private static let supportedStyleTypeEssences: Set<String> = [
        "",
        "text/css",
    ]

    private static func normalizedTypeAttributeEssence(_ type: String) -> String {
        type
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? type.lowercased()
    }

    static func scriptEmbeddedLanguage(forStartTagText startTagText: String) -> SyntaxLanguage? {
        guard rawTextStartTagHasValidNameBoundary(startTagText, rawTextElementName: "script") else {
            return nil
        }
        guard let type = startTagTypeAttribute(in: startTagText) else {
            return SyntaxLanguage.javascript
        }

        let essence = normalizedTypeAttributeEssence(type)
        return supportedScriptTypeEssences.contains(essence) ? SyntaxLanguage.javascript : nil
    }

    static func styleEmbeddedLanguage(forStartTagText startTagText: String) -> SyntaxLanguage? {
        guard rawTextStartTagHasValidNameBoundary(startTagText, rawTextElementName: "style") else {
            return nil
        }
        guard let type = startTagTypeAttribute(in: startTagText) else {
            return SyntaxLanguage.css
        }

        let essence = normalizedTypeAttributeEssence(type)
        return supportedStyleTypeEssences.contains(essence) ? SyntaxLanguage.css : nil
    }

    private static func rawTextStartTagHasValidNameBoundary(
        _ startTagText: String,
        rawTextElementName: String
    ) -> Bool {
        let nsText = startTagText as NSString
        var cursor = 0
        guard cursor < nsText.length, nsText.character(at: cursor) == 60 else {
            return false
        }

        cursor += 1
        while cursor < nsText.length, nsText.character(at: cursor) == 47 {
            cursor += 1
        }
        skipHTMLAttributeWhitespace(in: nsText, cursor: &cursor)

        let nameStart = cursor
        while cursor < nsText.length, isHTMLTagNameCharacter(nsText.character(at: cursor)) {
            cursor += 1
        }
        guard cursor > nameStart else {
            return false
        }

        let tagName = nsText.substring(with: NSRange(location: nameStart, length: cursor - nameStart)).lowercased()
        guard tagName == rawTextElementName else {
            return false
        }
        guard cursor < nsText.length else {
            return true
        }

        let boundary = nsText.character(at: cursor)
        return isHTMLWhitespace(boundary) || boundary == 47 || boundary == 62
    }

    static func startTagTypeAttribute(in startTagText: String) -> String? {
        let nsText = startTagText as NSString
        var cursor = 0

        if cursor < nsText.length, nsText.character(at: cursor) == 60 {
            cursor += 1
        }
        while cursor < nsText.length, nsText.character(at: cursor) == 47 {
            cursor += 1
        }
        skipHTMLAttributeWhitespace(in: nsText, cursor: &cursor)
        while cursor < nsText.length, isHTMLTagNameCharacter(nsText.character(at: cursor)) {
            cursor += 1
        }

        while cursor < nsText.length {
            skipHTMLAttributeWhitespace(in: nsText, cursor: &cursor)
            guard cursor < nsText.length else { break }

            let current = nsText.character(at: cursor)
            if current == 62 {
                break
            }
            if current == 47 {
                if isSelfClosingTagTerminator(in: nsText, from: cursor) {
                    break
                }
                cursor += 1
                continue
            }

            let nameStart = cursor
            while cursor < nsText.length, isHTMLAttributeNameCharacter(nsText.character(at: cursor)) {
                cursor += 1
            }
            guard cursor > nameStart else {
                cursor += 1
                continue
            }

            let attributeName = nsText
                .substring(with: NSRange(location: nameStart, length: cursor - nameStart))
                .lowercased()

            skipHTMLAttributeWhitespace(in: nsText, cursor: &cursor)
            guard cursor < nsText.length, nsText.character(at: cursor) == 61 else {
                continue
            }
            cursor += 1

            let valueLeadingWhitespaceStart = cursor
            skipHTMLAttributeWhitespace(in: nsText, cursor: &cursor)
            let skippedValueLeadingWhitespace = cursor > valueLeadingWhitespaceStart
            guard cursor < nsText.length else { break }
            if nsText.character(at: cursor) == 62 {
                break
            }
            if attributeName != "type",
               skippedValueLeadingWhitespace,
               looksLikeNextAttributeAssignment(in: nsText, from: cursor)
            {
                continue
            }

            let value: String
            let valueLead = nsText.character(at: cursor)
            if valueLead == 34 || valueLead == 39 {
                let quote = valueLead
                cursor += 1
                let valueStart = cursor
                while cursor < nsText.length, nsText.character(at: cursor) != quote {
                    cursor += 1
                }
                value = nsText.substring(with: NSRange(location: valueStart, length: cursor - valueStart))
                if cursor < nsText.length {
                    cursor += 1
                }
            } else {
                let valueStart = cursor
                while cursor < nsText.length {
                    let codeUnit = nsText.character(at: cursor)
                    if codeUnit == 32 || codeUnit == 9 || codeUnit == 10 || codeUnit == 13 || codeUnit == 62 {
                        break
                    }
                    cursor += 1
                }
                value = nsText.substring(with: NSRange(location: valueStart, length: cursor - valueStart))
            }

            if attributeName == "type" {
                return value
            }
        }

        return nil
    }

    static func skipHTMLAttributeWhitespace(in text: NSString, cursor: inout Int) {
        while cursor < text.length {
            let codeUnit = text.character(at: cursor)
            if codeUnit == 32 || codeUnit == 9 || codeUnit == 10 || codeUnit == 13 {
                cursor += 1
                continue
            }
            break
        }
    }

    static func isHTMLAttributeNameCharacter(_ codeUnit: unichar) -> Bool {
        guard codeUnit != 32, codeUnit != 9, codeUnit != 10, codeUnit != 13 else {
            return false
        }
        return codeUnit != 34 && codeUnit != 39 && codeUnit != 47 &&
            codeUnit != 60 && codeUnit != 61 && codeUnit != 62
    }

    static func looksLikeNextAttributeAssignment(in text: NSString, from start: Int) -> Bool {
        var cursor = start
        guard cursor < text.length, isHTMLAttributeNameCharacter(text.character(at: cursor)) else {
            return false
        }
        while cursor < text.length, isHTMLAttributeNameCharacter(text.character(at: cursor)) {
            cursor += 1
        }
        skipHTMLAttributeWhitespace(in: text, cursor: &cursor)
        return cursor < text.length && text.character(at: cursor) == 61
    }

    static func isSelfClosingTagTerminator(in text: NSString, from start: Int) -> Bool {
        var cursor = start + 1
        skipHTMLAttributeWhitespace(in: text, cursor: &cursor)
        return cursor < text.length && text.character(at: cursor) == 62
    }
}

extension HTMLLanguage {
    private static func nextRawTextStartTag(
        in source: NSString,
        from startOffset: Int
    ) -> (name: String, range: NSRange)? {
        var analysis = PrefixAnalysis()
        var analysisCursor = 0
        return nextRawTextStartTag(
            in: source,
            from: startOffset,
            analysis: &analysis,
            analysisCursor: &analysisCursor
        )
    }

    /// Resumable variant: region scans call this in a loop with one shared
    /// analyzer stream instead of re-streaming the prefix from zero per
    /// region (which made a k-region scan cost O(k·n)). The passed state must
    /// describe `source` up to `analysisCursor` with `analysisCursor` at or
    /// before `startOffset`.
    private static func nextRawTextStartTag(
        in source: NSString,
        from startOffset: Int,
        analysis: inout PrefixAnalysis,
        analysisCursor: inout Int
    ) -> (name: String, range: NSRange)? {
        let clampedStart = max(0, min(startOffset, source.length))
        PrefixAnalyzer.advance(&analysis, in: source, cursor: &analysisCursor, limit: clampedStart)
        var searchCursor = clampedStart

        while searchCursor < source.length {
            guard let candidateLocation = nextRawTextCandidateLocation(in: source, from: searchCursor) else {
                return nil
            }

            PrefixAnalyzer.advance(&analysis, in: source, cursor: &analysisCursor, limit: candidateLocation)
            searchCursor = candidateLocation

            if analysis.inComment || analysis.inTag || analysis.rawTextElementName != nil {
                PrefixAnalyzer.advance(
                    &analysis,
                    in: source,
                    cursor: &analysisCursor,
                    limit: min(candidateLocation + 1, source.length)
                )
                searchCursor = analysisCursor
                continue
            }

            let descriptor = rawTextTagDescriptor(in: source, at: candidateLocation, end: source.length)
            guard descriptor.isClosing == false,
                  let tagName = descriptor.name,
                  let tagEnd = endOfHTMLTag(in: source, after: descriptor.nextCursor)
            else {
                PrefixAnalyzer.advance(
                    &analysis,
                    in: source,
                    cursor: &analysisCursor,
                    limit: min(candidateLocation + 1, source.length)
                )
                searchCursor = analysisCursor
                continue
            }

            let tagRange = NSRange(location: candidateLocation, length: tagEnd - candidateLocation + 1)
            return (tagName, tagRange)
        }

        return nil
    }

    private static func nextRawTextCandidateLocation(
        in source: NSString,
        from startOffset: Int
    ) -> Int? {
        let searchRange = NSRange(location: startOffset, length: source.length - startOffset)
        let scriptRange = source.range(
            of: "<script",
            options: [.caseInsensitive],
            range: searchRange
        )
        let styleRange = source.range(
            of: "<style",
            options: [.caseInsensitive],
            range: searchRange
        )

        let candidates = [scriptRange, styleRange].filter { $0.location != NSNotFound }
        return candidates.min(by: { $0.location < $1.location })?.location
    }

    private static func nextUnsupportedRawTextStartTag(
        in source: NSString,
        from startOffset: Int
    ) -> (name: String, range: NSRange)? {
        var cursor = max(0, startOffset)
        var analysis = PrefixAnalysis()
        var analysisCursor = 0

        while let startTag = nextRawTextStartTag(
            in: source,
            from: cursor,
            analysis: &analysis,
            analysisCursor: &analysisCursor
        ) {
            let startTagText = source.substring(with: startTag.range)
            let embeddedLanguage: SyntaxLanguage?
            switch startTag.name {
            case "script":
                embeddedLanguage = scriptEmbeddedLanguage(forStartTagText: startTagText)
            case "style":
                embeddedLanguage = styleEmbeddedLanguage(forStartTagText: startTagText)
            default:
                embeddedLanguage = nil
            }

            if embeddedLanguage == nil {
                return startTag
            }

            cursor = NSMaxRange(startTag.range)
        }

        return nil
    }

    private static func rawTextClosingTagStart(
        in source: NSString,
        rawTextElementName: String,
        from startOffset: Int
    ) -> Int? {
        var cursor = max(0, startOffset)

        while cursor < source.length {
            guard source.character(at: cursor) == 60 else {
                cursor += 1
                continue
            }

            let descriptor = rawTextTagDescriptor(in: source, at: cursor, end: source.length)
            guard descriptor.isClosing,
                  descriptor.name == rawTextElementName,
                  endOfClosingRawTextTag(in: source, after: descriptor.nextCursor) != nil
            else {
                cursor += 1
                continue
            }

            return cursor
        }

        return nil
    }

    private static func rawTextTagDescriptor(
        in source: NSString,
        at offset: Int,
        end: Int
    ) -> (name: String?, isClosing: Bool, nextCursor: Int) {
        guard offset >= 0, offset < end, source.character(at: offset) == 60 else {
            return (nil, false, offset)
        }

        var cursor = offset + 1
        var isClosing = false

        if cursor < end, source.character(at: cursor) == 47 {
            isClosing = true
            cursor += 1
        }

        while cursor < end {
            let codeUnit = source.character(at: cursor)
            if isHTMLWhitespace(codeUnit) {
                cursor += 1
                continue
            }
            break
        }

        let nameStart = cursor
        while cursor < end, isHTMLTagNameCharacter(source.character(at: cursor)) {
            cursor += 1
        }

        guard cursor > nameStart else {
            return (nil, isClosing, cursor)
        }

        let name = source.substring(
            with: NSRange(location: nameStart, length: cursor - nameStart)
        ).lowercased()
        guard name == "script" || name == "style" else {
            return (nil, isClosing, cursor)
        }

        return (name, isClosing, cursor)
    }

    private static func endOfHTMLTag(in source: NSString, after startOffset: Int) -> Int? {
        var cursor = max(0, startOffset)
        var quote: unichar?

        while cursor < source.length {
            let codeUnit = source.character(at: cursor)

            if let activeQuote = quote, codeUnit == activeQuote {
                cursor += 1
                quote = nil
                continue
            }

            if quote == nil {
                if codeUnit == 34 || codeUnit == 39 {
                    if cursor > startOffset, source.character(at: cursor - 1) == codeUnit {
                        cursor += 1
                        continue
                    }
                    quote = codeUnit
                    cursor += 1
                    continue
                }

                if codeUnit == 62 {
                    return cursor
                }
            }

            cursor += 1
        }

        return nil
    }

    private static func endOfClosingRawTextTag(in source: NSString, after startOffset: Int) -> Int? {
        var cursor = max(0, startOffset)

        while cursor < source.length {
            let codeUnit = source.character(at: cursor)
            if isHTMLWhitespace(codeUnit) {
                cursor += 1
                continue
            }
            break
        }

        guard cursor < source.length, source.character(at: cursor) == 62 else {
            return nil
        }

        return cursor
    }

    private static func isHTMLWhitespace(_ codeUnit: unichar) -> Bool {
        codeUnit == 32 || codeUnit == 9 || codeUnit == 10 || codeUnit == 13
    }

    private static func isHTMLTagNameCharacter(_ codeUnit: unichar) -> Bool {
        (65...90).contains(Int(codeUnit)) ||
            (97...122).contains(Int(codeUnit)) ||
            (48...57).contains(Int(codeUnit)) ||
            codeUnit == 45 ||
            codeUnit == 58
    }

    private static func selectionIntersectsProtectedRange(
        _ selection: NSRange,
        protectedRange: NSRange,
        treatsEOFBoundaryAsInside: Bool = false
    ) -> Bool {
        if selection.length == 0 {
            return selection.location >= protectedRange.location &&
                (
                    selection.location < NSMaxRange(protectedRange) ||
                        (treatsEOFBoundaryAsInside && selection.location == NSMaxRange(protectedRange))
                )
        }

        return SyntaxEditorRangeUtilities.intersection(of: selection, and: protectedRange).length > 0
    }

    package static func sourceByMaskingUnsupportedEmbeddedContent(_ source: String) -> String {
        let nsSource = source as NSString
        let mutableSource = NSMutableString(string: source)
        var cursor = 0
        var analysis = PrefixAnalysis()
        var analysisCursor = 0

        while let startTag = nextRawTextStartTag(
            in: nsSource,
            from: cursor,
            analysis: &analysis,
            analysisCursor: &analysisCursor
        ) {
            let contentStart = NSMaxRange(startTag.range)
            let startTagText = nsSource.substring(with: startTag.range)
            let embeddedLanguage: SyntaxLanguage?
            switch startTag.name {
            case "script":
                embeddedLanguage = scriptEmbeddedLanguage(forStartTagText: startTagText)
            case "style":
                embeddedLanguage = styleEmbeddedLanguage(forStartTagText: startTagText)
            default:
                embeddedLanguage = nil
            }

            let contentEnd: Int
            if let embeddedLanguage {
                contentEnd = rawTextClosingTagStart(
                    in: nsSource,
                    rawTextElementName: startTag.name,
                    searchFrom: contentStart,
                    embeddedLanguage: embeddedLanguage,
                    mutableSource: mutableSource
                ) ?? nsSource.length
            } else {
                contentEnd = rawTextClosingTagStart(
                    in: nsSource,
                    rawTextElementName: startTag.name,
                    from: contentStart
                ) ?? nsSource.length

                let maskedLength = contentEnd - contentStart
                mutableSource.replaceCharacters(
                    in: NSRange(location: contentStart, length: maskedLength),
                    with: String(repeating: " ", count: maskedLength)
                )
            }

            if contentEnd == nsSource.length {
                break
            }

            cursor = contentEnd + 2
        }

        return mutableSource as String
    }

    package static func embeddedCSSRawTextRanges(in source: String) -> [NSRange] {
        rawTextContentRegions(in: source).css
    }

    /// All raw-text content ranges in document order, with the CSS subset the
    /// semantic pass scans. One shared analyzer stream feeds the whole walk.
    package static func rawTextContentRegions(in source: String) -> (all: [NSRange], css: [NSRange]) {
        let nsSource = source as NSString
        var all: [NSRange] = []
        var css: [NSRange] = []
        var cursor = 0
        var analysis = PrefixAnalysis()
        var analysisCursor = 0

        while let startTag = nextRawTextStartTag(
            in: nsSource,
            from: cursor,
            analysis: &analysis,
            analysisCursor: &analysisCursor
        ) {
            let contentStart = NSMaxRange(startTag.range)
            let startTagText = nsSource.substring(with: startTag.range)
            let embeddedLanguage: SyntaxLanguage?
            switch startTag.name {
            case "script":
                embeddedLanguage = scriptEmbeddedLanguage(forStartTagText: startTagText)
            case "style":
                embeddedLanguage = styleEmbeddedLanguage(forStartTagText: startTagText)
            default:
                embeddedLanguage = nil
            }

            let contentEnd: Int
            if let embeddedLanguage {
                contentEnd = rawTextClosingTagStart(
                    in: nsSource,
                    rawTextElementName: startTag.name,
                    searchFrom: contentStart,
                    embeddedLanguage: embeddedLanguage
                ) ?? nsSource.length
            } else {
                contentEnd = rawTextClosingTagStart(
                    in: nsSource,
                    rawTextElementName: startTag.name,
                    from: contentStart
                ) ?? nsSource.length
            }

            // `all` spans from the start tag's `<` through the content end:
            // start-tag interiors can decide supportedness (the type
            // attribute) yet slip the engine's markup guard when a quoted
            // attribute value contains '>', and an insertion between an empty
            // region's tags becomes region content. Zero-length contents are
            // kept for the same reason. `css` mirrors the historical scanning
            // ranges exactly (non-empty content only).
            all.append(NSRange(
                location: startTag.range.location,
                length: contentEnd - startTag.range.location
            ))
            if embeddedLanguage == .css, contentEnd > contentStart {
                css.append(NSRange(location: contentStart, length: contentEnd - contentStart))
            }
            if contentEnd == nsSource.length {
                break
            }

            cursor = contentEnd + 2
        }

        return (all, css)
    }
}
