import Foundation
import SwiftTreeSitter

private struct ObjectiveCTreeSymbolFacts {
    var localTypes = Set<String>()
    var localFunctions = Set<String>()
    var localProperties = Set<String>()
    var localMacros = Set<String>()
    var fileScopeVariables = Set<String>()
    var ivars = Set<String>()
    var typeDeclarations: [(name: String, range: NSRange)] = []
    var propertyDeclarations: [(name: String, range: NSRange)] = []
    var fileScopeVariableDeclarations: [(name: String, range: NSRange)] = []
    var ivarDeclarations: [(name: String, range: NSRange)] = []
    var selfMemberNameRangeKeys = Set<ObjectiveCRangeKey>()
    var selfMemberCandidates: [(member: String, fieldRange: NSRange)] = []
    var selfChainMemberNameRangeKeys = Set<ObjectiveCRangeKey>()
    var selfChainCandidates: [(firstMember: String, fieldRange: NSRange)] = []
}

struct ObjectiveCFileSymbolIndex {
    let localTypes: Set<String>
    let localFunctions: Set<String>
    let localProperties: Set<String>
    private let localMacros: Set<String>
    private let fileScopeVariables: Set<String>
    private let ivars: Set<String>
    private let allowsHeaderBackedSelfMembers: Bool
    private let typeDeclarationNameRangeKeys: Set<ObjectiveCRangeKey>
    private let propertyDeclarationNameRangeKeys: Set<ObjectiveCRangeKey>
    private let fileScopeVariableDeclarationNameRangeKeys: Set<ObjectiveCRangeKey>
    private let ivarDeclarationNameRangeKeys: Set<ObjectiveCRangeKey>
    private let shadowedVariableRangeKeys: Set<ObjectiveCRangeKey>
    private let selfMemberNameRangeKeys: Set<ObjectiveCRangeKey>
    private let selfChainMemberNameRangeKeys: Set<ObjectiveCRangeKey>
    private let selfMemberAccessOperatorRangeKeys: Set<ObjectiveCRangeKey>

    init?(
        source: NSString,
        tokenIndex: ObjectiveCTokenIndex,
        nonCodeRangeIndex: ObjectiveCNonCodeRangeIndex,
        rootNode: Node? = nil,
        allowsCancellation: Bool = false
    ) {
        if allowsCancellation, Task.isCancelled {
            return nil
        }
        let treeFacts: ObjectiveCTreeSymbolFacts
        if let rootNode {
            guard let facts = Self.collectTreeSymbolFacts(
                from: rootNode,
                source: source,
                tokenIndex: tokenIndex,
                allowsCancellation: allowsCancellation
            ) else {
                return nil
            }
            treeFacts = facts
        } else {
            treeFacts = ObjectiveCTreeSymbolFacts()
        }

        var localTypes = treeFacts.localTypes
        var localFunctions = treeFacts.localFunctions
        let localMacros = Self.scanDefinedMacroNames(
            source: source,
            nonCodeRangeIndex: nonCodeRangeIndex
        ).union(treeFacts.localMacros)
        var fileScopeVariables = treeFacts.fileScopeVariables
        var ivars = treeFacts.ivars
        var typeDeclarations = treeFacts.typeDeclarations
        var propertyDeclarations = treeFacts.propertyDeclarations
        var fileScopeVariableDeclarations = treeFacts.fileScopeVariableDeclarations
        var ivarDeclarations = treeFacts.ivarDeclarations
        let allowsHeaderBackedSelfMembers = Self.hasQuotedHeaderImport(in: source)
        let zeroArgumentMethodNameRanges = rootNode == nil ? Self.zeroArgumentMethodNameRanges(in: source) : []
        var localProperties = treeFacts.localProperties
        localProperties.formUnion(propertyDeclarations.map(\.name))
        let scannedLocalTypes = Self.scanLocalTypes(source: source, nonCodeRangeIndex: nonCodeRangeIndex)
        localTypes.formUnion(scannedLocalTypes.names)
        typeDeclarations.append(contentsOf: scannedLocalTypes.declarations)
        let scannedFileScopeVariables = Self.scanFileScopeVariableDeclarations(
            source: source,
            nonCodeRangeIndex: nonCodeRangeIndex
        )
        fileScopeVariables.formUnion(scannedFileScopeVariables.map(\.name))
        fileScopeVariableDeclarations.append(contentsOf: scannedFileScopeVariables)
        let scannedIvars = Self.scanImplementationIvarDeclarations(
            source: source,
            nonCodeRangeIndex: nonCodeRangeIndex
        )
        ivars.formUnion(scannedIvars.map(\.name))
        ivarDeclarations.append(contentsOf: scannedIvars)
        let shadowedVariableRangeKeys = Self.scanVariableShadowRanges(
            source: source,
            shadowedNames: fileScopeVariables.union(ivars),
            nonCodeRangeIndex: nonCodeRangeIndex
        )

        if rootNode == nil {
            propertyDeclarations.append(contentsOf: Self.scanLocalPropertyDeclarations(source: source, tokenIndex: tokenIndex))
            localProperties.formUnion(propertyDeclarations.map(\.name))
        }

        for token in tokenIndex.identifierTokens {
            if allowsCancellation, Task.isCancelled {
                return nil
            }
            let text = source.substring(with: token.range)

            switch token.syntaxID {
            case .identifierType:
                localTypes.insert(text)
            case .identifierFunction:
                if ObjectiveCSyntaxOverlayTokenProvider.isObjectiveCCFunctionDeclarationName(token.range, in: source) {
                    localFunctions.insert(text)
                }
                if Self.isZeroArgumentMethodName(
                    token.range,
                    in: zeroArgumentMethodNameRanges
                ) {
                    localProperties.insert(text)
                }
            default:
                continue
            }
        }

        var selfMemberNameRangeKeys = treeFacts.selfMemberNameRangeKeys
        for candidate in treeFacts.selfMemberCandidates
            where ObjectiveCSyntaxOverlayTokenProvider.shouldTrackSelfMember(
                candidate.member,
                localProperties: localProperties,
                allowsHeaderBackedMembers: allowsHeaderBackedSelfMembers
            ) {
            selfMemberNameRangeKeys.insert(ObjectiveCRangeKey(candidate.fieldRange))
        }

        var selfChainMemberNameRangeKeys = treeFacts.selfChainMemberNameRangeKeys
        for candidate in treeFacts.selfChainCandidates
            where ObjectiveCSyntaxOverlayTokenProvider.shouldTrackSelfMember(
                candidate.firstMember,
                localProperties: localProperties,
                allowsHeaderBackedMembers: allowsHeaderBackedSelfMembers
            ) {
            selfChainMemberNameRangeKeys.insert(ObjectiveCRangeKey(candidate.fieldRange))
        }

        for token in tokenIndex.identifierTokens {
            if allowsCancellation, Task.isCancelled {
                return nil
            }
            let text = source.substring(with: token.range)
            if ObjectiveCSyntaxOverlayTokenProvider.shouldTrackSelfMember(
                text,
                localProperties: localProperties,
                allowsHeaderBackedMembers: allowsHeaderBackedSelfMembers
            ),
               ObjectiveCSyntaxOverlayTokenProvider.isSelfMemberName(token.range, in: source) {
                selfMemberNameRangeKeys.insert(ObjectiveCRangeKey(token.range))
                continue
            }
            if ObjectiveCSyntaxOverlayTokenProvider.isMemberNameInKnownSelfChain(
                token.range,
                in: source,
                localProperties: localProperties,
                allowsHeaderBackedMembers: allowsHeaderBackedSelfMembers
            ) {
                selfChainMemberNameRangeKeys.insert(ObjectiveCRangeKey(token.range))
            }
        }

        self.localTypes = localTypes
        self.localFunctions = localFunctions
        self.localProperties = localProperties
        self.localMacros = localMacros
        self.fileScopeVariables = fileScopeVariables
        self.ivars = ivars
        self.allowsHeaderBackedSelfMembers = allowsHeaderBackedSelfMembers
        self.typeDeclarationNameRangeKeys = Set(typeDeclarations.map { ObjectiveCRangeKey($0.range) })
        self.propertyDeclarationNameRangeKeys = Set(propertyDeclarations.map { ObjectiveCRangeKey($0.range) })
        self.fileScopeVariableDeclarationNameRangeKeys = Set(fileScopeVariableDeclarations.map { ObjectiveCRangeKey($0.range) })
        self.ivarDeclarationNameRangeKeys = Set(ivarDeclarations.map { ObjectiveCRangeKey($0.range) })
        self.shadowedVariableRangeKeys = shadowedVariableRangeKeys
        self.selfMemberNameRangeKeys = selfMemberNameRangeKeys
        self.selfChainMemberNameRangeKeys = selfChainMemberNameRangeKeys
        self.selfMemberAccessOperatorRangeKeys = Self.memberAccessOperatorRangeKeys(
            before: selfMemberNameRangeKeys.union(selfChainMemberNameRangeKeys),
            in: source
        )
    }

    private init(
        localTypes: Set<String>,
        localFunctions: Set<String>,
        localProperties: Set<String>,
        localMacros: Set<String>,
        fileScopeVariables: Set<String>,
        ivars: Set<String>,
        allowsHeaderBackedSelfMembers: Bool,
        typeDeclarationNameRangeKeys: Set<ObjectiveCRangeKey>,
        propertyDeclarationNameRangeKeys: Set<ObjectiveCRangeKey>,
        fileScopeVariableDeclarationNameRangeKeys: Set<ObjectiveCRangeKey>,
        ivarDeclarationNameRangeKeys: Set<ObjectiveCRangeKey>,
        shadowedVariableRangeKeys: Set<ObjectiveCRangeKey>,
        selfMemberNameRangeKeys: Set<ObjectiveCRangeKey>,
        selfChainMemberNameRangeKeys: Set<ObjectiveCRangeKey>,
        selfMemberAccessOperatorRangeKeys: Set<ObjectiveCRangeKey>
    ) {
        self.localTypes = localTypes
        self.localFunctions = localFunctions
        self.localProperties = localProperties
        self.localMacros = localMacros
        self.fileScopeVariables = fileScopeVariables
        self.ivars = ivars
        self.allowsHeaderBackedSelfMembers = allowsHeaderBackedSelfMembers
        self.typeDeclarationNameRangeKeys = typeDeclarationNameRangeKeys
        self.propertyDeclarationNameRangeKeys = propertyDeclarationNameRangeKeys
        self.fileScopeVariableDeclarationNameRangeKeys = fileScopeVariableDeclarationNameRangeKeys
        self.ivarDeclarationNameRangeKeys = ivarDeclarationNameRangeKeys
        self.shadowedVariableRangeKeys = shadowedVariableRangeKeys
        self.selfMemberNameRangeKeys = selfMemberNameRangeKeys
        self.selfChainMemberNameRangeKeys = selfChainMemberNameRangeKeys
        self.selfMemberAccessOperatorRangeKeys = selfMemberAccessOperatorRangeKeys
    }

