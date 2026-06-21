import Foundation
import Testing
@testable import SyntaxEditorCore

extension SyntaxHighlighterEngineTests {
    @Test("SyntaxHighlighterEngine classifies Swift reference sample with Xcode-style semantic overlays")
    func highlighterClassifiesSwiftReferenceSampleWithXcodeStyleSemanticOverlays() async throws {
        let engine = sharedSyntaxHighlighterEngine
        let source = try referenceSampleText(named: "Reference.swift")
        let tokens = await engine.render(source: source, language: SyntaxLanguage.swift)

        let expectations: [(text: String, syntaxID: EditorSourceSyntax.ID, styleKey: String, occurrence: String)] = [
            ("MARK:", "mark", "editor.syntax.mark", "// MARK: - Reference highlighting surface"),
            ("Foundation", "plain", "editor.syntax.plain", "import Foundation"),
            ("Observation", "plain", "editor.syntax.plain", "import Observation"),
            ("Renders a compact reference model.", "comment.doc", "editor.syntax.comment.doc", "/// Renders a compact reference model."),
            ("https://example.invalid/reference.", "url", "editor.syntax.url", "https://example.invalid/reference."),
            ("associatedtype", "keyword", "editor.syntax.keyword", "associatedtype Output"),
            ("ReferenceID", "declaration.type", "editor.syntax.declaration.type", "typealias ReferenceID = UUID"),
            ("macro", "keyword", "editor.syntax.keyword", "macro localized"),
            ("localized", "declaration.other", "editor.syntax.declaration.other", "macro localized"),
            ("attached", "keyword", "editor.syntax.keyword", "@attached(member"),
            ("member", "plain", "editor.syntax.plain", "@attached(member"),
            ("Codable", "plain", "editor.syntax.plain", "conformances: Codable"),
            ("module", "plain", "editor.syntax.plain", #"#externalMacro(module: "ReferenceMacros""#),
            ("externalMacro", "keyword", "editor.syntax.keyword", #"#externalMacro(module: "ReferenceMacros""#),
            ("freestanding", "keyword", "editor.syntax.keyword", "@freestanding(expression)"),
            ("propertyWrapper", "keyword", "editor.syntax.keyword", "@propertyWrapper"),
            ("Comparable", "identifier.class.system", "editor.syntax.identifier.class.system", "Value: Comparable"),
            ("ReferenceStore", "declaration.type", "editor.syntax.declaration.type", "final class ReferenceStore"),
            ("OpenReferenceBase", "identifier.type", "editor.syntax.identifier.type", "OpenReferenceBase, @unchecked"),
            ("UUID", "identifier.type.system", "editor.syntax.identifier.type.system", "typealias ReferenceID = UUID"),
            ("load", "identifier.function.system", "editor.syntax.identifier.function.system", "try await load().map"),
            ("Value", "plain", "editor.syntax.plain", "var wrappedValue: Value"),
            ("wrappedValue", "declaration.other", "editor.syntax.declaration.other", "init(wrappedValue: Value"),
            ("create", "declaration.other", "editor.syntax.declaration.other", "for key: Key, create: @Sendable"),
            ("content", "declaration.other", "editor.syntax.declaration.other", "@RowBuilder content:"),
            ("lhs", "declaration.other", "editor.syntax.declaration.other", "func <+> (lhs: ReferenceStore.State"),
            ("rhs", "declaration.other", "editor.syntax.declaration.other", "rhs: ReferenceStore.State"),
            ("@", "plain", "editor.syntax.plain", "@AutoCodable"),
            ("AutoCodable", "plain", "editor.syntax.plain", "@AutoCodable"),
            ("Observable", "identifier.function.system", "editor.syntax.identifier.function.system", "@Observable"),
            ("MainActor", "identifier.class.system", "editor.syntax.identifier.class.system", "@MainActor"),
            ("Clamped", "plain", "editor.syntax.plain", "@Clamped(0...globalLimit)"),
            ("RowBuilder", "plain", "editor.syntax.plain", "@RowBuilder content:"),
            ("AdditionPrecedence", "identifier.type.system", "editor.syntax.identifier.type.system", "higherThan: AdditionPrecedence"),
            ("ReferencePrecedence", "identifier.type", "editor.syntax.identifier.type", "operator <+>: ReferencePrecedence"),
            ("Sendable", "identifier.class.system", "editor.syntax.identifier.class.system", "@unchecked Sendable"),
            ("ReferenceRenderable", "identifier.type", "editor.syntax.identifier.type", "@unchecked Sendable, ReferenceRenderable"),
            ("CaseIterable", "identifier.class.system", "editor.syntax.identifier.class.system", "String, CaseIterable"),
            ("Hashable", "identifier.class.system", "editor.syntax.identifier.class.system", "ID: Hashable"),
            ("Identifiable", "identifier.class.system", "editor.syntax.identifier.class.system", "Identifiable {"),
            ("State", "identifier.type", "editor.syntax.identifier.type", "var state: State = .ready"),
            ("range", "identifier.constant.system", "editor.syntax.identifier.constant.system", "self.range = range"),
            ("Item", "identifier.type", "editor.syntax.identifier.type", "Item(id: UUID()"),
            ("ReferenceID", "identifier.type", "editor.syntax.identifier.type", "[Item<ReferenceID>]"),
            ("sourceLocation", "keyword", "editor.syntax.keyword", "#sourceLocation(file:"),
            ("sourceLocationCheck", "declaration.other", "editor.syntax.declaration.other", "let sourceLocationCheck: Any?"),
            ("=", "plain", "editor.syntax.plain", "progress = 42"),
            ("->", "plain", "editor.syntax.plain", "render() async throws -> [String]"),
            ("#if", "keyword", "editor.syntax.keyword", "#if os(iOS)"),
            ("iOS", "plain", "editor.syntax.plain", "#if os(iOS)"),
            ("#available", "keyword", "editor.syntax.keyword", "if #available(macOS"),
            ("self", "keyword", "editor.syntax.keyword", "self.items = value.items"),
            ("Any", "keyword", "editor.syntax.keyword", "sourceLocationCheck: Any?"),
            ("nil", "keyword", "editor.syntax.keyword", "Any? = nil"),
            ("false", "keyword", "editor.syntax.keyword", "assignment: false"),
            ("item-(?<number>\\d+)-(?<kind>[A-Z]+)", "string", "editor.syntax.string", #"let pattern = #/item-(?<number>\d+)-(?<kind>[A-Z]+)/#"#),
            ("42", "number", "editor.syntax.number", "progress = 42"),
            ("reference.title", "string", "editor.syntax.string", #"#localized("reference.title")"#),
            ("AutoCodable", "declaration.other", "editor.syntax.declaration.other", "macro AutoCodable()"),
        ]

        for expectation in expectations {
            let snapshot = try semanticSnapshot(
                in: tokens,
                source: source,
                text: expectation.text,
                syntaxID: expectation.syntaxID,
                language: .swift,
                inOccurrenceOf: expectation.occurrence
            )
            #expect(snapshot.styleKeys.first == expectation.styleKey)
        }

        let effectiveExpectations: [(text: String, syntaxID: EditorSourceSyntax.ID, styleKey: String, occurrence: String)] = [
            ("isolated", "keyword", "editor.syntax.keyword", "isolated deinit"),
            ("defer", "keyword", "editor.syntax.keyword", "defer { state = .ready }"),
            ("#if", "preprocessor", "editor.syntax.preprocessor", "#if os(iOS)"),
            ("iOS", "preprocessor", "editor.syntax.preprocessor", "#if os(iOS)"),
            ("macOS", "preprocessor", "editor.syntax.preprocessor", "#elseif os(macOS)"),
            ("#else", "preprocessor", "editor.syntax.preprocessor", "#else"),
            ("#endif", "preprocessor", "editor.syntax.preprocessor", "#endif"),
            ("swift", "preprocessor", "editor.syntax.preprocessor", "#if swift(>=5.9)"),
            (">", "preprocessor", "editor.syntax.preprocessor", "#if swift(>=5.9)"),
            ("5.9", "number", "editor.syntax.number", "#if swift(>=5.9)"),
            ("&&", "preprocessor", "editor.syntax.preprocessor", "&& compiler(>=6.0)"),
            ("compiler", "preprocessor", "editor.syntax.preprocessor", "&& compiler(>=6.0)"),
            ("6.0", "number", "editor.syntax.number", "&& compiler(>=6.0)"),
            ("#if", "preprocessor", "editor.syntax.preprocessor", "#if canImport(UIKit"),
            ("#", "keyword", "editor.syntax.keyword", "if #available(macOS"),
            ("#available", "keyword", "editor.syntax.keyword", "if #available(macOS"),
            ("Comparable", "identifier.class.system", "editor.syntax.identifier.class.system", "Value: Comparable"),
            ("Observable", "identifier.function.system", "editor.syntax.identifier.function.system", "@Observable"),
            ("MainActor", "identifier.class.system", "editor.syntax.identifier.class.system", "@MainActor"),
            ("AdditionPrecedence", "identifier.type.system", "editor.syntax.identifier.type.system", "higherThan: AdditionPrecedence"),
            ("Sendable", "identifier.class.system", "editor.syntax.identifier.class.system", "@unchecked Sendable"),
            ("Hashable", "identifier.class.system", "editor.syntax.identifier.class.system", "ID: Hashable"),
            ("Identifiable", "identifier.class.system", "editor.syntax.identifier.class.system", "Identifiable {"),
            ("load", "identifier.function.system", "editor.syntax.identifier.function.system", "try await load().map"),
            ("firstMatch", "plain", "editor.syntax.plain", "pattern.firstMatch"),
            ("output", "plain", "editor.syntax.plain", "?.output.number"),
            ("state", "identifier.variable.system", "editor.syntax.identifier.variable.system", "state.rawValue"),
        ]

        for expectation in effectiveExpectations {
            let snapshot = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: expectation.text,
                syntaxID: expectation.syntaxID,
                language: .swift,
                inOccurrenceOf: expectation.occurrence
            )
            #expect(snapshot.syntaxID == expectation.syntaxID)
            #expect(snapshot.styleKeys.first == expectation.styleKey)
        }

        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "@",
            inOccurrenceOf: "@attached(member"
        ).last == .keyword)

        let zeroLengthTokens = tokens.filter { $0.range.length == 0 }
        if zeroLengthTokens.isEmpty == false {
            let nsSource = source as NSString
            let details = zeroLengthTokens.map { token in
                "\(token.range.location):\(nsSource.substring(with: token.range)):\(token.rawCaptureName)"
            }
            Issue.record("Zero-length tokens: \(details.joined(separator: ", "))")
        }
        #expect(zeroLengthTokens.isEmpty)
    }

    @Test("SyntaxHighlighterEngine aligns Swift attributes with Xcode token classification")
    func highlighterAlignsSwiftAttributesWithXcodeTokenClassification() async throws {
        let source = """
        @attached(member, names: named(FixtureCodingKeys))
        @freestanding(expression)
        macro LocalAttribute() = #externalMacro(module: "FixtureMacros", type: "LocalAttribute")
        @propertyWrapper struct LocalWrapper { var wrappedValue: Int }
        @LocalAttribute
        @Observable
        @MainActor
        @UnknownFixture
        struct SwiftAttributesFixture {
            @LocalWrapper var localValue: Int
            @UnknownFixture var value: Int
        }
        """
        let tokens = await SyntaxHighlighterEngine().render(source: source, language: .swift)

        let expectations: [(text: String, syntaxID: EditorSourceSyntax.ID, styleKey: String, occurrence: String)] = [
            ("attached", "keyword", "editor.syntax.keyword", "@attached(member"),
            ("freestanding", "keyword", "editor.syntax.keyword", "@freestanding(expression)"),
            ("@", "plain", "editor.syntax.plain", "@LocalAttribute"),
            ("LocalAttribute", "plain", "editor.syntax.plain", "@LocalAttribute"),
            ("@", "plain", "editor.syntax.plain", "@LocalWrapper"),
            ("LocalWrapper", "plain", "editor.syntax.plain", "@LocalWrapper"),
            ("@", "identifier.function.system", "editor.syntax.identifier.function.system", "@Observable"),
            ("Observable", "identifier.function.system", "editor.syntax.identifier.function.system", "@Observable"),
            ("@", "identifier.class.system", "editor.syntax.identifier.class.system", "@MainActor"),
            ("MainActor", "identifier.class.system", "editor.syntax.identifier.class.system", "@MainActor"),
            ("@", "plain", "editor.syntax.plain", "@UnknownFixture"),
            ("UnknownFixture", "plain", "editor.syntax.plain", "@UnknownFixture"),
        ]

        for expectation in expectations {
            let snapshot = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: expectation.text,
                syntaxID: expectation.syntaxID,
                language: .swift,
                inOccurrenceOf: expectation.occurrence
            )
            #expect(snapshot.syntaxID == expectation.syntaxID)
            #expect(snapshot.styleKeys.first == expectation.styleKey)
        }
    }