    func shifted(
        by mutation: SyntaxEditorTextChange.Replacement,
        sourceUTF16Length nextSourceUTF16Length: Int
    ) -> ObjectiveCFileSymbolIndex? {
        guard let shiftedTypeDeclarationNameRangeKeys = Self.shiftedRangeKeys(
            typeDeclarationNameRangeKeys,
            by: mutation,
            sourceUTF16Length: nextSourceUTF16Length
        ),
              let shiftedPropertyDeclarationNameRangeKeys = Self.shiftedRangeKeys(
                propertyDeclarationNameRangeKeys,
                by: mutation,
                sourceUTF16Length: nextSourceUTF16Length
              ),
              let shiftedFileScopeVariableDeclarationNameRangeKeys = Self.shiftedRangeKeys(
                fileScopeVariableDeclarationNameRangeKeys,
                by: mutation,
                sourceUTF16Length: nextSourceUTF16Length
              ),
              let shiftedIvarDeclarationNameRangeKeys = Self.shiftedRangeKeys(
                ivarDeclarationNameRangeKeys,
                by: mutation,
                sourceUTF16Length: nextSourceUTF16Length
              ),
              let shiftedShadowedVariableRangeKeys = Self.shiftedRangeKeys(
                shadowedVariableRangeKeys,
                by: mutation,
                sourceUTF16Length: nextSourceUTF16Length
              ),
              let shiftedSelfMemberNameRangeKeys = Self.shiftedRangeKeys(
                selfMemberNameRangeKeys,
                by: mutation,
                sourceUTF16Length: nextSourceUTF16Length
              ),
              let shiftedSelfChainMemberNameRangeKeys = Self.shiftedRangeKeys(
                selfChainMemberNameRangeKeys,
                by: mutation,
                sourceUTF16Length: nextSourceUTF16Length
              ),
              let shiftedSelfMemberAccessOperatorRangeKeys = Self.shiftedRangeKeys(
                selfMemberAccessOperatorRangeKeys,
                by: mutation,
                sourceUTF16Length: nextSourceUTF16Length
              ) else {
            return nil
        }

        return ObjectiveCFileSymbolIndex(
            localTypes: localTypes,
            localFunctions: localFunctions,
            localProperties: localProperties,
            localMacros: localMacros,
            fileScopeVariables: fileScopeVariables,
            ivars: ivars,
            allowsHeaderBackedSelfMembers: allowsHeaderBackedSelfMembers,
            typeDeclarationNameRangeKeys: shiftedTypeDeclarationNameRangeKeys,
            propertyDeclarationNameRangeKeys: shiftedPropertyDeclarationNameRangeKeys,
            fileScopeVariableDeclarationNameRangeKeys: shiftedFileScopeVariableDeclarationNameRangeKeys,
            ivarDeclarationNameRangeKeys: shiftedIvarDeclarationNameRangeKeys,
            shadowedVariableRangeKeys: shiftedShadowedVariableRangeKeys,
            selfMemberNameRangeKeys: shiftedSelfMemberNameRangeKeys,
            selfChainMemberNameRangeKeys: shiftedSelfChainMemberNameRangeKeys,
            selfMemberAccessOperatorRangeKeys: shiftedSelfMemberAccessOperatorRangeKeys
        )
    }

    func containsTypeDeclarationNameRange(_ range: NSRange) -> Bool {
        typeDeclarationNameRangeKeys.contains(ObjectiveCRangeKey(range))
    }

    func containsPropertyDeclarationNameRange(_ range: NSRange) -> Bool {
        propertyDeclarationNameRangeKeys.contains(ObjectiveCRangeKey(range))
    }

    func containsFileScopeVariableName(_ name: String) -> Bool {
        fileScopeVariables.contains(name)
    }

    func containsFileScopeVariableDeclarationNameRange(_ range: NSRange) -> Bool {
        fileScopeVariableDeclarationNameRangeKeys.contains(ObjectiveCRangeKey(range))
    }

    func containsIvarName(_ name: String) -> Bool {
        ivars.contains(name)
    }

    func containsIvarDeclarationNameRange(_ range: NSRange) -> Bool {
        ivarDeclarationNameRangeKeys.contains(ObjectiveCRangeKey(range))
    }

    func containsShadowedVariableRange(_ range: NSRange) -> Bool {
        shadowedVariableRangeKeys.contains(ObjectiveCRangeKey(range))
    }

    func containsLocalMacroName(_ name: String) -> Bool {
        localMacros.contains(name)
    }

    func containsSelfMemberNameRange(_ range: NSRange) -> Bool {
        selfMemberNameRangeKeys.contains(ObjectiveCRangeKey(range))
    }

    func containsSelfChainMemberNameRange(_ range: NSRange) -> Bool {
        selfChainMemberNameRangeKeys.contains(ObjectiveCRangeKey(range))
    }

    func mutationTouchesSelfMemberAccessOperator(_ mutation: SyntaxEditorTextChange.Replacement) -> Bool {
        guard mutation.length > 0 else {
            return false
        }
        let replacedRange = NSRange(location: mutation.location, length: mutation.length)
        return selfMemberAccessOperatorRangeKeys.contains(where: {
            SyntaxEditorRangeUtilities.intersection(
                of: replacedRange,
                and: NSRange(location: $0.location, length: $0.length)
            ).length > 0
        })
    }

    func shouldTrackSelfMemberName(_ name: String) -> Bool {
        ObjectiveCSyntaxOverlayTokenProvider.shouldTrackSelfMember(
            name,
            localProperties: localProperties,
            allowsHeaderBackedMembers: allowsHeaderBackedSelfMembers
        )
    }

    static func containingFunctionLikeScopeRange(containing location: Int, in source: NSString) -> NSRange? {
        functionLikeScopes(in: source)
            .first { scope in
                scope.location <= location && location < scope.upperBound
            }
            .map { scope in
                NSRange(location: scope.location, length: scope.upperBound - scope.location)
            }
    }

    private static func shiftedRangeKeys(
        _ keys: Set<ObjectiveCRangeKey>,
        by mutation: SyntaxEditorTextChange.Replacement,
        sourceUTF16Length nextSourceUTF16Length: Int
    ) -> Set<ObjectiveCRangeKey>? {
        var shifted = Set<ObjectiveCRangeKey>()
        shifted.reserveCapacity(keys.count)
        for key in keys {
            let range = NSRange(location: key.location, length: key.length)
            guard let shiftedRange = shiftedRange(
                range,
                by: mutation,
                sourceUTF16Length: nextSourceUTF16Length
            ) else {
                return nil
            }
            shifted.insert(ObjectiveCRangeKey(shiftedRange))
        }
        return shifted
    }

    private static func memberAccessOperatorRangeKeys(
        before fieldRangeKeys: Set<ObjectiveCRangeKey>,
        in source: NSString
    ) -> Set<ObjectiveCRangeKey> {
        var operatorRangeKeys = Set<ObjectiveCRangeKey>()
        operatorRangeKeys.reserveCapacity(fieldRangeKeys.count)
        for key in fieldRangeKeys {
            let range = NSRange(location: key.location, length: key.length)
            guard let operatorRange = ObjectiveCSyntaxOverlayTokenProvider.memberAccessOperatorRange(
                before: range,
                in: source
            ) else {
                continue
            }
            operatorRangeKeys.insert(ObjectiveCRangeKey(operatorRange))
        }
        return operatorRangeKeys
    }

    private static func shiftedRange(
        _ range: NSRange,
        by mutation: SyntaxEditorTextChange.Replacement,
        sourceUTF16Length nextSourceUTF16Length: Int
    ) -> NSRange? {
        let replacementLength = mutation.replacement.utf16.count
        let replacedRange = NSRange(location: mutation.location, length: mutation.length)
        let oldUpperBound = mutation.location + mutation.length
        let delta = replacementLength - mutation.length

        if range.upperBound <= mutation.location {
            return range
        }
        if mutation.length == 0,
           replacementLength > 0,
           range.location < mutation.location,
           mutation.location < range.upperBound {
            return nil
        }
        if range.location >= oldUpperBound {
            let shiftedLocation = range.location + delta
            guard shiftedLocation >= 0,
                  shiftedLocation + range.length <= nextSourceUTF16Length else {
                return nil
            }
            return NSRange(location: shiftedLocation, length: range.length)
        }
        if SyntaxEditorRangeUtilities.intersection(of: range, and: replacedRange).length > 0 {
            return nil
        }
        return range
    }

    private static func hasQuotedHeaderImport(in source: NSString) -> Bool {
        quotedHeaderImportRegex.firstMatch(
            in: source as String,
            range: NSRange(location: 0, length: source.length)
        ) != nil
    }

    private static func collectTreeSymbolFacts(
        from rootNode: Node,
        source: NSString,
        tokenIndex: ObjectiveCTokenIndex,
        allowsCancellation: Bool
    ) -> ObjectiveCTreeSymbolFacts? {
        var facts = ObjectiveCTreeSymbolFacts()
        guard collectTreeSymbolFacts(
            from: rootNode,
            source: source,
            tokenIndex: tokenIndex,
            allowsCancellation: allowsCancellation,
            into: &facts
        ) else {
            return nil
        }
        return facts
    }

    @discardableResult
    private static func collectTreeSymbolFacts(
        from node: Node,
        source: NSString,
        tokenIndex: ObjectiveCTokenIndex,
        allowsCancellation: Bool,
        into facts: inout ObjectiveCTreeSymbolFacts
    ) -> Bool {
        if allowsCancellation, Task.isCancelled {
            return false
        }
        switch node.nodeType {
        case "class_interface", "class_implementation", "protocol_declaration":
            if let nameNode = primaryTypeIdentifier(in: node, source: source) {
                let name = source.substring(with: nameNode.range)
                facts.localTypes.insert(name)
                facts.typeDeclarations.append((name: name, range: nameNode.range))
            }
        case "class_declaration", "protocol_forward_declaration":
            for nameNode in directIdentifierChildren(in: node) {
                let name = source.substring(with: nameNode.range)
                facts.localTypes.insert(name)
                facts.typeDeclarations.append((name: name, range: nameNode.range))
            }
        case "type_definition":
            collectTypeDefinitionFacts(from: node, source: source, into: &facts)
        case "enum_specifier", "struct_specifier", "union_specifier":
            if let nameNode = node.child(byFieldName: "name") ?? directChild(in: node, nodeType: "type_identifier") {
                facts.localTypes.insert(source.substring(with: nameNode.range))
            }
        case "property_declaration":
            collectPropertyFacts(from: node, source: source, tokenIndex: tokenIndex, into: &facts)
        case "method_declaration", "method_definition":
            collectMethodFacts(from: node, source: source, into: &facts)
        case "function_declarator":
            collectFunctionDeclaratorFacts(from: node, source: source, into: &facts)
        case "field_expression":
            collectFieldExpressionFacts(from: node, source: source, into: &facts)
        default:
            break
        }

        for index in 0..<node.childCount {
            guard let child = node.child(at: index) else { continue }
            guard collectTreeSymbolFacts(
                from: child,
                source: source,
                tokenIndex: tokenIndex,
                allowsCancellation: allowsCancellation,
                into: &facts
            ) else {
                return false
            }
        }
        return true
    }

    private static func collectTypeDefinitionFacts(
        from node: Node,
        source: NSString,
        into facts: inout ObjectiveCTreeSymbolFacts
    ) {
        let declaration = source.substring(with: node.range) as NSString
        if let declaredName = nsEnumOptionsTypedefDeclaredName(in: declaration) {
            facts.localTypes.insert(declaredName.name)
            facts.typeDeclarations.append((
                name: declaredName.name,
                range: NSRange(
                    location: node.range.location + declaredName.range.location,
                    length: declaredName.range.length
                )
            ))
            return
        }
        for declarator in children(in: node, fieldName: "declarator") {
            if let identifier = declaratorIdentifier(in: declarator, preferredTypes: ["type_identifier", "identifier"]) {
                let name = source.substring(with: identifier.range)
                facts.localTypes.insert(name)
                facts.typeDeclarations.append((name: name, range: identifier.range))
            }
        }
    }

    private static func collectPropertyFacts(
        from node: Node,
        source: NSString,
        tokenIndex: ObjectiveCTokenIndex,
        into facts: inout ObjectiveCTreeSymbolFacts
    ) {
        guard let declarationRange = propertyStatementRange(startingAt: node.range.location, in: source) else {
            return
        }
        let declaration = source.substring(with: declarationRange) as NSString
        guard propertyDeclarationIsComplete(declaration),
              !propertyDeclarationAppearsToSwallowFollowingDeclaration(in: declaration) else {
            return
        }

        var didCollectFromToken = false
        for range in tokenIndex.declarationOtherIdentifierRanges(in: declarationRange) {
            let name = source.substring(with: range)
            facts.localProperties.insert(name)
            facts.propertyDeclarations.append((name: name, range: range))
            didCollectFromToken = true
        }

        guard let relativeNameRange = propertyDeclaredNameRange(in: declaration) else {
            return
        }
        let range = NSRange(
            location: declarationRange.location + relativeNameRange.location,
            length: relativeNameRange.length
        )
        guard range.upperBound <= source.length,
              isIdentifierRange(range, in: source) else {
            return
        }
        let name = source.substring(with: range)
        if propertyReferenceShouldBeTracked(name: name, range: relativeNameRange, in: declaration) {
            facts.localProperties.insert(name)
        }
        guard !didCollectFromToken else {
            return
        }
        facts.propertyDeclarations.append((name: name, range: range))
    }

    private static func propertyStatementRange(startingAt start: Int, in source: NSString) -> NSRange? {
        guard start >= 0, start < source.length else {
            return nil
        }
        var cursor = start
        while cursor < source.length {
            let character = source.substring(with: NSRange(location: cursor, length: 1))
            if character == ";" {
                return NSRange(location: start, length: cursor - start + 1)
            }
            if character == "\n" || character == "\r" {
                let nextLineStart = cursor + 1
                if nextLineStart < source.length {
                    var lookahead = nextLineStart
                    while lookahead < source.length,
                          isWhitespace(source.substring(with: NSRange(location: lookahead, length: 1))) {
                        lookahead += 1
                    }
                    if lookahead < source.length {
                        let next = source.substring(with: NSRange(location: lookahead, length: 1))
                        if next == "@" || next == "-" || next == "+" {
                            return nil
                        }
                    }
                }
            }
            cursor += 1
        }
        return nil
    }

    private static func propertyDeclarationIsComplete(_ declaration: NSString) -> Bool {
        var cursor = declaration.length - 1
        while cursor >= 0 {
            let character = declaration.substring(with: NSRange(location: cursor, length: 1))
            if isWhitespace(character) {
                if cursor == 0 {
                    return false
                }
                cursor -= 1
                continue
            }
            return character == ";"
        }
        return false
    }

    private static func collectMethodFacts(
        from node: Node,
        source: NSString,
        into facts: inout ObjectiveCTreeSymbolFacts
    ) {
        let directIdentifiers = directIdentifierChildren(in: node)
        guard directIdentifiers.count == 1,
              !hasDirectChild(in: node, nodeType: "method_parameter"),
              !hasDirectChild(in: node, nodeType: "keyword_declarator"),
              let nameNode = directIdentifiers.first
        else {
            return
        }
        facts.localProperties.insert(source.substring(with: nameNode.range))
    }

    private static func collectFunctionDeclaratorFacts(
        from node: Node,
        source: NSString,
        into facts: inout ObjectiveCTreeSymbolFacts
    ) {
        guard !hasAncestor(node, nodeTypes: [
            "property_declaration",
            "method_declaration",
            "method_definition",
            "method_parameter",
            "parameter_declaration"
        ]),
              let declarator = node.child(byFieldName: "declarator"),
              let identifier = declaratorIdentifier(in: declarator, preferredTypes: ["identifier"]) else {
            return
        }
        facts.localFunctions.insert(source.substring(with: identifier.range))
    }

    private static func collectFieldExpressionFacts(
        from node: Node,
        source: NSString,
        into facts: inout ObjectiveCTreeSymbolFacts
    ) {
        guard let fieldNode = node.child(byFieldName: "field"),
              let argumentNode = node.child(byFieldName: "argument") else {
            return
        }

        if expressionIsBareSelf(argumentNode, source: source) {
            facts.selfMemberCandidates.append((
                member: source.substring(with: fieldNode.range),
                fieldRange: fieldNode.range
            ))
        } else if let firstMember = firstSelfRootMemberName(in: argumentNode, source: source) {
            facts.selfChainCandidates.append((firstMember: firstMember, fieldRange: fieldNode.range))
        }
    }

    private static func primaryTypeIdentifier(in node: Node, source: NSString) -> Node? {
        for index in 0..<node.childCount {
            guard let child = node.child(at: index),
                  child.nodeType == "identifier",
                  node.fieldNameForChild(at: index) != "superclass",
                  node.fieldNameForChild(at: index) != "category",
                  child.range.upperBound <= source.length
            else {
                continue
            }
            return child
        }
        return nil
    }

    private static func directIdentifierChildren(in node: Node) -> [Node] {
        var identifiers: [Node] = []
        for index in 0..<node.childCount {
            guard let child = node.child(at: index),
                  child.nodeType == "identifier" || child.nodeType == "type_identifier"
            else {
                continue
            }
            identifiers.append(child)
        }
        return identifiers
    }

    private static func children(in node: Node, fieldName: String) -> [Node] {
        var children: [Node] = []
        for index in 0..<node.childCount {
            guard node.fieldNameForChild(at: index) == fieldName,
                  let child = node.child(at: index)
            else {
                continue
            }
            children.append(child)
        }
        return children
    }

    private static func directChild(in node: Node, nodeType: String) -> Node? {
        for index in 0..<node.childCount {
            guard let child = node.child(at: index),
                  child.nodeType == nodeType
            else {
                continue
            }
            return child
        }
        return nil
    }

    private static func hasDirectChild(in node: Node, nodeType: String) -> Bool {
        directChild(in: node, nodeType: nodeType) != nil
    }

    private static func declaratorIdentifier(in node: Node, preferredTypes: Set<String>) -> Node? {
        if let nodeType = node.nodeType,
           preferredTypes.contains(nodeType) {
            return node
        }
        if let declarator = node.child(byFieldName: "declarator"),
           let identifier = declaratorIdentifier(in: declarator, preferredTypes: preferredTypes) {
            return identifier
        }
        for index in 0..<node.childCount {
            guard let child = node.child(at: index),
                  let identifier = declaratorIdentifier(in: child, preferredTypes: preferredTypes)
            else {
                continue
            }
            return identifier
        }
        return nil
    }

    private static func expressionIsBareSelf(_ node: Node, source: NSString) -> Bool {
        guard node.range.upperBound <= source.length else {
            return false
        }
        return source.substring(with: node.range)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "self"
    }

    private static func firstSelfRootMemberName(in node: Node, source: NSString) -> String? {
        guard node.nodeType == "field_expression",
              let argument = node.child(byFieldName: "argument"),
              let field = node.child(byFieldName: "field"),
              field.range.upperBound <= source.length
        else {
            return nil
        }
        if expressionIsBareSelf(argument, source: source) {
            return source.substring(with: field.range)
        }
        return firstSelfRootMemberName(in: argument, source: source)
    }

    private static func hasAncestor(_ node: Node, nodeTypes: Set<String>) -> Bool {
        var current = node.parent
        while let node = current {
            if let nodeType = node.nodeType,
               nodeTypes.contains(nodeType) {
                return true
            }
            current = node.parent
        }
        return false
    }

    private static func range(_ outer: NSRange, contains inner: NSRange) -> Bool {
        inner.location >= outer.location && inner.upperBound <= outer.upperBound
    }

    private static func scanLocalTypes(
        source: NSString,
        nonCodeRangeIndex: ObjectiveCNonCodeRangeIndex
    ) -> (names: Set<String>, declarations: [(name: String, range: NSRange)]) {
        let string = source as String
        let fullRange = NSRange(location: 0, length: source.length)
        var names = Set<String>()
        var declarations: [(name: String, range: NSRange)] = []

        for regex in localTypeRegexes {
            for match in regex.matches(in: string, range: fullRange) {
                guard match.numberOfRanges > 1 else { continue }
                let range = match.range(at: 1)
                guard range.location != NSNotFound,
                      !nonCodeRangeIndex.intersects(range) else { continue }
                let name = source.substring(with: range)
                if isIdentifier(name) {
                    names.insert(name)
                    declarations.append((name: name, range: range))
                }
            }
        }

        for match in typedefRegex.matches(in: string, range: fullRange) {
            let range = match.range
            guard !nonCodeRangeIndex.intersects(range) else { continue }
            let declaration = source.substring(with: range) as NSString
            if let name = typedefDeclaredName(in: declaration) {
                let relativeRange = declaration.range(of: name, options: [.backwards])
                guard relativeRange.location != NSNotFound else {
                    continue
                }
                names.insert(name)
                declarations.append((
                    name: name,
                    range: NSRange(location: range.location + relativeRange.location, length: relativeRange.length)
                ))
            }
        }

        return (names, declarations)
    }

    private static func scanDefinedMacroNames(
        source: NSString,
        nonCodeRangeIndex: ObjectiveCNonCodeRangeIndex
    ) -> Set<String> {
        let string = source as String
        let fullRange = NSRange(location: 0, length: source.length)
        var names = Set<String>()
        for match in definedMacroNameRegex.matches(in: string, range: fullRange) {
            let range = match.range(at: 1)
            guard range.location != NSNotFound,
                  !nonCodeRangeIndex.intersects(range) else {
                continue
            }
            names.insert(source.substring(with: range))
        }
        return names
    }