    @Test("SyntaxHighlighterEngine aligns Swift preprocessor macros with Xcode token classification")
    func highlighterAlignsSwiftPreprocessorMacrosWithXcodeTokenClassification() async throws {
        let source = """
        macro FixtureMacro() = #externalMacro(module: "FixtureMacros", type: "FixtureMacro")

        #sourceLocation(file: "SwiftPreprocessorMacros.swift", line: 100)
        let sourceLocationFixture: Any? = nil

        let invocation = #FixtureMacro()
        let selector = #selector(runFixture)
        """
        let tokens = await SyntaxHighlighterEngine().render(source: source, language: .swift)

        let expectations: [(text: String, syntaxID: EditorSourceSyntax.ID, styleKey: String, occurrence: String)] = [
            ("externalMacro", "keyword", "editor.syntax.keyword", "#externalMacro(module:"),
            ("sourceLocation", "preprocessor", "editor.syntax.preprocessor", "#sourceLocation(file:"),
            ("FixtureMacro", "identifier.macro", "editor.syntax.identifier.macro", "#FixtureMacro()"),
            ("selector", "identifier.macro.system", "editor.syntax.identifier.macro.system", "#selector(runFixture)"),
        ]

        for expectation in expectations {
            let snapshot = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: expectation.text,
                syntaxID: expectation.syntaxID,
                language: .swift,
                inOccurrenceOf: expectation.occurrence
            )
            #expect(snapshot.syntaxID == expectation.syntaxID)
            #expect(snapshot.styleKeys.first == expectation.styleKey)
        }
    }

    @Test("SyntaxHighlighterEngine classifies Swift file-local variables and scoped symbols")
    func highlighterClassifiesSwiftFileLocalVariablesAndScopedSymbols() async throws {
        let source = """
        struct LocalModel {
            let value: Int
        }

        enum LocalState {
            case ready
        }

        macro LocalMacro() = #externalMacro(module: "FixtureMacros", type: "LocalMacro")

        func localFunction(_ model: LocalModel, count: Int) -> LocalModel {
            let localValue = count
            print(localValue)
            return LocalModel(value: localValue)
        }

        let title: String = "title"
        let interpolated = "\\(String(describing: title))"
        let tuple: (String, Int) = ("value", 1)
        let metatype = String.self
        let maxValue = Int.max
        typealias ExternalAlias = Double
        func constrained<T>(_ value: T) where T == UInt {}
        let handler: () -> Void = {}
        handler()
        let state = LocalState.ready
        let model = LocalModel(value: 1)
        let output = localFunction(model, count: 2)
        let dotted = Namespace.String.self
        let dottedCall = Namespace.String()
        let expanded = #LocalMacro()
        let external = #ExternalMacro()
        @UnknownFixture var attributed: Int
        """
        let tokens = await SyntaxHighlighterEngine().render(source: source, language: .swift)

        let expectations: [(text: String, syntaxID: EditorSourceSyntax.ID, styleKey: String, occurrence: String)] = [
            ("LocalModel", "identifier.type", "editor.syntax.identifier.type", "_ model: LocalModel"),
            ("Int", "identifier.type.system", "editor.syntax.identifier.type.system", "value: Int"),
            ("String", "identifier.type.system", "editor.syntax.identifier.type.system", "title: String"),
            ("String", "identifier.type.system", "editor.syntax.identifier.type.system", "String(describing: title)"),
            ("String", "identifier.type.system", "editor.syntax.identifier.type.system", "tuple: (String"),
            ("String", "identifier.type.system", "editor.syntax.identifier.type.system", "String.self"),
            ("Int", "identifier.type.system", "editor.syntax.identifier.type.system", "Int.max"),
            ("Double", "identifier.type.system", "editor.syntax.identifier.type.system", "= Double"),
            ("UInt", "identifier.type.system", "editor.syntax.identifier.type.system", "== UInt"),
            ("handler", "identifier.variable", "editor.syntax.identifier.variable", "handler()"),
            ("localFunction", "identifier.function", "editor.syntax.identifier.function", "localFunction(model"),
            ("print", "identifier.function.system", "editor.syntax.identifier.function.system", "print(localValue)"),
            ("model", "identifier.variable", "editor.syntax.identifier.variable", "localFunction(model"),
            ("localValue", "plain", "editor.syntax.plain", "print(localValue)"),
            ("String", "identifier.type.system", "editor.syntax.identifier.type.system", "Namespace.String"),
            ("String", "identifier.type.system", "editor.syntax.identifier.type.system", "Namespace.String()"),
            ("LocalState", "identifier.type", "editor.syntax.identifier.type", "LocalState.ready"),
            ("ready", "identifier.constant", "editor.syntax.identifier.constant", "LocalState.ready"),
            ("LocalModel", "identifier.type", "editor.syntax.identifier.type", "LocalModel(value: 1)"),
            ("LocalMacro", "identifier.macro", "editor.syntax.identifier.macro", "#LocalMacro()"),
            ("ExternalMacro", "plain", "editor.syntax.plain", "#ExternalMacro()"),
        ]

        for expectation in expectations {
            let snapshot = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: expectation.text,
                syntaxID: expectation.syntaxID,
                language: .swift,
                inOccurrenceOf: expectation.occurrence
            )
            #expect(snapshot.syntaxID == expectation.syntaxID)
            #expect(snapshot.styleKeys.first == expectation.styleKey)
        }

        for (text, occurrence) in [
            ("value", "LocalModel(value: 1)"),
            ("module", #"#externalMacro(module: "FixtureMacros""#),
            ("type", #"type: "LocalMacro""#),
        ] {
            let snapshot = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: text,
                syntaxID: .plain,
                language: .swift,
                inOccurrenceOf: occurrence
            )
            #expect(snapshot.syntaxID == .plain)
        }
    }

    @Test("SyntaxHighlighterEngine keeps same-file functions named like system types plain")
    func highlighterKeepsLocalFunctionsNamedLikeSystemTypesPlain() async throws {
        let source = """
        func String() -> Int {
            1
        }

        let value = String()
        """
        let tokens = await SyntaxHighlighterEngine().render(source: source, language: .swift)

        let call = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "String",
            syntaxID: .identifierFunction,
            language: .swift,
            inOccurrenceOf: "value = String()"
        )
        #expect(call.styleKeys.first == "editor.syntax.identifier.function")
    }

    @Test("SyntaxHighlighterEngine limits block-local functions named like system types")
    func highlighterLimitsBlockLocalFunctionsNamedLikeSystemTypes() async throws {
        let source = """
        struct Holder {
            func String() -> Int {
                1
            }
        }

        func render(flag: Bool) {
            if flag {
                func String() -> Int {
                    1
                }
                let local = String()
            }
            let sibling = String()
        }

        let top = String()
        """
        let tokens = await SyntaxHighlighterEngine().render(source: source, language: .swift)

        let localCall = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "String",
            syntaxID: .identifierFunction,
            language: .swift,
            inOccurrenceOf: "local = String()"
        )
        #expect(localCall.styleKeys.first == "editor.syntax.identifier.function")

        let siblingCall = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "String",
            syntaxID: .identifierTypeSystem,
            language: .swift,
            inOccurrenceOf: "sibling = String()"
        )
        #expect(siblingCall.styleKeys.first == "editor.syntax.identifier.type.system")

        let topCall = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "String",
            syntaxID: .identifierTypeSystem,
            language: .swift,
            inOccurrenceOf: "top = String()"
        )
        #expect(topCall.styleKeys.first == "editor.syntax.identifier.type.system")
    }

    @Test("SyntaxHighlighterEngine does not classify shadowed system type names as external")
    func highlighterDoesNotClassifyShadowedSystemTypeNamesAsExternal() async throws {
        let source = """
        struct String {
            let rawValue: Int
        }

        let shadow: String? = nil
        """
        let tokens = await SyntaxHighlighterEngine().render(source: source, language: .swift)

        let shadow = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "String",
            syntaxID: .identifierType,
            language: .swift,
            inOccurrenceOf: "shadow: String?"
        )
        #expect(shadow.styleKeys.first == "editor.syntax.identifier.type")

        let int = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "Int",
            syntaxID: .identifierTypeSystem,
            language: .swift,
            inOccurrenceOf: "rawValue: Int"
        )
        #expect(int.styleKeys.first == "editor.syntax.identifier.type.system")
    }

    @Test("SyntaxHighlighterEngine keeps value and type namespaces separate")
    func highlighterKeepsValueAndTypeNamespacesSeparate() async throws {
        let source = """
        func render() {
            let String = "local"
            let title: String = ""
            _ = String
        }
        """
        let tokens = await SyntaxHighlighterEngine().render(source: source, language: .swift)

        let typeAnnotation = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "String",
            syntaxID: .identifierTypeSystem,
            language: .swift,
            inOccurrenceOf: "title: String"
        )
        #expect(typeAnnotation.styleKeys.first == "editor.syntax.identifier.type.system")

        let valueReference = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "String",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "_ = String"
        )
        #expect(valueReference.styleKeys.first == "editor.syntax.plain")
    }

    @Test("SyntaxHighlighterEngine limits non-function local type shadows to executable braces")
    func highlighterLimitsNonFunctionLocalTypeShadowsToExecutableBraces() async throws {
        let source = """
        let closure = {
            struct String {
                let rawValue: Int
            }
            let local: String? = nil
        }

        let outside: String = ""
        """
        let tokens = await SyntaxHighlighterEngine().render(source: source, language: .swift)

        let localShadow = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "String",
            syntaxID: .identifierType,
            language: .swift,
            inOccurrenceOf: "local: String?"
        )
        #expect(localShadow.styleKeys.first == "editor.syntax.identifier.type")

        let outsideSystem = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "String",
            syntaxID: .identifierTypeSystem,
            language: .swift,
            inOccurrenceOf: "outside: String"
        )
        #expect(outsideSystem.styleKeys.first == "editor.syntax.identifier.type.system")
    }

    @Test("SyntaxHighlighterEngine limits function block local type shadows")
    func highlighterLimitsFunctionBlockLocalTypeShadows() async throws {
        let source = """
        func render(flag: Bool) {
            if flag {
                struct String {}
                let local: String? = nil
            }
            let sibling: String = ""
        }
        """
        let tokens = await SyntaxHighlighterEngine().render(source: source, language: .swift)

        let localShadow = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "String",
            syntaxID: .identifierType,
            language: .swift,
            inOccurrenceOf: "local: String?"
        )
        #expect(localShadow.styleKeys.first == "editor.syntax.identifier.type")

        let siblingSystem = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "String",
            syntaxID: .identifierTypeSystem,
            language: .swift,
            inOccurrenceOf: "sibling: String"
        )
        #expect(siblingSystem.styleKeys.first == "editor.syntax.identifier.type.system")
    }

    @Test("SyntaxHighlighterEngine scopes switch case locals to their clauses")
    func highlighterScopesSwitchCaseLocalsToTheirClauses() async throws {
        let source = """
        struct SwitchScope {
            var value: Int

            func render(_ tag: Int) {
                switch tag {
                case 0:
                    let value = 1
                    _ = value
                default:
                    _ = value
                }
            }
        }
        """
        let tokens = await SyntaxHighlighterEngine().render(source: source, language: .swift)

        let memberValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "default:\n            _ = value"
        )
        #expect(memberValue.styleKeys.first == "editor.syntax.identifier.variable")
    }

    @Test("SyntaxHighlighterEngine indexes multi-line comma value declarations")
    func highlighterIndexesMultiLineCommaValueDeclarations() async throws {
        let source = """
        struct MultiLineScope {
            var value: Int

            func render() {
                let first = 0,
                    value = first
                _ = value
            }
        }
        """
        let tokens = await SyntaxHighlighterEngine().render(source: source, language: .swift)

        let localValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "_ = value"
        )
        #expect(localValue.styleKeys.first == "editor.syntax.plain")
    }

    @Test("SyntaxHighlighterEngine treats Swift typealias and associatedtype declarations as type shadows")
    func highlighterTreatsSwiftTypeAliasesAsTypeShadows() async throws {
        let source = """
        typealias String = Swift.String
        let title: String = ""
        let count: Double = 0

        protocol Loader {
            associatedtype Int
            func load() -> Int
        }
        """
        let tokens = await SyntaxHighlighterEngine().render(source: source, language: .swift)

        let fileAlias = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "String",
            syntaxID: .identifierType,
            language: .swift,
            inOccurrenceOf: "title: String"
        )
        #expect(fileAlias.styleKeys.first == "editor.syntax.identifier.type")

        let systemType = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "Double",
            syntaxID: .identifierTypeSystem,
            language: .swift,
            inOccurrenceOf: "count: Double"
        )
        #expect(systemType.styleKeys.first == "editor.syntax.identifier.type.system")

        let associatedType = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "Int",
            syntaxID: .identifierType,
            language: .swift,
            inOccurrenceOf: "load() -> Int"
        )
        #expect(associatedType.styleKeys.first == "editor.syntax.identifier.type")
    }

    @Test("SyntaxHighlighterEngine limits generic type shadowing to the active scope")
    func highlighterLimitsGenericTypeShadowingToActiveScope() async throws {
        let source = """
        func scopedGeneric<String>(_ value: String) {
            _ = value
        }

        struct Outer {
            struct String {}
            let nested: String
        }

        struct ExtendedOuter {}

        extension ExtendedOuter {
            struct String {}
        }

        struct Box {
            struct String {}
        }

        extension Box {
            func read(_ value: String) {}
        }

        func localTypeShadow() {
            struct String {}
            let local: String = .init()
            _ = local
        }

        let standard: String = ""
        """
        let tokens = await SyntaxHighlighterEngine().render(source: source, language: .swift)

        let genericParameterUse = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "String",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "_ value: String"
        )
        #expect(genericParameterUse.styleKeys.first == "editor.syntax.plain")

        let nestedType = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "String",
            syntaxID: .identifierType,
            language: .swift,
            inOccurrenceOf: "nested: String"
        )
        #expect(nestedType.styleKeys.first == "editor.syntax.identifier.type")

        let standardType = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "String",
            syntaxID: .identifierTypeSystem,
            language: .swift,
            inOccurrenceOf: "standard: String"
        )
        #expect(standardType.styleKeys.first == "editor.syntax.identifier.type.system")

        let nestedTypeInExtension = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "String",
            syntaxID: .identifierType,
            language: .swift,
            inOccurrenceOf: "read(_ value: String)"
        )
        #expect(nestedTypeInExtension.styleKeys.first == "editor.syntax.identifier.type")

        let localFunctionType = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "String",
            syntaxID: .identifierType,
            language: .swift,
            inOccurrenceOf: "local: String"
        )
        #expect(localFunctionType.styleKeys.first == "editor.syntax.identifier.type")
    }

    @Test("SyntaxHighlighterEngine preserves Swift semantic scopes around casts and requirements")
    func highlighterPreservesSwiftSemanticScopesAroundCastsAndRequirements() async throws {
        let source = """
        protocol Renderable {
            func render() -> String
        }

        struct Item {
            let id: String

            func copy() -> String {
                return id
            }
        }

        func genericRender<T>(_ input: T, value: Any) -> Bool {
            let localValue = 1
            let text = value as? String
            let count = value as! Int
            return localValue > 0 && value is Double
        }
        """
        let tokens = await SyntaxHighlighterEngine().render(source: source, language: .swift)

        for (text, occurrence) in [
            ("String", "value as? String"),
            ("Int", "value as! Int"),
            ("Double", "value is Double"),
        ] {
            let snapshot = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: text,
                syntaxID: .identifierTypeSystem,
                language: .swift,
                inOccurrenceOf: occurrence
            )
            #expect(snapshot.styleKeys.first == "editor.syntax.identifier.type.system")
        }

        let memberReference = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "id",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "return id"
        )
        #expect(memberReference.styleKeys.first == "editor.syntax.identifier.variable")

        let localReference = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "localValue",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "localValue > 0"
        )
        #expect(localReference.styleKeys.first == "editor.syntax.plain")
    }

    @Test("SyntaxHighlighterEngine classifies Swift directive condition operators")
    func highlighterClassifiesSwiftDirectiveConditionOperators() async throws {
        let engine = sharedSyntaxHighlighterEngine
        let source = """
        #if !DEBUG
        let mode = "release"
        #elseif canImport(UIKit, _version: 17.0)
        let mode = "versioned"
        #elseif swift(>=5.9) && compiler(>=6.0)
        let mode = "modern"
        #endif
        if #available(macOS 15.0, *) {
            let mode = "available"
        }
        """
        let tokens = await engine.render(source: source, language: SyntaxLanguage.swift)

        let expectations: [(text: String, syntaxID: EditorSourceSyntax.ID, styleKey: String, occurrence: String)] = [
            ("#if", "preprocessor", "editor.syntax.preprocessor", "#if !DEBUG"),
            ("!", "preprocessor", "editor.syntax.preprocessor", "#if !DEBUG"),
            ("DEBUG", "preprocessor", "editor.syntax.preprocessor", "#if !DEBUG"),
            ("#elseif", "preprocessor", "editor.syntax.preprocessor", "#elseif canImport(UIKit"),
            ("canImport", "preprocessor", "editor.syntax.preprocessor", "#elseif canImport(UIKit"),
            ("_", "preprocessor", "editor.syntax.preprocessor", "_version: 17.0"),
            (":", "preprocessor", "editor.syntax.preprocessor", "_version: 17.0"),
            ("17.0", "number", "editor.syntax.number", "_version: 17.0"),
            ("#elseif", "preprocessor", "editor.syntax.preprocessor", "#elseif swift(>=5.9)"),
            (">", "preprocessor", "editor.syntax.preprocessor", "#elseif swift(>=5.9)"),
            ("5.9", "number", "editor.syntax.number", "#elseif swift(>=5.9)"),
            ("&&", "preprocessor", "editor.syntax.preprocessor", "&& compiler(>=6.0)"),
            ("6.0", "number", "editor.syntax.number", "&& compiler(>=6.0)"),
            ("#endif", "preprocessor", "editor.syntax.preprocessor", "#endif"),
            ("#available", "keyword", "editor.syntax.keyword", "if #available(macOS"),
        ]

        for expectation in expectations {
            let snapshot = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: expectation.text,
                syntaxID: expectation.syntaxID,
                language: .swift,
                inOccurrenceOf: expectation.occurrence
            )
            #expect(snapshot.syntaxID == expectation.syntaxID)
            #expect(snapshot.styleKeys.first == expectation.styleKey)
        }
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "17.0",
            inOccurrenceOf: "_version: 17.0"
        ).contains(.preprocessor) == false)
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "_",
            inOccurrenceOf: "_version: 17.0"
        ).contains(.character) == false)
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "#available",
            inOccurrenceOf: "if #available(macOS"
        ).contains(.identifierMacroSystem) == false)
    }

    @Test("SyntaxHighlighterEngine keeps preprocessor fallback scoped to directive errors")
    func highlighterKeepsPreprocessorFallbackScopedToDirectiveErrors() async {
        let source = "let x: = y\nlet values = [foo: ]"
        let tokens = await SyntaxHighlighterEngine().render(source: source, language: SyntaxLanguage.swift)

        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: ":",
            inOccurrenceOf: "let x: = y"
        ).contains(.preprocessor) == false)
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: ":",
            inOccurrenceOf: "[foo: ]"
        ).contains(.preprocessor) == false)
    }

    @Test("SyntaxHighlighterEngine keeps contextual Swift keywords as identifiers")
    func highlighterKeepsContextualSwiftKeywordsAsIdentifiers() async throws {
        let engine = sharedSyntaxHighlighterEngine
        let source = """
        func contextualNames() -> Int {
            let async = 1
            let get = 2
            let left = 3
            let `defer` = 4
            return async + get + left + `defer`
        }

        struct KeywordMembers {
            var `defer`: Int
        }

        func read(_ value: KeywordMembers) -> Int {
            value.defer
        }

        precedencegroup ContextualPrecedence {
            associativity: left
            higherThan: AdditionPrecedence
            assignment: false
        }
        """
        let tokens = await engine.render(source: source, language: SyntaxLanguage.swift)

        for (text, occurrence) in [
            ("async", "let async = 1"),
            ("get", "let get = 2"),
            ("left", "let left = 3"),
            ("defer", "let `defer` = 4"),
            ("defer", "value.defer"),
        ] {
            let ids = syntaxIDs(
                in: tokens,
                source: source,
                text: text,
                inOccurrenceOf: occurrence
            )
            #expect(ids.contains(.keyword) == false)
            #expect(ids.contains(.plain))
        }

        let precedenceLeft = try semanticSnapshot(
            in: tokens,
            source: source,
            text: "left",
            syntaxID: "keyword",
            language: .swift,
            inOccurrenceOf: "associativity: left"
        )
        #expect(precedenceLeft.styleKeys.first == "editor.syntax.keyword")
    }

    @Test("SyntaxHighlighterEngine classifies unqualified Swift member references")
    func highlighterClassifiesUnqualifiedSwiftMemberReferences() async throws {
        let engine = sharedSyntaxHighlighterEngine
        let source = """
        let topLevelClosure = {
            let temp = 1
            return temp
        }

        struct Collision {
            let id: String

            init(id: String) {
                self.id = id
            }

            func copy() -> String {
                return id
            }

            func count() -> Int {
                let count: Int = self.id.count
                return count
            }

            func shadow(id: String) -> String {
                return id.uppercased()
            }

            func anonymous(_ id: String) -> String {
                return id.lowercased()
            }
        }

        struct BlockShadow {
            let value: Int

            func read(_ flag: Bool) -> Int {
                let copied = value
                if flag {
                    let value = 0
                    _ = value
                }
                return value + copied + self.value
            }
        }

        struct SameLineShadow {
            let value: Int

            func read() -> Int {
                let value = value; _ = value
                return self.value
            }
        }

        struct UppercaseVariable {
            let URL: String

            func read() -> String {
                let copy = URL
                return copy
            }
        }

        struct MultilineInitializerShadow {
            let value: Int

            func read() -> Int {
                let value =
                    value
                _ = value
                return self.value
            }
        }

        struct ForLoopHeaderCollision {
            let value: Int
            let values: [Int]

            func read() {
                value.description
                for item in values {
                    _ = item
                }
                _ = value
            }
        }

        struct ComparisonShadow {
            let value: Int

            func read(_ lhs: Int, _ rhs: Int) -> Int {
                let value = lhs<rhs ? 1 : 0
                return value
            }
        }

        struct ConditionalShadow {
            let value: Int

            func read(_ optional: Int?) -> Int {
                if
                    let value = optional
                {
                    _ = value
                }
                return value + 1
            }
        }

        struct OptionalConditionalShadow {
            let value: Int?

            func read() -> Int {
                if let value = value, value > 0 {
                    return value
                }
                return 0
            }
        }

        struct GuardShadow {
            let value: Int?

            func read() -> Int {
                guard let value = value else {
                    return self.value ?? 0
                }
                return value
            }

            func readTrailing() -> Int {
                guard let value = value, value > 0 else {
                    return self.value ?? 0
                }
                return value
            }
        }

        struct InitCallShadow {
            let value: Int

            func read() -> Int {
                _ = InitCallShadow.init(value: value)
                if value > 0 {
                    return value
                }
                return value
            }
        }

        struct OptionalLabelShadow {
            let value: Int

            func update(value: Int) {}
            func throwing(value: Int) throws -> Int { value }

            func read(_ optional: OptionalLabelShadow?) {
                optional?.update(value: 1)
                _ = try? throwing(value: 1)
            }
        }

        struct UppercaseLabelShadow {
            let URL: Int

            func make(String: Int, URL: Int) {}

            func read() {
                make(String: 1, URL: URL)
            }

            func dictionary() {
                let values: [String: Int] = [:]
                _ = values
            }
        }

        struct ClosureShadow {
            let value: Int
            let values: [Int]

            func read() -> Int {
                values.forEach { value in
                    _ = value
                }
                _ = values.count
                let mapped = values.map { value in value }
                return mapped.first ?? value
            }
        }

        enum AssociatedPattern {
            case success(Int)
            case failure
        }

        struct AssociatedPatternShadow {
            let value: Int

            func inline(_ state: AssociatedPattern) {
                switch state {
                case .success(let value):
                    _ = value
                case .failure:
                    _ = value
                default:
                    _ = self.value
                }
            }

            func leading(_ state: AssociatedPattern) {
                switch state {
                case let .success(value):
                    _ = value
                default:
                    _ = self.value
                }
            }

            func conditional(_ state: AssociatedPattern) {
                if case let .success(value) = state {
                    _ = value
                }
            }

            func guardConditional(_ state: AssociatedPattern) {
                guard case let .success(value) = state else {
                    return
                }
                _ = value
            }

            func compactCase(_ state: AssociatedPattern) {
                switch state {
                case .failure: let value = 0; _ = value
                default: _ = self.value
                }
            }
        }

        struct PatternDeclarationShadow {
            let value: Int

            func tuple(_ pair: (Int, Int)) -> Int {
                let (value, _) = pair
                return value
            }

            func comma() -> Int {
                let first = 0, value = 1
                return value + first
            }

            func chained() -> Int {
                let value = 1, copy = value
                return copy
            }
        }

        struct A {
            struct State {
                let value: Int

                func read() -> Int {
                    return value + 1
                }
            }
        }

        struct B {
            struct State {
                func read() -> Int {
                    return value + 2
                }
            }
        }

        struct OuterLeak {
            let value: Int

            struct Inner {
                func read() -> Int {
                    return value + 5
                }
            }
        }

        struct AccessorShadow {
            let value: Int

            var computed: Int {
                let value = 0
                return value
            }
        }

        struct QualifiedExtension {
            struct State {
                let value: Int
            }
        }

        extension QualifiedExtension.State {
            func read() -> Int {
                return value + 3
            }
        }

        struct ExtensionDeclaredNested {}

        extension ExtensionDeclaredNested {
            struct State {
                let value: Int
            }
        }

        extension ExtensionDeclaredNested.State {
            func read() -> Int {
                return value + 6
            }
        }

        struct DefaultClosure {
            let value: Int

            func read(_ action: () -> Void = {}) -> Int {
                let value = 0
                action()
                return value + 4
            }

            func choose(_ flag: Bool, fallback: Int) -> Int {
                return flag ? value : fallback
            }
        }

        struct PatternShadow {
            let value: Int
            let values: [Int]
            let pairs: [(Int, Int)]
            let states: [AssociatedPattern]

            func read() {
                for value in values {
                    _ = value
                }

                for (value, _) in pairs {
                    _ = value
                }

                for case let .success(value) in states {
                    _ = value
                }

                switch value {
                case let value:
                    switch value {
                    case 0:
                        break
                    default:
                        break
                    }
                    _ = value
                }
                let afterSwitch = value

                do {
                    throw NSError()
                } catch let value {
                    _ = value
                }
            }
        }
        """
        let tokens = await engine.render(source: source, language: SyntaxLanguage.swift)

        let topLevelClosureLocal = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "temp",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "return temp"
        )
        #expect(topLevelClosureLocal.styleKeys.first == "editor.syntax.plain")

        let memberID = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "id",
            syntaxID: .identifierVariableSystem,
            language: .swift,
            inOccurrenceOf: "self.id = id"
        )
        #expect(memberID.styleKeys.first == "editor.syntax.identifier.variable.system")

        let propertyID = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "id",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "return id"
        )
        #expect(propertyID.styleKeys.first == "editor.syntax.identifier.variable")

        let shadowedID = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "id",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "return id.uppercased()"
        )
        #expect(shadowedID.styleKeys.first == "editor.syntax.plain")

        let anonymousID = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "id",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "return id.lowercased()"
        )
        #expect(anonymousID.styleKeys.first == "editor.syntax.plain")

        let selfLineType = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "Int",
            syntaxID: .identifierTypeSystem,
            language: .swift,
            inOccurrenceOf: "count: Int = self.id.count"
        )
        #expect(selfLineType.styleKeys.first == "editor.syntax.identifier.type.system")

        let blockLocalValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "_ = value"
        )
        #expect(blockLocalValue.styleKeys.first == "editor.syntax.plain")

        let memberBeforeBlockShadow = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "copied = value"
        )
        #expect(memberBeforeBlockShadow.styleKeys.first == "editor.syntax.identifier.variable")

        let memberAfterBlock = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "return value + copied + self.value"
        )
        #expect(memberAfterBlock.styleKeys.first == "editor.syntax.identifier.variable")

        let sameLineInitializerMember = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "= value; _"
        )
        #expect(sameLineInitializerMember.styleKeys.first == "editor.syntax.identifier.variable")

        let sameLineLocalValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "; _ = value"
        )
        #expect(sameLineLocalValue.styleKeys.first == "editor.syntax.plain")

        let uppercaseVariable = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "URL",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "copy = URL"
        )
        #expect(uppercaseVariable.styleKeys.first == "editor.syntax.identifier.variable")

        let multilineInitializerMember = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "=\n            value"
        )
        #expect(multilineInitializerMember.styleKeys.first == "editor.syntax.identifier.variable")

        let multilineLocalValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "_ = value\n        return self.value\n    }\n}\n\nstruct ForLoopHeaderCollision"
        )
        #expect(multilineLocalValue.styleKeys.first == "editor.syntax.plain")

        let forLoopPrecedingMember = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "value.description"
        )
        #expect(forLoopPrecedingMember.styleKeys.first == "editor.syntax.identifier.variable")

        let forLoopFollowingMember = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "_ = value\n    }\n}\n\nstruct ComparisonShadow"
        )
        #expect(forLoopFollowingMember.styleKeys.first == "editor.syntax.identifier.variable")

        let destructuringDeclarationValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "let (value, _) = pair"
        )
        #expect(destructuringDeclarationValue.styleKeys.first == "editor.syntax.plain")

        let comparisonLocalValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "return value\n    }\n}\n\nstruct ConditionalShadow"
        )
        #expect(comparisonLocalValue.styleKeys.first == "editor.syntax.plain")

        let conditionalLocalValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "{\n            _ = value"
        )
        #expect(conditionalLocalValue.styleKeys.first == "editor.syntax.plain")

        let memberAfterConditional = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "return value + 1"
        )
        #expect(memberAfterConditional.styleKeys.first == "editor.syntax.identifier.variable")

        let conditionalBindingInitializerValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "= value, value > 0"
        )
        #expect(conditionalBindingInitializerValue.styleKeys.first == "editor.syntax.identifier.variable")

        let conditionalBindingBodyValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "{\n            return value\n        }\n        return 0"
        )
        #expect(conditionalBindingBodyValue.styleKeys.first == "editor.syntax.plain")

        let conditionalBindingLaterClauseValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: ", value > 0"
        )
        #expect(conditionalBindingLaterClauseValue.styleKeys.first == "editor.syntax.plain")

        let guardBindingInitializerValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "= value else"
        )
        #expect(guardBindingInitializerValue.styleKeys.first == "editor.syntax.identifier.variable")

        let guardBindingTrailingClauseValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: ", value > 0 else"
        )
        #expect(guardBindingTrailingClauseValue.styleKeys.first == "editor.syntax.plain")

        let guardBindingBodyValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "return value\n    }\n}\n\nstruct InitCallShadow"
        )
        #expect(guardBindingBodyValue.styleKeys.first == "editor.syntax.plain")

        let initCallBlockValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "if value > 0"
        )
        #expect(initCallBlockValue.styleKeys.first == "editor.syntax.identifier.variable")

        let optionalChainLabelValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "optional?.update(value: 1)"
        )
        #expect(optionalChainLabelValue.styleKeys.first == "editor.syntax.plain")

        let tryOptionalLabelValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "try? throwing(value: 1)"
        )
        #expect(tryOptionalLabelValue.styleKeys.first == "editor.syntax.plain")

        let uppercaseStringLabel = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "String",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "make(String: 1"
        )
        #expect(uppercaseStringLabel.styleKeys.first == "editor.syntax.plain")

        let uppercaseURLLabel = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "URL",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "make(String: 1, URL: URL)"
        )
        #expect(uppercaseURLLabel.styleKeys.first == "editor.syntax.plain")

        let uppercaseURLArgumentValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "URL",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: ": URL)"
        )
        #expect(uppercaseURLArgumentValue.styleKeys.first == "editor.syntax.identifier.variable")

        let dictionaryKeyType = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "String",
            syntaxID: .identifierTypeSystem,
            language: .swift,
            inOccurrenceOf: "values: [String: Int]"
        )
        #expect(dictionaryKeyType.styleKeys.first == "editor.syntax.identifier.type.system")

        let closureParameterValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "in value }"
        )
        #expect(closureParameterValue.styleKeys.first == "editor.syntax.plain")

        let memberAfterClosure = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "?? value"
        )
        #expect(memberAfterClosure.styleKeys.first == "editor.syntax.identifier.variable")

        let memberCollectionAfterClosure = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "values",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "_ = values.count"
        )
        #expect(memberCollectionAfterClosure.styleKeys.first == "editor.syntax.identifier.variable")

        let inlineAssociatedCaseValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "case .success(let value):"
        )
        #expect(inlineAssociatedCaseValue.styleKeys.first == "editor.syntax.plain")

        let memberAfterInlineAssociatedCase = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "case .failure:\n            _ = value"
        )
        #expect(memberAfterInlineAssociatedCase.styleKeys.first == "editor.syntax.identifier.variable")

        let leadingAssociatedCaseValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "case let .success(value):"
        )
        #expect(leadingAssociatedCaseValue.styleKeys.first == "editor.syntax.plain")

        let conditionalCaseValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "{\n            _ = value\n        }\n    }\n\n    func guardConditional"
        )
        #expect(conditionalCaseValue.styleKeys.first == "editor.syntax.plain")

        let guardCaseValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "return\n        }\n        _ = value"
        )
        #expect(guardCaseValue.styleKeys.first == "editor.syntax.plain")

        let compactCaseLocalValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "; _ = value\n        default"
        )
        #expect(compactCaseLocalValue.styleKeys.first == "editor.syntax.plain")

        let tuplePatternValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "pair\n        return value"
        )
        #expect(tuplePatternValue.styleKeys.first == "editor.syntax.plain")

        let commaPatternValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "1\n        return value + first"
        )
        #expect(commaPatternValue.styleKeys.first == "editor.syntax.plain")

        let chainedBindingInitializerValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "copy = value"
        )
        #expect(chainedBindingInitializerValue.styleKeys.first == "editor.syntax.plain")

        let nestedMemberValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "return value + 1"
        )
        #expect(nestedMemberValue.styleKeys.first == "editor.syntax.identifier.variable")

        let unrelatedNestedMemberValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "return value + 2"
        )
        #expect(unrelatedNestedMemberValue.styleKeys.first == "editor.syntax.plain")

        let outerMemberLeakValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "return value + 5"
        )
        #expect(outerMemberLeakValue.styleKeys.first == "editor.syntax.plain")

        let accessorLocalValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "computed: Int {\n        let value = 0\n        return value"
        )
        #expect(accessorLocalValue.styleKeys.first == "editor.syntax.plain")

        let qualifiedExtensionMemberValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "return value + 3"
        )
        #expect(qualifiedExtensionMemberValue.styleKeys.first == "editor.syntax.identifier.variable")

        let extensionDeclaredNestedMemberValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "return value + 6"
        )
        #expect(extensionDeclaredNestedMemberValue.styleKeys.first == "editor.syntax.identifier.variable")

        let defaultClosureLocalValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "return value + 4"
        )
        #expect(defaultClosureLocalValue.styleKeys.first == "editor.syntax.plain")

        let ternaryMemberValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "flag ? value : fallback"
        )
        #expect(ternaryMemberValue.styleKeys.first == "editor.syntax.identifier.variable")

        let forPatternValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "for value in values {\n            _ = value"
        )
        #expect(forPatternValue.styleKeys.first == "editor.syntax.plain")

        let destructuredForPatternValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "_) in pairs {\n            _ = value"
        )
        #expect(destructuredForPatternValue.styleKeys.first == "editor.syntax.plain")

        let caseForPatternValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: ") in states {\n            _ = value"
        )
        #expect(caseForPatternValue.styleKeys.first == "editor.syntax.plain")

        let casePatternValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "case let value:"
        )
        #expect(casePatternValue.styleKeys.first == "editor.syntax.plain")

        let memberAfterCasePattern = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "afterSwitch = value"
        )
        #expect(memberAfterCasePattern.styleKeys.first == "editor.syntax.identifier.variable")

        let catchPatternValue = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "value",
            syntaxID: .plain,
            language: .swift,
            inOccurrenceOf: "catch let value {\n            _ = value"
        )
        #expect(catchPatternValue.styleKeys.first == "editor.syntax.plain")
    }

    @Test("SyntaxHighlighterEngine does not duplicate Swift semantic overlays during incremental updates")
    func highlighterKeepsSwiftSemanticOverlaysStableAcrossIncrementalUpdates() async throws {
        let source = try referenceSampleText(named: "Reference.swift")
        let updatedSource = source.replacingOccurrences(
            of: "Reference highlighting surface",
            with: "Reference highlighting surface updated"
        )
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.swift)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.swift,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.swift)

        #expect(incremental.tokens == full.tokens)
        #expect(refreshRangeUnion(incremental).length < updatedSource.utf16.count)
        #expect(Set(incremental.tokens.map { "\($0.range.location):\($0.range.length):\($0.rawCaptureName)" }).count == incremental.tokens.count)
    }

    @Test("SyntaxHighlighterEngine keeps Swift safe reference edits local")
    func highlighterKeepsSwiftSafeReferenceEditsLocal() async throws {
        let source = """
        let item = 1

        func render() -> Int {
            return item + 1
        }
        """
        let updatedSource = source.replacingOccurrences(of: "item + 1", with: "item + 2")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.swift)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.swift,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.swift)

        #expect(incremental.tokens == full.tokens)
        #expect(refreshRangeUnion(incremental).length < updatedSource.utf16.count)

        _ = try effectiveSemanticSnapshot(
            in: incremental.tokens,
            source: updatedSource,
            text: "item",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "return item + 2"
        )
    }

    @Test("SyntaxHighlighterEngine keeps large Swift value edits scoped")
    func highlighterKeepsLargeSwiftValueEditsScoped() async throws {
        let declarations = (0..<3_000)
            .map { "let value\($0) = \($0)" }
            .joined(separator: "\n")
        let source = """
        \(declarations)

        func render() -> Int {
            let local = 1
            return local
        }
        """
        let updatedSource = source.replacingOccurrences(of: "let local = 1", with: "let local = 12")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.swift)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.swift,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.swift)

        #expect(incremental.tokens == full.tokens)
        #expect(refreshRangeUnion(incremental).length < 256)
    }

    @Test("SyntaxHighlighterEngine returns replacement token payloads for incremental updates")
    func highlighterReturnsReplacementTokenPayloadsForIncrementalUpdates() async throws {
        let source = """
        let value = 1

        func render() -> Int {
            return value
        }
        """
        let updatedSource = source.replacingOccurrences(of: "return value", with: "return value + 1")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let engine = SyntaxHighlighterEngine()

        let reset = await engine.reset(source: source, language: SyntaxLanguage.swift, revision: 0)
        let update = await engine.update(
            source: updatedSource,
            language: SyntaxLanguage.swift,
            mutation: mutation,
            revision: 1
        )
        let currentTokens = await engine.currentTokensForTesting()

        #expect(reset.tokenPayload == .fullSnapshot)
        #expect(update.tokenPayload == .replacement)
        #expect(update.containsCompleteTokenSnapshot == false)
        #expect(update.tokens.count < currentTokens.count)
        #expect(Set(update.tokens.map { "\($0.range.location):\($0.range.length):\($0.rawCaptureName):\($0.isSemanticOverlay)" }).count == update.tokens.count)
        #expect(update.tokens.allSatisfy {
            token in update.refreshRanges.contains {
                SyntaxEditorRangeUtilities.intersection(of: token.range, and: $0).length > 0
            }
        })
    }

    @Test("SyntaxHighlighterEngine keeps complete refresh covering skipped Swift syntactic fast pass")
    func highlighterKeepsCompleteRefreshCoveringSkippedSwiftSyntacticFastPass() async throws {
        let source = """
        let message = \"""
        first
        second
        \"""
        let tail = 1
        """
        let updatedSource = source.replacingOccurrences(of: "first", with: "first!")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let engine = SyntaxHighlighterEngine()

        _ = await engine.reset(source: source, language: SyntaxLanguage.swift, revision: 0)
        let phases = await engine.updatePhases(
            source: updatedSource,
            language: SyntaxLanguage.swift,
            mutation: mutation,
            revision: 1
        )
        var iterator = phases.makeAsyncIterator()
        let syntacticFastPass = try #require(await iterator.next())
        let complete = try #require(await iterator.next())

        #expect(syntacticFastPass.phase == .syntacticFastPass)
        #expect(complete.phase == .complete)
        #expect(
            SyntaxEditorRangeUtilities.intersection(
                of: refreshRangeUnion(complete),
                and: refreshRangeUnion(syntacticFastPass)
            ) == refreshRangeUnion(syntacticFastPass)
        )
    }

    @Test("SyntaxHighlighterEngine keeps Swift initializer edits local")
    func highlighterKeepsSwiftInitializerEditsLocal() async throws {
        let source = """
        let item = 1

        func render() -> Int {
            return item + 1
        }
        """
        let updatedSource = source.replacingOccurrences(of: "let item = 1", with: "let item = 2")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.swift)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.swift,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.swift)

        #expect(incremental.tokens == full.tokens)
        #expect(refreshRangeUnion(incremental).length < updatedSource.utf16.count)
    }

    @Test("SyntaxHighlighterEngine rebuilds Swift semantic index after same-length closure parameter edits")
    func highlighterRebuildsSwiftSemanticIndexAfterSameLengthClosureParameterEdits() async throws {
        let source = """
        func render(_ values: [Double]) -> [Double] {
            values.map { foo in
                foo + 1
            }
        }
        """
        let updatedSource = source.replacingOccurrences(of: "foo", with: "sin")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.swift)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.swift,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.swift)

        #expect(incremental.tokens == full.tokens)
    }

    @Test("SyntaxHighlighterEngine re-queries Swift identifiers that become keywords")
    func highlighterRequeriesSwiftIdentifiersThatBecomeKeywords() async throws {
        let source = "let value = tru\n"
        let updatedSource = "let value = true\n"
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.swift)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.swift,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.swift)
        let keywordRange = (updatedSource as NSString).range(of: "true")

        #expect(highlightTokensMatch(incremental.tokens, full.tokens))
        #expect(incremental.tokens.contains {
            tokenIntersects($0, range: keywordRange, syntaxID: .keyword, language: .swift)
        })
    }

    @Test("SyntaxHighlighterEngine rebuilds Swift semantic index after source-length edits")
    func highlighterRebuildsSwiftSemanticIndexAfterSourceLengthEdits() async throws {
        let source = """
        let item = 1

        func render() -> Int {
            return item + 1
        }
        """
        let prefix = "// inserted comment\n"
        let prefixedSource = prefix + source
        let updatedSource = prefixedSource.replacingOccurrences(of: "item + 1", with: "item + 2")
        let referenceMutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: prefixedSource, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.swift)
        _ = await incrementalEngine.update(
            previousSource: source,
            source: prefixedSource,
            language: SyntaxLanguage.swift,
            mutation: SyntaxEditorTextChange.Replacement(location: 0, length: 0, replacement: prefix)
        )
        let incremental = await incrementalEngine.update(
            previousSource: prefixedSource,
            source: updatedSource,
            language: SyntaxLanguage.swift,
            mutation: referenceMutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.swift)

        #expect(incremental.tokens == full.tokens)
        #expect(refreshRangeUnion(incremental).length < updatedSource.utf16.count)
        _ = try effectiveSemanticSnapshot(
            in: incremental.tokens,
            source: updatedSource,
            text: "item",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "return item + 2"
        )
    }

    @Test("SyntaxHighlighterEngine keeps Swift semantic index after EOF append past trailing newline")
    func highlighterKeepsSwiftSemanticIndexAfterEOFAppendPastTrailingNewline() async throws {
        let source = "let item = 1\n"
        let appendedText = """
        func render() -> Int {
            return item
        }
        """
        let appendedSource = source + appendedText
        let updatedSource = appendedSource.replacingOccurrences(of: "return item", with: "return item + 1")
        let appendMutation = SyntaxEditorTextChange.Replacement(
            location: source.utf16.count,
            length: 0,
            replacement: appendedText
        )
        let referenceMutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: appendedSource, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.swift)
        _ = await incrementalEngine.update(
            previousSource: source,
            source: appendedSource,
            language: SyntaxLanguage.swift,
            mutation: appendMutation
        )
        let incremental = await incrementalEngine.update(
            previousSource: appendedSource,
            source: updatedSource,
            language: SyntaxLanguage.swift,
            mutation: referenceMutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.swift)

        #expect(incremental.tokens == full.tokens)
        _ = try effectiveSemanticSnapshot(
            in: incremental.tokens,
            source: updatedSource,
            text: "item",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "return item + 1"
        )
    }

    @Test("SyntaxHighlighterEngine removes Swift semantic overlays after declaration syntax removal")
    func highlighterRemovesSwiftSemanticOverlaysAfterDeclarationSyntaxRemoval() async throws {
        let source = """
        let item = 1

        func render() -> Int {
            return item + 1
        }
        """
        let updatedSource = source.replacingOccurrences(of: "let item = 1", with: "item = 1")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.swift)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.swift,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.swift)
        let nsSource = updatedSource as NSString
        let returnRange = nsSource.range(of: "return item + 1")
        let itemRange = nsSource.range(of: "item", options: [], range: returnRange)

        #expect(incremental.tokens == full.tokens)
        #expect(incremental.tokens.contains {
            tokenIntersects($0, range: itemRange, syntaxID: .identifierVariable, language: .swift)
        } == false)
    }

    @Test("SyntaxHighlighterEngine removes Swift semantic overlays after declaration line break deletion")
    func highlighterRemovesSwiftSemanticOverlaysAfterDeclarationLineBreakDeletion() async throws {
        let source = """
        // disabled
        let item = 1

        func render() -> Int {
            return item
        }
        """
        let nsSource = source as NSString
        let deletedLineBreakRange = nsSource.range(of: "\nlet item")
        let deletedLineBreakLocation = try #require(
            deletedLineBreakRange.location == NSNotFound ? nil : deletedLineBreakRange.location
        )
        let mutation = SyntaxEditorTextChange.Replacement(
            location: deletedLineBreakLocation,
            length: 1,
            replacement: ""
        )
        let updatedSource = nsSource.replacingCharacters(
            in: NSRange(location: deletedLineBreakLocation, length: 1),
            with: ""
        )
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.swift)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.swift,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.swift)
        let updatedNSString = updatedSource as NSString
        let returnRange = updatedNSString.range(of: "return item")
        let itemRange = updatedNSString.range(of: "item", options: [], range: returnRange)

        #expect(incremental.tokens == full.tokens)
        #expect(incremental.tokens.contains {
            tokenIntersects($0, range: itemRange, syntaxID: .identifierVariable, language: .swift)
        } == false)
    }

    @Test("SyntaxHighlighterEngine uses Swift parser invalidation beyond semantic line ranges")
    func highlighterUsesSwiftParserInvalidationBeyondSemanticLineRanges() async throws {
        let source = """
        let first = 1
        let second = 2
        let third = 3
        """
        let updatedSource = source.replacingOccurrences(of: "let second = 2", with: "/* let second = 2")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.swift)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.swift,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.swift)

        #expect(incremental.tokens == full.tokens)
    }

    @Test("SyntaxHighlighterEngine removes stale Swift overlays after identifier typing edits")
    func highlighterRemovesStaleSwiftOverlaysAfterIdentifierTypingEdits() async throws {
        let source = """
        let item = 1

        func render() -> Int {
            return item
        }
        """
        let updatedSource = source.replacingOccurrences(of: "return item", with: "return items")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.swift)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.swift,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.swift)

        #expect(incremental.tokens == full.tokens)
        #expect(refreshRangeUnion(incremental).length < updatedSource.utf16.count)
        #expect(
            syntaxIDs(
                in: incremental.tokens,
                source: updatedSource,
                text: "items",
                inOccurrenceOf: "return items"
            ).last != .identifierVariable
        )
    }

    @Test("SyntaxHighlighterEngine reapplies Swift semantic overlays after distant declaration edits")
    func highlighterReappliesSwiftSemanticOverlaysAfterDistantDeclarationEdits() async throws {
        let source = """
        let item = 1

        func render() -> Int {
            return item
        }
        """
        let updatedSource = source.replacingOccurrences(of: "item", with: "value")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.swift)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.swift,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.swift)

        #expect(incremental.tokens == full.tokens)
        #expect(Set(incremental.tokens.map { "\($0.range.location):\($0.range.length):\($0.rawCaptureName)" }).count == incremental.tokens.count)

        let nsUpdatedSource = updatedSource as NSString
        let returnLineRange = nsUpdatedSource.range(of: "return value")
        let returnValueRange = nsUpdatedSource.range(of: "value", options: [], range: returnLineRange)
        #expect(SyntaxEditorRangeUtilities.intersection(of: refreshRangeUnion(incremental), and: returnValueRange) == returnValueRange)

        let valueReference = try effectiveSemanticSnapshot(
            in: incremental.tokens,
            source: updatedSource,
            text: "value",
            syntaxID: .identifierVariable,
            language: .swift,
            inOccurrenceOf: "return value"
        )
        #expect(valueReference.styleKeys.first == "editor.syntax.identifier.variable")
    }

    @Test("SyntaxHighlighterEngine refreshes distant Swift references after declaration head edits")
    func highlighterRefreshesDistantSwiftReferencesAfterDeclarationHeadEdits() async throws {
        let source = """
        let item = 1

        func render() -> Int {
            return item
        }
        """
        let updatedSource = source.replacingOccurrences(of: "let item", with: "let value")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.swift)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.swift,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.swift)
        let nsUpdatedSource = updatedSource as NSString
        let returnLineRange = nsUpdatedSource.range(of: "return item")
        let returnItemRange = nsUpdatedSource.range(of: "item", options: [], range: returnLineRange)

        #expect(incremental.tokens == full.tokens)
        #expect(incremental.tokens.contains {
            tokenIntersects($0, range: returnItemRange, syntaxID: .identifierVariable, language: .swift)
        } == false)
        #expect(SyntaxEditorRangeUtilities.intersection(of: refreshRangeUnion(incremental), and: returnItemRange) == returnItemRange)
    }

    @Test("SyntaxHighlighterEngine keeps Swift enum case insertion name-targeted")
    func highlighterKeepsSwiftEnumCaseInsertionNameTargeted() async throws {
        let filler = (0..<500)
            .map { "let filler\($0) = \($0)" }
            .joined(separator: "\n")
        let source = "enum State {\n"
            + "    case idle\n"
            + "    \n"
            + "}\n"
            + "\(filler)\n"
            + "let selected = State.failed\n"
        let nsSource = source as NSString
        let insertionTarget = nsSource.range(of: "    \n}")
        let insertionLocation = try #require(
            insertionTarget.location == NSNotFound ? nil : insertionTarget.location
        )
        let insertion = "    case failed\n"
        let mutation = SyntaxEditorTextChange.Replacement(
            location: insertionLocation,
            length: 0,
            replacement: insertion
        )
        let updatedSource = nsSource.replacingCharacters(
            in: NSRange(location: insertionLocation, length: 0),
            with: insertion
        )
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.swift, revision: 0)
        let update = await incrementalEngine.update(
            source: updatedSource,
            language: SyntaxLanguage.swift,
            mutation: mutation,
            revision: 1
        )
        let currentTokens = await incrementalEngine.currentTokensForTesting()
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.swift)
        let nsUpdatedSource = updatedSource as NSString
        let stateFailedRange = nsUpdatedSource.range(of: "State.failed")
        let failedRange = nsUpdatedSource.range(of: "failed", options: [], range: stateFailedRange)
        let refreshTotalLength = update.refreshRanges.reduce(0) { $0 + $1.length }

        #expect(update.tokenPayload == .replacement)
        #expect(highlightTokensMatch(currentTokens, full.tokens))
        #expect(Set(update.tokens.map { "\($0.range.location):\($0.range.length):\($0.rawCaptureName):\($0.isSemanticOverlay)" }).count == update.tokens.count)
        #expect(update.refreshRanges.count >= 2)
        #expect(refreshTotalLength < updatedSource.utf16.count / 4)
        #expect(refreshRangeUnion(update).length > refreshTotalLength)
        #expect(currentTokens.contains {
            tokenIntersects($0, range: failedRange, syntaxID: .identifierConstant, language: .swift)
        })
    }

    @Test("SyntaxHighlighterEngine keeps duplicate Swift enum cases incremental")
    func highlighterKeepsDuplicateSwiftEnumCasesIncremental() async throws {
        let filler = (0..<500)
            .map { "let filler\($0) = \($0)" }
            .joined(separator: "\n")
        let source = "enum State {\n"
            + "    case idle\n"
            + "    case failed\n"
            + "    \n"
            + "}\n"
            + "\(filler)\n"
            + "let selected = State.failed\n"
        let nsSource = source as NSString
        let insertionTarget = nsSource.range(of: "    \n}")
        let insertionLocation = try #require(
            insertionTarget.location == NSNotFound ? nil : insertionTarget.location
        )
        let insertion = "    case failed\n"
        let mutation = SyntaxEditorTextChange.Replacement(
            location: insertionLocation,
            length: 0,
            replacement: insertion
        )
        let updatedSource = nsSource.replacingCharacters(
            in: NSRange(location: insertionLocation, length: 0),
            with: insertion
        )
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.swift, revision: 0)
        let update = await incrementalEngine.update(
            source: updatedSource,
            language: SyntaxLanguage.swift,
            mutation: mutation,
            revision: 1
        )
        let currentTokens = await incrementalEngine.currentTokensForTesting()
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.swift)
        let refreshTotalLength = update.refreshRanges.reduce(0) { $0 + $1.length }

        #expect(update.tokenPayload == .replacement)
        #expect(highlightTokensMatch(currentTokens, full.tokens))
        #expect(Set(update.tokens.map { "\($0.range.location):\($0.range.length):\($0.rawCaptureName):\($0.isSemanticOverlay)" }).count == update.tokens.count)
        #expect(refreshTotalLength < updatedSource.utf16.count / 4)
        #expect(refreshRangeUnion(update).length < updatedSource.utf16.count)
    }

    @Test("SyntaxHighlighterEngine rebuilds Swift semantic index after modifier declaration edits")
    func highlighterRebuildsSwiftSemanticIndexAfterModifierDeclarationEdits() async throws {
        let source = """
        private let item = 1

        func render() -> Int {
            return item
        }
        """
        let updatedSource = source.replacingOccurrences(of: "private let item", with: "private let value")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.swift)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.swift,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.swift)
        let nsUpdatedSource = updatedSource as NSString
        let returnLineRange = nsUpdatedSource.range(of: "return item")
        let returnItemRange = nsUpdatedSource.range(of: "item", options: [], range: returnLineRange)

        #expect(incremental.tokens == full.tokens)
        #expect(incremental.tokens.contains {
            tokenIntersects($0, range: returnItemRange, syntaxID: .identifierVariable, language: .swift)
        } == false)
        #expect(SyntaxEditorRangeUtilities.intersection(of: refreshRangeUnion(incremental), and: returnItemRange) == returnItemRange)
    }

    @Test("SyntaxHighlighterEngine strips stale Swift system macro overlays after local macro declarations")
    func highlighterStripsStaleSwiftSystemMacroOverlaysAfterLocalMacroDeclarations() async throws {
        let source = """
        let expanded = #ExternalMacro()
        """
        let prefix = """
        macro ExternalMacro() = #externalMacro(module: "FixtureMacros", type: "ExternalMacro")

        """
        let updatedSource = prefix + source
        let mutation = SyntaxEditorTextChange.Replacement(location: 0, length: 0, replacement: prefix)
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.swift)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.swift,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.swift)

        #expect(incremental.tokens == full.tokens)
        #expect(Set(incremental.tokens.map { "\($0.range.location):\($0.range.length):\($0.rawCaptureName)" }).count == incremental.tokens.count)
        let macroInvocation = try effectiveSemanticSnapshot(
            in: incremental.tokens,
            source: updatedSource,
            text: "ExternalMacro",
            syntaxID: .identifierMacro,
            language: .swift,
            inOccurrenceOf: "#ExternalMacro()"
        )
        #expect(macroInvocation.styleKeys.first == "editor.syntax.identifier.macro")
        #expect(syntaxIDs(
            in: incremental.tokens,
            source: updatedSource,
            text: "ExternalMacro",
            inOccurrenceOf: "#ExternalMacro()"
        ).contains(.identifierMacroSystem) == false)
    }

    @Test("SyntaxHighlighterEngine keeps Swift comment overlays in large comment ranges")
    func highlighterKeepsSwiftCommentOverlaysInLargeCommentRanges() async {
        let lines = (0..<400).map { index in
            switch index {
            case 24:
                return "// MARK: - Batched paste surface"
            case 120:
                return "/// - Warning: See https://example.invalid/paste/\(index)."
            default:
                return "/// Documentation line \(index)"
            }
        }
        let source = lines.joined(separator: "\n")
        let nsSource = source as NSString
        let tokens = await SyntaxHighlighterEngine().render(source: source, language: SyntaxLanguage.swift)

        let markRange = nsSource.range(of: "MARK:")
        let urlRange = nsSource.range(of: "https://example.invalid/paste/120.")

        #expect(tokens.contains { tokenIntersects($0, range: markRange, syntaxID: .mark, language: .swift) })
        #expect(tokens.contains { tokenIntersects($0, range: urlRange, syntaxID: .url, language: .swift) })
    }
}