    private static func scanFileScopeVariableDeclarations(
        source: NSString,
        nonCodeRangeIndex: ObjectiveCNonCodeRangeIndex
    ) -> [(name: String, range: NSRange)] {
        var declarations: [(name: String, range: NSRange)] = []
        var location = 0
        var braceDepth = 0
        var isInBlockComment = false
        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let line = source.substring(with: lineRange) as NSString
            let depthBeforeLine = braceDepth
            defer {
                let result = objectiveCBraceDepth(
                    afterScanning: line,
                    startingAt: braceDepth,
                    isInBlockComment: isInBlockComment
                )
                braceDepth = result.depth
                isInBlockComment = result.isInBlockComment
                let nextLocation = lineRange.upperBound
                location = nextLocation > location ? nextLocation : source.length
            }

            let codeStart = firstNonWhitespaceLocation(in: line)
            let afterStatic = codeStart + "static".utf16.count
            guard depthBeforeLine == 0,
                  !isInBlockComment,
                  codeStart < line.length,
                  line.length - codeStart >= "static".utf16.count,
                  line.substring(with: NSRange(location: codeStart, length: "static".utf16.count)) == "static",
                  afterStatic == line.length || !isASCIIIdentifierContinue(line.character(at: afterStatic)) else {
                continue
            }
            let statementEnd = firstLocation(ofAny: [";"], in: line, before: line.length)
            let firstTerminator = firstLocation(ofAny: ["=", ";"], in: line, before: line.length)
            guard statementEnd != NSNotFound,
                  firstTerminator != NSNotFound,
                  line.range(of: "(", options: [], range: NSRange(location: 0, length: firstTerminator)).location == NSNotFound else {
                continue
            }
            for relativeRange in declarationNameRanges(in: line, statementEnd: statementEnd) {
                let absoluteRange = NSRange(
                    location: lineRange.location + relativeRange.location,
                    length: relativeRange.length
                )
                let name = line.substring(with: relativeRange)
                guard !typedefIgnoredIdentifiers.contains(name),
                      name != "const",
                      name != "static",
                      !nonCodeRangeIndex.intersects(absoluteRange) else {
                    continue
                }
                declarations.append((
                    name: name,
                    range: absoluteRange
                ))
            }
        }
        return declarations
    }

    private static func firstNonWhitespaceLocation(in line: NSString) -> Int {
        var cursor = 0
        while cursor < line.length {
            if !isWhitespaceCodeUnit(line.character(at: cursor)) {
                return cursor
            }
            cursor += 1
        }
        return line.length
    }

    static func declarationNameRanges(in declaration: NSString, statementEnd: Int) -> [NSRange] {
        let upperBound = min(max(0, statementEnd), declaration.length)
        var ranges: [NSRange] = []
        var segmentStart = 0
        var cursor = 0
        var parenDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        var angleDepth = 0
        while cursor < upperBound {
            if let nextCursor = indexAfterCommentOrQuotedLiteral(startingAt: cursor, in: declaration) {
                cursor = min(nextCursor, upperBound)
                continue
            }
            let character = declaration.character(at: cursor)
            if character == commaCodeUnit,
               parenDepth == 0,
               bracketDepth == 0,
               braceDepth == 0,
               angleDepth == 0 {
                if let range = declarationNameRange(
                    in: NSRange(location: segmentStart, length: cursor - segmentStart),
                    declaration: declaration
                ) {
                    ranges.append(range)
                }
                segmentStart = cursor + 1
                cursor += 1
                continue
            }
            updateDeclarationDelimiterDepth(
                character: character,
                next: cursor + 1 < declaration.length
                    ? declaration.character(at: cursor + 1)
                    : 0,
                parenDepth: &parenDepth,
                bracketDepth: &bracketDepth,
                braceDepth: &braceDepth,
                angleDepth: &angleDepth
            )
            cursor += 1
        }
        if let range = declarationNameRange(
            in: NSRange(location: segmentStart, length: upperBound - segmentStart),
            declaration: declaration
        ) {
            ranges.append(range)
        }
        return ranges
    }

    private static func declarationNameRange(in segmentRange: NSRange, declaration: NSString) -> NSRange? {
        let searchEnd = declarationAssignmentLocation(in: segmentRange, declaration: declaration) ?? segmentRange.upperBound
        var end = min(searchEnd, declaration.length)
        while end > segmentRange.location,
              isWhitespaceCodeUnit(declaration.character(at: end - 1)) {
            end -= 1
        }
        guard let range = identifierRange(before: end, in: declaration) else {
            return nil
        }
        let name = declaration.substring(with: range)
        guard isIdentifier(name),
              !typedefIgnoredIdentifiers.contains(name),
              name != "const",
              name != "static" else {
            return nil
        }
        return range
    }

    private static func declarationAssignmentLocation(in segmentRange: NSRange, declaration: NSString) -> Int? {
        var cursor = max(0, segmentRange.location)
        let upperBound = min(segmentRange.upperBound, declaration.length)
        var parenDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        var angleDepth = 0
        while cursor < upperBound {
            if let nextCursor = indexAfterCommentOrQuotedLiteral(startingAt: cursor, in: declaration) {
                cursor = min(nextCursor, upperBound)
                continue
            }
            let character = declaration.character(at: cursor)
            if character == equalsCodeUnit,
               parenDepth == 0,
               bracketDepth == 0,
               braceDepth == 0,
               angleDepth == 0 {
                return cursor
            }
            updateDeclarationDelimiterDepth(
                character: character,
                next: cursor + 1 < declaration.length
                    ? declaration.character(at: cursor + 1)
                    : 0,
                parenDepth: &parenDepth,
                bracketDepth: &bracketDepth,
                braceDepth: &braceDepth,
                angleDepth: &angleDepth
            )
            cursor += 1
        }
        return nil
    }

    private static let backslashCodeUnit: unichar = 92
    private static let colonCodeUnit: unichar = 58
    private static let commaCodeUnit: unichar = 44
    private static let doubleQuoteCodeUnit: unichar = 34
    private static let equalsCodeUnit: unichar = 61
    private static let greaterThanCodeUnit: unichar = 62
    private static let lessThanCodeUnit: unichar = 60
    private static let openBraceCodeUnit: unichar = 123
    private static let openBracketCodeUnit: unichar = 91
    private static let openParenCodeUnit: unichar = 40
    private static let closeBraceCodeUnit: unichar = 125
    private static let closeBracketCodeUnit: unichar = 93
    private static let closeParenCodeUnit: unichar = 41
    private static let semicolonCodeUnit: unichar = 59
    private static let singleQuoteCodeUnit: unichar = 39
    private static let slashCodeUnit: unichar = 47
    private static let starCodeUnit: unichar = 42

    private static func singleUTF16CodeUnit(_ text: String) -> unichar? {
        var iterator = text.utf16.makeIterator()
        guard let first = iterator.next(),
              iterator.next() == nil else {
            return nil
        }
        return first
    }

    private static func isWhitespaceCodeUnit(_ codeUnit: unichar) -> Bool {
        switch codeUnit {
        case 9, 10, 11, 12, 13, 32:
            return true
        default:
            return false
        }
    }

    private static func updateDeclarationDelimiterDepth(
        character: unichar,
        next: unichar,
        parenDepth: inout Int,
        bracketDepth: inout Int,
        braceDepth: inout Int,
        angleDepth: inout Int
    ) {
        if character == openParenCodeUnit {
            parenDepth += 1
        } else if character == closeParenCodeUnit {
            parenDepth = max(0, parenDepth - 1)
        } else if character == openBracketCodeUnit {
            bracketDepth += 1
        } else if character == closeBracketCodeUnit {
            bracketDepth = max(0, bracketDepth - 1)
        } else if character == openBraceCodeUnit {
            braceDepth += 1
        } else if character == closeBraceCodeUnit {
            braceDepth = max(0, braceDepth - 1)
        } else if character == lessThanCodeUnit,
                  next != lessThanCodeUnit,
                  parenDepth == 0,
                  bracketDepth == 0,
                  braceDepth == 0 {
            angleDepth += 1
        } else if character == greaterThanCodeUnit,
                  angleDepth > 0,
                  next != greaterThanCodeUnit {
            angleDepth -= 1
        }
    }

    private static func updateDeclarationDelimiterDepth(
        character: String,
        next: String,
        parenDepth: inout Int,
        bracketDepth: inout Int,
        braceDepth: inout Int,
        angleDepth: inout Int
    ) {
        if character == "(" {
            parenDepth += 1
        } else if character == ")" {
            parenDepth = max(0, parenDepth - 1)
        } else if character == "[" {
            bracketDepth += 1
        } else if character == "]" {
            bracketDepth = max(0, bracketDepth - 1)
        } else if character == "{" {
            braceDepth += 1
        } else if character == "}" {
            braceDepth = max(0, braceDepth - 1)
        } else if character == "<",
                  next != "<",
                  parenDepth == 0,
                  bracketDepth == 0,
                  braceDepth == 0 {
            angleDepth += 1
        } else if character == ">",
                  angleDepth > 0,
                  next != ">" {
            angleDepth -= 1
        }
    }

    private static func scanVariableShadowRanges(
        source: NSString,
        shadowedNames: Set<String>,
        nonCodeRangeIndex: ObjectiveCNonCodeRangeIndex
    ) -> Set<ObjectiveCRangeKey> {
        guard !shadowedNames.isEmpty else {
            return []
        }

        var ranges = Set<ObjectiveCRangeKey>()
        for scope in functionLikeScopes(in: source) {
            var parameterShadowStarts: [String: Int] = [:]
            collectParameterShadows(
                in: NSRange(location: scope.location, length: scope.bodyOpenLocation - scope.location),
                source: source,
                shadowedNames: shadowedNames,
                nonCodeRangeIndex: nonCodeRangeIndex,
                into: &parameterShadowStarts
            )
            var shadowScopes = parameterShadowStarts.compactMap { name, start -> (name: String, range: NSRange)? in
                guard start < scope.upperBound else { return nil }
                return (name, NSRange(location: start, length: scope.upperBound - start))
            }
            collectLocalVariableShadows(
                in: scope,
                source: source,
                shadowedNames: shadowedNames,
                nonCodeRangeIndex: nonCodeRangeIndex,
                into: &shadowScopes
            )

            for shadowScope in shadowScopes {
                for range in identifierRanges(named: shadowScope.name, in: shadowScope.range, source: source) {
                    guard !nonCodeRangeIndex.intersects(range) else { continue }
                    ranges.insert(ObjectiveCRangeKey(range))
                }
            }
        }
        return ranges
    }

    private static func functionLikeScopes(in source: NSString) -> [(location: Int, bodyOpenLocation: Int, upperBound: Int)] {
        var scopes: [(location: Int, bodyOpenLocation: Int, upperBound: Int)] = []
        var pendingStart: Int?
        var pendingSplitCFunctionStart: Int?
        var location = 0

        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let line = source.substring(with: lineRange) as NSString
            let lineString = line as String
            defer {
                let nextLocation = lineRange.upperBound
                location = nextLocation > location ? nextLocation : source.length
            }

            if pendingStart == nil,
               objectiveCFunctionLikeSignatureLineRegex.firstMatch(
                in: lineString,
                range: NSRange(location: 0, length: line.length)
               ) != nil {
                pendingStart = lineRange.location
                pendingSplitCFunctionStart = nil
            } else if pendingStart == nil,
                      let splitStart = pendingSplitCFunctionStart,
                      isObjectiveCSplitCFunctionNameLine(line) {
                pendingStart = splitStart
                pendingSplitCFunctionStart = nil
            } else if pendingStart == nil,
                      isObjectiveCSplitCFunctionReturnTypeLine(line) {
                pendingSplitCFunctionStart = lineRange.location
            } else if pendingStart == nil {
                pendingSplitCFunctionStart = nil
            }

            guard let start = pendingStart else {
                continue
            }

            if let openBraceRange = firstBraceRange(in: line, brace: "{") {
                let openBraceLocation = lineRange.location + openBraceRange.location
                if let closeBraceLocation = matchingClosingBraceLocation(in: source, openBraceLocation: openBraceLocation) {
                    scopes.append((
                        location: start,
                        bodyOpenLocation: openBraceLocation,
                        upperBound: closeBraceLocation + 1
                    ))
                }
                pendingStart = nil
            } else if firstCodeCharacterRange(in: line, character: ";") != nil {
                pendingStart = nil
            }
        }

        return scopes
    }

    private static func isObjectiveCSplitCFunctionReturnTypeLine(_ line: NSString) -> Bool {
        let trimmed = (line as String).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              !trimmed.hasPrefix("@"),
              !trimmed.hasPrefix("-"),
              !trimmed.hasPrefix("+"),
              !trimmed.hasPrefix("//"),
              !trimmed.hasPrefix("/*"),
              !trimmed.contains("("),
              !trimmed.contains(")"),
              !trimmed.contains("="),
              !trimmed.contains(";"),
              !trimmed.contains("{"),
              !trimmed.contains("}") else {
            return false
        }

        let nsTrimmed = trimmed as NSString
        guard let firstIdentifier = identifierRegex.firstMatch(
            in: trimmed,
            range: NSRange(location: 0, length: nsTrimmed.length)
        ) else {
            return false
        }
        let leadingIdentifier = nsTrimmed.substring(with: firstIdentifier.range)
        return !objectiveCStatementLeadingIdentifiers.contains(leadingIdentifier)
    }

    private static func isObjectiveCSplitCFunctionNameLine(_ line: NSString) -> Bool {
        let string = line as String
        let fullRange = NSRange(location: 0, length: line.length)
        guard objectiveCSplitCFunctionNameLineRegex.firstMatch(in: string, range: fullRange) != nil,
              firstLocation(ofAny: ["="], in: line, before: line.length) == NSNotFound else {
            return false
        }
        return true
    }

    private static func collectParameterShadows(
        in headerRange: NSRange,
        source: NSString,
        shadowedNames: Set<String>,
        nonCodeRangeIndex: ObjectiveCNonCodeRangeIndex,
        into shadowStarts: inout [String: Int]
    ) {
        guard headerRange.length > 0 else { return }
        let header = source.substring(with: headerRange) as NSString
        let matches = identifierRegex.matches(in: header as String, range: NSRange(location: 0, length: header.length))
        for match in matches {
            let name = header.substring(with: match.range)
            guard shadowedNames.contains(name),
                  methodParameterNameRange(match.range, in: header)
                    || cParameterNameRange(match.range, in: header) else {
                continue
            }
            let absoluteLocation = headerRange.location + match.range.location
            guard !nonCodeRangeIndex.intersects(
                NSRange(location: absoluteLocation, length: match.range.length)
            ) else {
                continue
            }
            shadowStarts[name] = min(shadowStarts[name] ?? absoluteLocation, absoluteLocation)
        }
    }

    private static func collectLocalVariableShadows(
        in scope: (location: Int, bodyOpenLocation: Int, upperBound: Int),
        source: NSString,
        shadowedNames: Set<String>,
        nonCodeRangeIndex: ObjectiveCNonCodeRangeIndex,
        into shadowScopes: inout [(name: String, range: NSRange)]
    ) {
        let bodyStart = min(source.length, scope.bodyOpenLocation + 1)
        let bodyEnd = max(bodyStart, min(source.length, scope.upperBound - 1))
        let bodyRange = NSRange(location: bodyStart, length: bodyEnd - bodyStart)
        let body = source.substring(with: bodyRange) as NSString
        for match in objectiveCLocalVariableShadowDeclarationRegex.matches(
            in: body as String,
            range: NSRange(location: 0, length: body.length)
        ) {
            let anchorRange = match.range(at: 1)
            guard anchorRange.location != NSNotFound else { continue }
            let absoluteLineRange = source.lineRange(
                for: NSRange(location: bodyRange.location + anchorRange.location, length: 0)
            )
            let line = source.substring(with: absoluteLineRange) as NSString
            let statementEnd = firstLocation(ofAny: [";"], in: line, before: line.length)
            let firstTerminator = firstLocation(ofAny: ["=", ";"], in: line, before: line.length)
            guard statementEnd != NSNotFound,
                  firstTerminator != NSNotFound,
                  line.range(of: "(", options: [], range: NSRange(location: 0, length: firstTerminator)).location == NSNotFound else {
                continue
            }
            for nameRange in declarationNameRanges(in: line, statementEnd: statementEnd) {
                let absoluteLocation = absoluteLineRange.location + nameRange.location
                guard !nonCodeRangeIndex.intersects(
                    NSRange(location: absoluteLocation, length: nameRange.length)
                ) else {
                    continue
                }
                let name = line.substring(with: nameRange)
                guard shadowedNames.contains(name) else { continue }
                let upperBound = localVariableShadowUpperBound(startingAt: absoluteLocation, in: source, scope: scope)
                shadowScopes.append((
                    name: name,
                    range: NSRange(location: absoluteLocation, length: max(0, upperBound - absoluteLocation))
                ))
            }
        }

        for match in objectiveCForLoopVariableShadowDeclarationRegex.matches(
            in: body as String,
            range: NSRange(location: 0, length: body.length)
        ) {
            let matchRange = NSRange(location: bodyRange.location + match.range.location, length: match.range.length)
            let upperBound = forLoopShadowUpperBound(
                matchRange: matchRange,
                source: source,
                nonCodeRangeIndex: nonCodeRangeIndex,
                scopeUpperBound: scope.upperBound
            )
            for nameRange in forLoopDeclarationNameRanges(
                matchRange: matchRange,
                source: source
            ) {
                let absoluteLocation = nameRange.location
                guard !nonCodeRangeIndex.intersects(nameRange) else {
                    continue
                }
                let name = source.substring(with: nameRange)
                guard shadowedNames.contains(name) else { continue }
                shadowScopes.append((
                    name: name,
                    range: NSRange(location: absoluteLocation, length: max(0, upperBound - absoluteLocation))
                ))
            }
        }
    }

    private static func localVariableShadowUpperBound(
        startingAt location: Int,
        in source: NSString,
        scope: (location: Int, bodyOpenLocation: Int, upperBound: Int)
    ) -> Int {
        guard let openBrace = innermostOpenBraceLocation(
            containing: location,
            lowerBound: scope.bodyOpenLocation,
            in: source
        ),
              let closeBrace = matchingClosingBraceLocation(in: source, openBraceLocation: openBrace) else {
            return scope.upperBound
        }
        return min(scope.upperBound, closeBrace + 1)
    }

    private static func forLoopShadowUpperBound(
        matchRange: NSRange,
        source: NSString,
        nonCodeRangeIndex: ObjectiveCNonCodeRangeIndex,
        scopeUpperBound: Int
    ) -> Int {
        guard let openParen = nextLocation(ofAny: ["("], after: matchRange.location, in: source),
              let closeParen = matchingCloseParenLocation(openingAt: openParen, in: source) else {
            return min(scopeUpperBound, matchRange.upperBound)
        }

        var cursor = closeParen + 1
        let upperBound = min(scopeUpperBound, source.length)
        while cursor < upperBound {
            if let nextCursor = nonCodeRangeIndex.upperBoundOfRange(containing: cursor) {
                cursor = min(nextCursor, upperBound)
                continue
            }
            let character = source.character(at: cursor)
            if isWhitespaceCodeUnit(character) {
                cursor += 1
                continue
            }
            if character == openBraceCodeUnit,
               let closeBrace = matchingClosingBraceLocation(in: source, openBraceLocation: cursor) {
                return min(scopeUpperBound, closeBrace + 1)
            }
            if character == semicolonCodeUnit {
                return min(scopeUpperBound, cursor + 1)
            }
            cursor += 1
        }
        return scopeUpperBound
    }

    private static func forLoopDeclarationNameRanges(matchRange: NSRange, source: NSString) -> [NSRange] {
        guard let openParen = nextLocation(ofAny: ["("], after: matchRange.location, in: source),
              let closeParen = matchingCloseParenLocation(openingAt: openParen, in: source),
              openParen < closeParen else {
            return []
        }
        let clauseRange = NSRange(location: openParen + 1, length: closeParen - openParen - 1)
        let clause = source.substring(with: clauseRange) as NSString
        let declarationEnd = forLoopDeclarationEnd(in: clause)
        guard declarationEnd != NSNotFound else {
            return []
        }
        return declarationNameRanges(in: clause, statementEnd: declarationEnd)
            .map { NSRange(location: clauseRange.location + $0.location, length: $0.length) }
    }

    private static func forLoopDeclarationEnd(in clause: NSString) -> Int {
        var cursor = 0
        var parenDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        var angleDepth = 0
        while cursor < clause.length {
            if let nextCursor = indexAfterCommentOrQuotedLiteral(startingAt: cursor, in: clause) {
                cursor = nextCursor
                continue
            }
            let character = clause.character(at: cursor)
            updateDeclarationDelimiterDepth(
                character: character,
                next: cursor + 1 < clause.length
                    ? clause.character(at: cursor + 1)
                    : 0,
                parenDepth: &parenDepth,
                bracketDepth: &bracketDepth,
                braceDepth: &braceDepth,
                angleDepth: &angleDepth
            )
            if parenDepth == 0,
               bracketDepth == 0,
               braceDepth == 0,
               angleDepth == 0 {
                if character == semicolonCodeUnit {
                    return cursor
                }
                if clauseHasStandaloneIn(at: cursor, in: clause) {
                    return cursor
                }
            }
            cursor += 1
        }
        return NSNotFound
    }

    private static func clauseHasStandaloneIn(at location: Int, in clause: NSString) -> Bool {
        let keywordLength = "in".utf16.count
        guard location + keywordLength <= clause.length,
              clause.substring(with: NSRange(location: location, length: keywordLength)) == "in" else {
            return false
        }
        let before = location == 0 ? nil : clause.character(at: location - 1)
        let afterLocation = location + keywordLength
        let after = afterLocation < clause.length ? clause.character(at: afterLocation) : nil
        return before.map(isASCIIIdentifierContinue) != true
            && after.map(isASCIIIdentifierContinue) != true
    }

    private static func innermostOpenBraceLocation(
        containing location: Int,
        lowerBound: Int,
        in source: NSString
    ) -> Int? {
        let upperBound = min(max(0, location), source.length)
        var stack: [Int] = []
        var cursor = min(max(0, lowerBound), upperBound)
        while cursor < upperBound {
            if let nextCursor = indexAfterCommentOrQuotedLiteral(startingAt: cursor, in: source) {
                cursor = min(nextCursor, upperBound)
                continue
            }
            let character = source.character(at: cursor)
            if character == openBraceCodeUnit {
                stack.append(cursor)
            } else if character == closeBraceCodeUnit {
                _ = stack.popLast()
            }
            cursor += 1
        }
        return stack.last
    }

    private static func identifierRanges(named name: String, in range: NSRange, source: NSString) -> [NSRange] {
        identifierRegex
            .matches(in: source as String, range: range)
            .compactMap { match in
                source.substring(with: match.range) == name ? match.range : nil
            }
    }

    private static func methodParameterNameRange(_ range: NSRange, in header: NSString) -> Bool {
        guard let closeParen = previousNonWhitespaceLocation(before: range.location, in: header),
              header.character(at: closeParen) == closeParenCodeUnit,
              let openParen = matchingOpeningParenLocation(before: closeParen, in: header),
              let beforeType = previousNonWhitespaceLocation(before: openParen, in: header) else {
            return false
        }
        return header.character(at: beforeType) == colonCodeUnit
    }

    private static func cParameterNameRange(_ range: NSRange, in header: NSString) -> Bool {
        guard let delimiterBefore = previousLocation(ofAny: ["(", ","], before: range.location, in: header),
              let delimiterAfter = nextLocation(ofAny: [")", ","], after: range.upperBound, in: header),
              delimiterBefore < range.location,
              range.upperBound <= delimiterAfter else {
            return false
        }
        let segmentRange = NSRange(location: delimiterBefore + 1, length: delimiterAfter - delimiterBefore - 1)
        let segment = header.substring(with: segmentRange) as NSString
        guard let relativeNameRange = identifierRange(before: segment.length, in: segment) else {
            return false
        }
        return segmentRange.location + relativeNameRange.location == range.location
            && relativeNameRange.length == range.length
    }

    private static func previousNonWhitespaceLocation(before location: Int, in text: NSString) -> Int? {
        guard location > 0 else { return nil }
        var cursor = min(location, text.length) - 1
        while cursor >= 0 {
            let character = text.character(at: cursor)
            if !isWhitespaceCodeUnit(character) {
                return cursor
            }
            if cursor == 0 { break }
            cursor -= 1
        }
        return nil
    }

    private static func matchingOpeningParenLocation(before closeParen: Int, in text: NSString) -> Int? {
        var depth = 0
        var cursor = closeParen
        while cursor >= 0 {
            let character = text.character(at: cursor)
            if character == closeParenCodeUnit {
                depth += 1
            } else if character == openParenCodeUnit {
                depth -= 1
                if depth == 0 {
                    return cursor
                }
            }
            if cursor == 0 { break }
            cursor -= 1
        }
        return nil
    }

    private static func previousLocation(ofAny needles: [String], before location: Int, in text: NSString) -> Int? {
        let needleCodeUnits = needles.compactMap(singleUTF16CodeUnit)
        guard location > 0 else { return nil }
        var cursor = min(location, text.length) - 1
        while cursor >= 0 {
            let character = text.character(at: cursor)
            if needleCodeUnits.contains(character) {
                return cursor
            }
            if cursor == 0 { break }
            cursor -= 1
        }
        return nil
    }

    private static func nextLocation(ofAny needles: [String], after location: Int, in text: NSString) -> Int? {
        let needleCodeUnits = needles.compactMap(singleUTF16CodeUnit)
        var cursor = min(max(0, location), text.length)
        while cursor < text.length {
            let character = text.character(at: cursor)
            if needleCodeUnits.contains(character) {
                return cursor
            }
            cursor += 1
        }
        return nil
    }

    private static func matchingCloseParenLocation(openingAt openParen: Int, in text: NSString) -> Int? {
        var depth = 0
        var cursor = openParen
        while cursor < text.length {
            if let nextCursor = indexAfterCommentOrQuotedLiteral(startingAt: cursor, in: text) {
                cursor = nextCursor
                continue
            }
            let character = text.character(at: cursor)
            if character == openParenCodeUnit {
                depth += 1
            } else if character == closeParenCodeUnit {
                depth -= 1
                if depth == 0 {
                    return cursor
                }
            }
            cursor += 1
        }
        return nil
    }

    private static func matchingClosingBraceLocation(in source: NSString, openBraceLocation: Int) -> Int? {
        var cursor = openBraceLocation + 1
        var depth = 1
        while cursor < source.length {
            if let nextCursor = indexAfterCommentOrQuotedLiteral(startingAt: cursor, in: source) {
                cursor = nextCursor
                continue
            }
            let character = source.character(at: cursor)
            if character == openBraceCodeUnit, depth == 0 {
                depth = 1
            } else if character == openBraceCodeUnit {
                depth += 1
            } else if character == closeBraceCodeUnit {
                depth -= 1
                if depth == 0 {
                    return cursor
                }
            }
            cursor += 1
        }
        return nil
    }

    private static func indexAfterCommentOrQuotedLiteral(startingAt location: Int, in text: NSString) -> Int? {
        guard location >= 0,
              location < text.length else {
            return nil
        }
        let character = text.character(at: location)
        let next = location + 1 < text.length
            ? text.character(at: location + 1)
            : 0
        if character == doubleQuoteCodeUnit || character == singleQuoteCodeUnit {
            return indexAfterQuotedLiteral(startingAt: location, quote: character, in: text)
        }
        if character == slashCodeUnit, next == slashCodeUnit {
            return text.lineRange(for: NSRange(location: location, length: 0)).upperBound
        }
        if character == slashCodeUnit, next == starCodeUnit {
            var cursor = location + 2
            while cursor + 1 < text.length {
                let current = text.character(at: cursor)
                let following = text.character(at: cursor + 1)
                if current == starCodeUnit, following == slashCodeUnit {
                    return cursor + 2
                }
                cursor += 1
            }
            return text.length
        }
        return nil
    }

    private static func isInsideCommentOrLiteral(_ range: NSRange, in text: NSString) -> Bool {
        var cursor = 0
        while cursor < min(range.location, text.length) {
            if let nextCursor = indexAfterCommentOrQuotedLiteral(startingAt: cursor, in: text) {
                if nextCursor > range.location {
                    return true
                }
                cursor = nextCursor
                continue
            }
            cursor += 1
        }
        return false
    }

    private static func objectiveCBraceDepth(
        afterScanning line: NSString,
        startingAt depth: Int,
        isInBlockComment: Bool
    ) -> (depth: Int, isInBlockComment: Bool) {
        var result = depth
        var isInBlockComment = isInBlockComment
        var cursor = 0
        while cursor < line.length {
            let character = line.character(at: cursor)
            let nextLocation = cursor + 1
            let next = nextLocation < line.length
                ? line.character(at: nextLocation)
                : 0
            if isInBlockComment {
                if character == starCodeUnit, next == slashCodeUnit {
                    isInBlockComment = false
                    cursor += 2
                    continue
                }
                cursor += 1
                continue
            }
            if character == slashCodeUnit, next == slashCodeUnit {
                break
            }
            if character == slashCodeUnit, next == starCodeUnit {
                isInBlockComment = true
                cursor += 2
                continue
            }
            if character == doubleQuoteCodeUnit || character == singleQuoteCodeUnit {
                cursor = indexAfterQuotedLiteral(startingAt: cursor, quote: character, in: line)
                continue
            }
            if character == openBraceCodeUnit {
                result += 1
            } else if character == closeBraceCodeUnit {
                result = max(0, result - 1)
            }
            cursor += 1
        }
        return (result, isInBlockComment)
    }

    private static func indexAfterQuotedLiteral(startingAt quoteLocation: Int, quote: String, in text: NSString) -> Int {
        guard let quote = singleUTF16CodeUnit(quote) else {
            return min(text.length, quoteLocation + 1)
        }
        return indexAfterQuotedLiteral(startingAt: quoteLocation, quote: quote, in: text)
    }

    private static func indexAfterQuotedLiteral(startingAt quoteLocation: Int, quote: unichar, in text: NSString) -> Int {
        var cursor = quoteLocation + 1
        var isEscaped = false
        while cursor < text.length {
            let character = text.character(at: cursor)
            if isEscaped {
                isEscaped = false
            } else if character == backslashCodeUnit {
                isEscaped = true
            } else if character == quote {
                return cursor + 1
            }
            cursor += 1
        }
        return text.length
    }

    private static func scanImplementationIvarDeclarations(
        source: NSString,
        nonCodeRangeIndex: ObjectiveCNonCodeRangeIndex
    ) -> [(name: String, range: NSRange)] {
        var declarations: [(name: String, range: NSRange)] = []
        var location = 0
        var awaitingIvarBlock = false
        var isInIvarBlock = false

        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let line = source.substring(with: lineRange) as NSString
            let trimmed = (line as String).trimmingCharacters(in: .whitespacesAndNewlines)
            defer {
                let nextLocation = lineRange.upperBound
                location = nextLocation > location ? nextLocation : source.length
            }

            if isInIvarBlock {
                let closeBraceRange = firstBraceRange(in: line, brace: "}")
                let ivarSegmentLength = closeBraceRange?.location ?? line.length
                appendImplementationIvarDeclarations(
                    in: line.substring(with: NSRange(location: 0, length: ivarSegmentLength)) as NSString,
                    lineOffset: lineRange.location,
                    nonCodeRangeIndex: nonCodeRangeIndex,
                    to: &declarations
                )
                if closeBraceRange != nil {
                    isInIvarBlock = false
                    awaitingIvarBlock = false
                }
                continue
            }

            if awaitingIvarBlock {
                if let openBraceRange = firstBraceRange(in: line, brace: "{") {
                    let segmentStart = openBraceRange.upperBound
                    let closeBraceRange = firstBraceRange(in: line, brace: "}", after: segmentStart)
                    let segmentUpperBound = closeBraceRange?.location ?? line.length
                    appendImplementationIvarDeclarations(
                        in: line.substring(with: NSRange(location: segmentStart, length: segmentUpperBound - segmentStart)) as NSString,
                        lineOffset: lineRange.location + segmentStart,
                        nonCodeRangeIndex: nonCodeRangeIndex,
                        to: &declarations
                    )
                    isInIvarBlock = closeBraceRange == nil
                    awaitingIvarBlock = closeBraceRange == nil
                } else if !trimmed.isEmpty && !isObjectiveCCommentOnlyLine(trimmed) {
                    awaitingIvarBlock = false
                }
                continue
            }

            guard trimmed.hasPrefix("@implementation") else {
                continue
            }
            if let openBraceRange = firstBraceRange(in: line, brace: "{") {
                let segmentStart = openBraceRange.upperBound
                let closeBraceRange = firstBraceRange(in: line, brace: "}", after: segmentStart)
                let segmentUpperBound = closeBraceRange?.location ?? line.length
                appendImplementationIvarDeclarations(
                    in: line.substring(with: NSRange(location: segmentStart, length: segmentUpperBound - segmentStart)) as NSString,
                    lineOffset: lineRange.location + segmentStart,
                    nonCodeRangeIndex: nonCodeRangeIndex,
                    to: &declarations
                )
                isInIvarBlock = closeBraceRange == nil
                awaitingIvarBlock = false
            } else {
                awaitingIvarBlock = true
            }
        }
        return declarations
    }

    private static func isObjectiveCCommentOnlyLine(_ trimmedLine: String) -> Bool {
        trimmedLine.hasPrefix("//")
            || trimmedLine.hasPrefix("/*")
            || trimmedLine.hasPrefix("*")
            || trimmedLine.hasPrefix("*/")
    }

    private static func firstBraceRange(in line: NSString, brace: String, after location: Int = 0) -> NSRange? {
        guard let brace = singleUTF16CodeUnit(brace) else { return nil }
        return firstCodeCharacterRange(in: line, character: brace, after: location)
    }

    private static func firstCodeCharacterRange(in line: NSString, character: String, after location: Int = 0) -> NSRange? {
        guard let character = singleUTF16CodeUnit(character) else { return nil }
        return firstCodeCharacterRange(in: line, character: character, after: location)
    }

    private static func firstCodeCharacterRange(in line: NSString, character: unichar, after location: Int = 0) -> NSRange? {
        var cursor = min(max(0, location), line.length)
        while cursor < line.length {
            if let nextCursor = indexAfterCommentOrQuotedLiteral(startingAt: cursor, in: line) {
                cursor = nextCursor
                continue
            }
            if line.character(at: cursor) == character {
                return NSRange(location: cursor, length: 1)
            }
            cursor += 1
        }
        return nil
    }

    private static func appendImplementationIvarDeclarations(
        in segment: NSString,
        lineOffset: Int,
        nonCodeRangeIndex: ObjectiveCNonCodeRangeIndex,
        to declarations: inout [(name: String, range: NSRange)]
    ) {
        var statementStart = 0
        while statementStart < segment.length {
            let searchRange = NSRange(location: statementStart, length: segment.length - statementStart)
            let semicolonRange = segment.range(of: ";", options: [], range: searchRange)
            guard semicolonRange.location != NSNotFound else {
                return
            }

            let statementRange = NSRange(
                location: statementStart,
                length: semicolonRange.upperBound - statementStart
            )
            let statement = segment.substring(with: statementRange) as NSString
            for relativeRange in implementationIvarNameRanges(in: statement) {
                let absoluteRange = NSRange(
                    location: lineOffset + statementStart + relativeRange.location,
                    length: relativeRange.length
                )
                guard !nonCodeRangeIndex.intersects(absoluteRange) else {
                    continue
                }
                let name = statement.substring(with: relativeRange)
                declarations.append((
                    name: name,
                    range: absoluteRange
                ))
            }
            statementStart = semicolonRange.upperBound
        }
    }

    private static func implementationIvarNameRanges(in line: NSString) -> [NSRange] {
        let semicolonRange = line.range(of: ";")
        guard semicolonRange.location != NSNotFound,
              line.range(of: "(", options: [], range: NSRange(location: 0, length: semicolonRange.location)).location == NSNotFound else {
            return []
        }
        return declarationNameRanges(in: line, statementEnd: semicolonRange.location)
    }

    private static func firstLocation(ofAny needles: [String], in text: NSString, before end: Int) -> Int {
        var result = NSNotFound
        let range = NSRange(location: 0, length: max(0, min(end, text.length)))
        for needle in needles {
            let match = text.range(of: needle, options: [], range: range)
            if match.location != NSNotFound,
               result == NSNotFound || match.location < result {
                result = match.location
            }
        }
        return result
    }

    static func typedefDeclaredName(in declaration: NSString) -> String? {
        if let declaredName = nsEnumOptionsTypedefDeclaredName(in: declaration) {
            return declaredName.name
        }
        if let blockName = blockTypedefDeclaredName(in: declaration) {
            return blockName
        }

        let string = declaration as String
        let matches = identifierRegex.matches(
            in: string,
            range: NSRange(location: 0, length: declaration.length)
        )
        for match in matches.reversed() {
            let name = declaration.substring(with: match.range)
            if !typedefIgnoredIdentifiers.contains(name) {
                return name
            }
        }
        return nil
    }

    private static func nsEnumOptionsTypedefDeclaredName(in declaration: NSString) -> (name: String, range: NSRange)? {
        let string = declaration as String
        guard let match = nsEnumOptionsTypedefNameRegex.firstMatch(
            in: string,
            range: NSRange(location: 0, length: declaration.length)
        ) else {
            return nil
        }
        let range = match.range(at: 1)
        guard range.location != NSNotFound else {
            return nil
        }
        return (declaration.substring(with: range), range)
    }

    private static func blockTypedefDeclaredName(in declaration: NSString) -> String? {
        let string = declaration as String
        guard let match = blockTypedefNameRegex.firstMatch(
            in: string,
            range: NSRange(location: 0, length: declaration.length)
        ) else {
            return nil
        }
        let range = match.range(at: 1)
        guard range.location != NSNotFound else {
            return nil
        }
        return declaration.substring(with: range)
    }

    private static func scanLocalPropertyDeclarations(
        source: NSString,
        tokenIndex: ObjectiveCTokenIndex
    ) -> [(name: String, range: NSRange)] {
        let string = source as String
        let fullRange = NSRange(location: 0, length: source.length)
        var declarations: [(name: String, range: NSRange)] = []

        for match in propertyDeclarationRegex.matches(in: string, range: fullRange) {
            let propertyKeywordRange = NSRange(location: match.range.location, length: "@property".count)
            guard tokenIndex.containsPropertyKeywordRange(propertyKeywordRange) else {
                continue
            }

            let declaration = source.substring(with: match.range) as NSString
            if propertyDeclarationAppearsToSwallowFollowingDeclaration(in: declaration) {
                continue
            }
            guard let relativeNameRange = propertyDeclaredNameRange(in: declaration) else {
                continue
            }
            let range = NSRange(
                location: match.range.location + relativeNameRange.location,
                length: relativeNameRange.length
            )
            let name = source.substring(with: range)
            if isIdentifier(name),
               !typedefIgnoredIdentifiers.contains(name),
               tokenIndex.containsIdentifierRange(range) {
                declarations.append((name: name, range: range))
            }
        }

        return declarations
    }

    static func propertyDeclaredNameRange(in declaration: NSString) -> NSRange? {
        let string = declaration as String
        if let match = blockPropertyNameRegex.firstMatch(
            in: string,
            range: NSRange(location: 0, length: declaration.length)
        ) {
            let range = match.range(at: 1)
            if range.location != NSNotFound {
                return range
            }
        }
        if let match = functionPointerPropertyNameRegex.firstMatch(
            in: string,
            range: NSRange(location: 0, length: declaration.length)
        ) {
            let range = match.range(at: 1)
            if range.location != NSNotFound {
                return range
            }
        }
        let searchRange = propertyNameFallbackSearchRange(in: declaration)
        guard searchRange.length > 0 else {
            return nil
        }

        let searchableDeclaration = declaration.substring(with: searchRange) + ";"
        if let match = propertyNameBeforeTrailingAttributesRegex.firstMatch(
            in: searchableDeclaration,
            range: NSRange(location: 0, length: (searchableDeclaration as NSString).length)
        ) {
            let range = match.range(at: 1)
            if range.location != NSNotFound,
               range.upperBound <= searchRange.length {
                return range
            }
        }

        return identifierRegex.matches(
            in: string,
            range: searchRange
        ).last?.range
    }

    private static func propertyDeclarationAppearsToSwallowFollowingDeclaration(in declaration: NSString) -> Bool {
        let bodyStart = propertyBodyStart(in: declaration)
        guard bodyStart < declaration.length else {
            return false
        }

        let body = declaration.substring(from: bodyStart)
        let lines = body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        guard lines.count > 1 else {
            return false
        }

        var previousLineContainsDeclaratorName = false
        for line in lines {
            if previousLineContainsDeclaratorName,
               propertyContinuationLineLooksLikeStandaloneDeclaration(line) {
                return true
            }
            previousLineContainsDeclaratorName = propertyBodyLineContainsDeclaratorName(line)
        }
        return false
    }

    private static func propertyBodyLineContainsDeclaratorName(_ line: String) -> Bool {
        let body = line as NSString
        let bodyWithoutGenerics = stringByRemovingAngleBracketContents(from: body)
        let end = trimmingTrailingPropertySyntax(in: bodyWithoutGenerics, end: bodyWithoutGenerics.length)
        guard let lastIdentifierRange = identifierRange(before: end, in: bodyWithoutGenerics) else {
            return false
        }
        return identifierRegex.firstMatch(
            in: bodyWithoutGenerics as String,
            range: NSRange(location: 0, length: lastIdentifierRange.location)
        ) != nil
    }

    private static func stringByRemovingAngleBracketContents(from text: NSString) -> NSString {
        var result = ""
        var depth = 0
        for character in text as String {
            if character == "<" {
                depth += 1
                continue
            }
            if character == ">", depth > 0 {
                depth -= 1
                continue
            }
            if depth == 0 {
                result.append(character)
            }
        }
        return result as NSString
    }

    private static func propertyContinuationLineLooksLikeStandaloneDeclaration(_ line: String) -> Bool {
        let trimmedLine = (line as NSString)
        let end = trimmingTrailingPropertySyntax(in: trimmedLine, end: trimmedLine.length)
        guard end > 0 else {
            return false
        }
        let declaration = trimmedLine.substring(to: end) as NSString
        let matches = identifierRegex.matches(
            in: declaration as String,
            range: NSRange(location: 0, length: declaration.length)
        )
        guard let firstMatch = matches.first else {
            return false
        }

        let firstIdentifier = declaration.substring(with: firstMatch.range)
        if isLikelyTrailingPropertyAttribute(firstIdentifier, in: declaration, matchCount: matches.count) {
            return false
        }
        if (declaration as String).contains("*") {
            return matches.count >= 1
        }
        return matches.count >= 2
    }

    private static func isLikelyTrailingPropertyAttribute(
        _ name: String,
        in declaration: NSString,
        matchCount: Int
    ) -> Bool {
        if name.hasPrefix("__") || bareTrailingPropertyAttributes.contains(name) {
            return true
        }
        if name.range(
            of: #"^(?:NS|CF|API|AVAILABLE|DEPRECATED|IB)_"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        if isUppercaseIdentifier(name) {
            if matchCount == 1 {
                return true
            }
            let suffix = declaration.substring(from: name.utf16.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return suffix.first == "("
        }
        return false
    }

    private static func propertyNameFallbackSearchRange(in declaration: NSString) -> NSRange {
        var end = declaration.length
        end = trimmingTrailingPropertySyntax(in: declaration, end: end)

        var didStripSuffix = true
        while didStripSuffix {
            didStripSuffix = false
            end = trimmingTrailingPropertySyntax(in: declaration, end: end)

            if let range = trailingFunctionLikeMacroRange(in: declaration, end: end),
               hasIdentifierBefore(range.location, in: declaration) {
                end = range.location
                didStripSuffix = true
                continue
            }

            if let range = trailingIdentifierRange(in: declaration, end: end) {
                let name = declaration.substring(with: range)
                if shouldStripBareTrailingPropertyAttribute(
                    name,
                    before: range.location,
                    in: declaration
                ),
                   hasIdentifierBefore(range.location, in: declaration) {
                    end = range.location
                    didStripSuffix = true
                }
            }
        }

        end = trimmingTrailingPropertySyntax(in: declaration, end: end)
        return NSRange(location: 0, length: max(0, end))
    }

    private static func propertyReferenceShouldBeTracked(
        name: String,
        range: NSRange,
        in declaration: NSString
    ) -> Bool {
        guard isUppercaseIdentifier(name),
              name.contains("_") else {
            return true
        }

        let trailingStart = range.upperBound
        guard trailingStart < declaration.length else {
            return true
        }
        let trailing = declaration.substring(from: trailingStart)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trailing.isEmpty == false,
              trailing != ";" else {
            return true
        }
        return false
    }

    private static func trimmingTrailingPropertySyntax(in declaration: NSString, end: Int) -> Int {
        var end = end
        while end > 0 {
            let character = declaration.substring(with: NSRange(location: end - 1, length: 1))
            if character == ";" || isWhitespace(character) {
                end -= 1
            } else {
                break
            }
        }
        return end
    }

    private static func trailingFunctionLikeMacroRange(in declaration: NSString, end: Int) -> NSRange? {
        guard end > 0,
              declaration.substring(with: NSRange(location: end - 1, length: 1)) == ")",
              let openParen = matchingOpeningParenthesis(in: declaration, before: end),
              let nameRange = identifierRange(before: openParen, in: declaration)
        else {
            return nil
        }

        let name = declaration.substring(with: nameRange)
        guard isIdentifier(name) else {
            return nil
        }
        return NSRange(location: nameRange.location, length: end - nameRange.location)
    }

    private static func matchingOpeningParenthesis(in declaration: NSString, before end: Int) -> Int? {
        var depth = 0
        var cursor = end - 1
        while cursor >= 0 {
            let character = declaration.substring(with: NSRange(location: cursor, length: 1))
            if character == ")" {
                depth += 1
            } else if character == "(" {
                depth -= 1
                if depth == 0 {
                    return cursor
                }
                if depth < 0 {
                    return nil
                }
            }

            if cursor == 0 {
                break
            }
            cursor -= 1
        }
        return nil
    }

    private static func trailingIdentifierRange(in declaration: NSString, end: Int) -> NSRange? {
        identifierRange(before: end, in: declaration)
    }

    private static func identifierRange(before location: Int, in declaration: NSString) -> NSRange? {
        var end = location
        while end > 0 {
            let character = declaration.substring(with: NSRange(location: end - 1, length: 1))
            if isWhitespace(character) {
                end -= 1
            } else {
                break
            }
        }

        var start = end
        while start > 0 {
            let character = Character(declaration.substring(with: NSRange(location: start - 1, length: 1)))
            if isIdentifierCharacter(character) {
                start -= 1
            } else {
                break
            }
        }
        guard start < end else {
            return nil
        }
        return NSRange(location: start, length: end - start)
    }

    private static func hasIdentifierBefore(_ location: Int, in declaration: NSString) -> Bool {
        identifierRegex.firstMatch(
            in: declaration as String,
            range: NSRange(location: 0, length: max(0, location))
        ) != nil
    }

    private static func shouldStripBareTrailingPropertyAttribute(
        _ name: String,
        before location: Int,
        in declaration: NSString
    ) -> Bool {
        if name.hasPrefix("__") || bareTrailingPropertyAttributes.contains(name) {
            return true
        }
        guard name.contains("_"),
              name == name.uppercased(),
              let previousRange = trailingIdentifierRange(in: declaration, end: location) else {
            return false
        }
        let previousName = declaration.substring(with: previousRange)
        if isUppercaseIdentifier(previousName) {
            return hasPropertyTypeIdentifierBefore(previousRange.location, in: declaration)
        }
        guard !typedefIgnoredIdentifiers.contains(previousName),
              !isLikelyLowercaseTypedefName(previousName),
              let firstCharacter = previousName.first else {
            return false
        }
        return firstCharacter == "_" || firstCharacter.isLowercase
    }

    private static func isUppercaseIdentifier(_ name: String) -> Bool {
        name == name.uppercased() && name.contains { $0.isLetter }
    }

    private static func hasPropertyTypeIdentifierBefore(_ location: Int, in declaration: NSString) -> Bool {
        let start = propertyBodyStart(in: declaration)
        guard start < location else {
            return false
        }
        return identifierRegex.firstMatch(
            in: declaration as String,
            range: NSRange(location: start, length: location - start)
        ) != nil
    }

    private static func propertyBodyStart(in declaration: NSString) -> Int {
        var cursor = "@property".utf16.count
        while cursor < declaration.length,
              isWhitespace(declaration.substring(with: NSRange(location: cursor, length: 1))) {
            cursor += 1
        }

        if cursor < declaration.length,
           declaration.substring(with: NSRange(location: cursor, length: 1)) == "(",
           let closeParen = matchingClosingParenthesis(in: declaration, after: cursor) {
            cursor = closeParen + 1
            while cursor < declaration.length,
                  isWhitespace(declaration.substring(with: NSRange(location: cursor, length: 1))) {
                cursor += 1
            }
        }
        return cursor
    }

    private static func matchingClosingParenthesis(in declaration: NSString, after openParen: Int) -> Int? {
        var depth = 0
        var cursor = openParen
        while cursor < declaration.length {
            let character = declaration.substring(with: NSRange(location: cursor, length: 1))
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    return cursor
                }
                if depth < 0 {
                    return nil
                }
            }
            cursor += 1
        }
        return nil
    }

    private static func isLikelyLowercaseTypedefName(_ name: String) -> Bool {
        name.contains("_") && name.allSatisfy { character in
            character == "_" || character.isLowercase || character.isNumber
        }
    }

    private static func isWhitespace(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    private static func zeroArgumentMethodNameRanges(in source: NSString) -> [NSRange] {
        let string = source as String
        let fullRange = NSRange(location: 0, length: source.length)
        return zeroArgumentMethodRegex.matches(in: string, range: fullRange).compactMap { match in
            guard match.numberOfRanges > 1 else {
                return nil
            }
            let range = match.range(at: 1)
            return range.location == NSNotFound ? nil : range
        }
    }

    private static func isZeroArgumentMethodName(
        _ range: NSRange,
        in zeroArgumentMethodNameRanges: [NSRange]
    ) -> Bool {
        zeroArgumentMethodNameRanges.contains {
            NSIntersectionRange($0, range).length > 0
        }
    }

    private static func isIdentifier(_ text: String) -> Bool {
        let nsText = text as NSString
        return isIdentifierRange(NSRange(location: 0, length: nsText.length), in: nsText)
    }

    static func isIdentifierRange(_ range: NSRange, in source: NSString) -> Bool {
        guard range.location >= 0,
              range.length > 0,
              range.upperBound <= source.length,
              isASCIIIdentifierStart(source.character(at: range.location))
        else {
            return false
        }
        var cursor = range.location + 1
        while cursor < range.upperBound {
            guard isASCIIIdentifierContinue(source.character(at: cursor)) else {
                return false
            }
            cursor += 1
        }
        return true
    }

    private static func isASCIIIdentifierStart(_ unit: unichar) -> Bool {
        unit == 95
            || (65...90).contains(unit)
            || (97...122).contains(unit)
    }

    private static func isASCIIIdentifierContinue(_ unit: unichar) -> Bool {
        isASCIIIdentifierStart(unit) || (48...57).contains(unit)
    }

    private static let localTypeRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"@(?:interface|implementation|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)"#),
        try! NSRegularExpression(pattern: #"@class\s+([A-Za-z_][A-Za-z0-9_]*)"#),
        try! NSRegularExpression(pattern: #"\bNS_(?:ENUM|OPTIONS)\s*\([^,]+,\s*([A-Za-z_][A-Za-z0-9_]*)"#),
        try! NSRegularExpression(pattern: #"\b(?:struct|union|enum)\s+([A-Za-z_][A-Za-z0-9_]*)"#),
    ]

    private static let propertyDeclarationRegex = try! NSRegularExpression(
        pattern: #"@property\b[^\n;]*(?:\n(?!\s*(?:[-+]|@))[^\n;]*)*;"#
    )

    private static let definedMacroNameRegex = try! NSRegularExpression(
        pattern: #"(?m)^\s*#\s*define\s+([A-Za-z_][A-Za-z0-9_]*)"#
    )

    private static let objectiveCFunctionLikeSignatureLineRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:[-+]\s*\(|(?:static\s+)?[A-Za-z_][A-Za-z0-9_ <>,_*]*[ \t*]+[A-Za-z_][A-Za-z0-9_]*\s*\()"#
    )

    private static let objectiveCSplitCFunctionNameLineRegex = try! NSRegularExpression(
        pattern: #"^\s*(?!(?:return|if|for|while|switch|case|break|continue|goto|else|do|sizeof)\b)[A-Za-z_][A-Za-z0-9_]*\s*\([^;{}=]*\)"#
    )

    private static let objectiveCLocalVariableShadowDeclarationRegex = try! NSRegularExpression(
        pattern: #"(?m)^\s*(?:static\s+)?(?!(?:return|if|for|while|switch|case|break|continue|goto|else|do)\b)[A-Za-z_][A-Za-z0-9_ <>,_*]*[ \t*]+([A-Za-z_][A-Za-z0-9_]*)\s*(?:=|;)"#
    )

    private static let objectiveCForLoopVariableShadowDeclarationRegex = try! NSRegularExpression(
        pattern: #"\bfor\s*\(\s*[A-Za-z_][A-Za-z0-9_ <>,_*]*[ \t*]+([A-Za-z_][A-Za-z0-9_]*)\s*(?:=|in\b)"#
    )

    private static let nsEnumOptionsTypedefNameRegex = try! NSRegularExpression(
        pattern: #"\btypedef\s+NS_(?:ENUM|OPTIONS)\s*\([^,]+,\s*([A-Za-z_][A-Za-z0-9_]*)"#
    )

    private static let blockPropertyNameRegex = try! NSRegularExpression(
        pattern: #"@property\b[^;]*\(\s*\^\s*(?:[A-Za-z_][A-Za-z0-9_]*\s+)*([A-Za-z_][A-Za-z0-9_]*)\s*\)"#
    )

    private static let functionPointerPropertyNameRegex = try! NSRegularExpression(
        pattern: #"\(\s*\*+\s*(?:[A-Za-z_][A-Za-z0-9_]*\s+)*([A-Za-z_][A-Za-z0-9_]*)\s*\)\s*\([^;]*\)"#
    )

    private static let propertyNameBeforeTrailingAttributesRegex = try! NSRegularExpression(
        pattern: #"\b([A-Za-z_][A-Za-z0-9_]*)\s*(?:\[[^\];]*\]\s*)?(?:(?:NS_[A-Z0-9_]+|CF_[A-Z0-9_]+|API_[A-Z0-9_]+|AVAILABLE_[A-Z0-9_]+|DEPRECATED_[A-Z0-9_]+|IB_[A-Z0-9_]+|__[A-Za-z0-9_]+__|__[A-Za-z0-9_]+)\s*(?:\([^;]*\))?\s*)*;"#
    )

    private static let zeroArgumentMethodRegex = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*[-+]\s*\([^)]*\)\s*([A-Za-z_][A-Za-z0-9_]*)\s*[;{]"#
    )

    private static let bareTrailingPropertyAttributes: Set<String> = [
        "IBInspectable", "IBOutlet", "NS_REFINED_FOR_SWIFT"
    ]

    private static let typedefRegex = try! NSRegularExpression(
        pattern: #"\btypedef\b[^;]*;"#,
        options: [.dotMatchesLineSeparators]
    )

    private static let blockTypedefNameRegex = try! NSRegularExpression(
        pattern: #"\(\s*\^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)"#
    )

    static let identifierRegex = try! NSRegularExpression(
        pattern: #"[A-Za-z_][A-Za-z0-9_]*"#
    )

    static let typedefIgnoredIdentifiers: Set<String> = [
        "NS_ENUM", "NS_OPTIONS", "typedef", "struct", "union", "enum",
        "const", "unsigned", "signed", "short", "long", "int", "char",
        "void", "id", "BOOL", "NSInteger", "NSUInteger", "NSString",
        "NSError", "NSRange", "nullable", "nonnull", "_Nullable", "_Nonnull"
    ]

    private static let objectiveCStatementLeadingIdentifiers: Set<String> = [
        "return", "if", "for", "while", "switch", "case", "break", "continue",
        "goto", "else", "do", "sizeof"
    ]

    private static let quotedHeaderImportRegex = try! NSRegularExpression(
        pattern: #"(?m)^\s*#\s*(?:import|include)\s*"[^"]+\.h""#
    )
}
