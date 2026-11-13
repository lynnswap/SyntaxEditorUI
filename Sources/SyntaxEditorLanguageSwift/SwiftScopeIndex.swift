import Foundation
import SyntaxEditorCoreTypes
import SyntaxEditorLanguageSupport
import SwiftTreeSitter

/// Tree-derived scope index for Swift semantic overlays.
///
/// Replaces the regex-collector symbol index: scopes and declarations are derived
/// in a single walk of the tree-sitter syntax tree (no regular expressions, no
/// masked-source string, no per-character scans). Strings and comments cannot
/// produce declaration nodes, so the masking the old index needed is structural
/// here for free.
///
/// Resolution reproduces the observable semantics of the old index queries:
/// - innermost scope wins; within a scope the latest visible declaration shadows
/// - a name never resolves at its own declaration token
/// - member declarations resolve only while the query's innermost enclosing type
///   scope matches the member's owner (extensions of the same qualified name count)
/// - locals become visible after their declaring statement ends; guard bindings
///   cover the remainder of the enclosing block; conditional bindings cover the
///   attached body; parameters cover the whole function body
/// - enum cases are visible file-wide, gated by receiver type or global uniqueness
package final class SwiftScopeIndex {
    enum SymbolKind: Equatable {
        case type
        case function
        case variable
        case constant
        case macro
    }

    enum SymbolRole: Equatable {
        case file
        case member
        case local
        case genericParameter
    }

    struct SymbolKindSet: OptionSet {
        let rawValue: UInt8

        static let type = Self(rawValue: 1 << 0)
        static let function = Self(rawValue: 1 << 1)
        static let variable = Self(rawValue: 1 << 2)
        static let constant = Self(rawValue: 1 << 3)
        static let macro = Self(rawValue: 1 << 4)

        func contains(_ kind: SymbolKind) -> Bool {
            rawValue & Self.bit(for: kind) != 0
        }

        static func bit(for kind: SymbolKind) -> UInt8 {
            switch kind {
            case .type: return Self.type.rawValue
            case .function: return Self.function.rawValue
            case .variable: return Self.variable.rawValue
            case .constant: return Self.constant.rawValue
            case .macro: return Self.macro.rawValue
            }
        }
    }

    struct SymbolRoleSet: OptionSet {
        let rawValue: UInt8

        static let file = Self(rawValue: 1 << 0)
        static let member = Self(rawValue: 1 << 1)
        static let local = Self(rawValue: 1 << 2)
        static let genericParameter = Self(rawValue: 1 << 3)
        static let any: Self = [.file, .member, .local, .genericParameter]

        func contains(_ role: SymbolRole) -> Bool {
            rawValue & Self.bit(for: role) != 0
        }

        static func bit(for role: SymbolRole) -> UInt8 {
            switch role {
            case .file: return Self.file.rawValue
            case .member: return Self.member.rawValue
            case .local: return Self.local.rawValue
            case .genericParameter: return Self.genericParameter.rawValue
            }
        }
    }

    /// Query result: just enough for the overlay rules to pick a syntax ID.
    struct Resolution: Equatable {
        let kind: SymbolKind
        let role: SymbolRole
    }

    struct Declaration: Equatable {
        let name: String
        let kind: SymbolKind
        let role: SymbolRole
        /// The declared name token range (a name never resolves at its own token).
        var declarationRange: NSRange
        /// Absolute offset from which the declaration is visible inside its scope.
        var visibleFrom: Int
        /// Head identifier of the declared type annotation, for member-type lookups.
        let typeNameHead: String?
        /// Owner type qualified name for members and enum cases.
        let ownerQualifiedName: String?
    }

    final class Scope {
        enum Kind: Equatable {
            case file
            /// A type body (class/struct/enum/actor/protocol/precedencegroup).
            case type(qualifiedName: String)
            /// An extension body; members join the extended type's qualified name.
            case typeExtension(qualifiedName: String)
            /// Any executable brace scope: function/closure/accessor bodies, plain
            /// blocks, switch-case clauses, loop bodies.
            case block
        }

        var kind: Kind
        var range: NSRange
        var declarations: [Declaration] = []
        var children: [Scope] = []
        /// Lazy name → declaration indices for scopes whose declaration list is
        /// long enough that per-query linear scans dominate (the file root in
        /// generated/pasted code). Built on first query; stays valid because
        /// edits either shift declarations in place (names and order unchanged)
        /// or replace whole Scope instances.
        var declarationNameIndex: [String: [Int]]?

        init(kind: Kind, range: NSRange) {
            self.kind = kind
            self.range = range
        }

        static let nameIndexThreshold = 16

        func declarationIndices(named name: String) -> [Int]? {
            if declarationNameIndex == nil {
                var index = [String: [Int]](minimumCapacity: declarations.count)
                for (position, declaration) in declarations.enumerated() {
                    index[declaration.name, default: []].append(position)
                }
                declarationNameIndex = index
            }
            return declarationNameIndex?[name]
        }

        var typeQualifiedName: String? {
            switch kind {
            case .type(let name), .typeExtension(let name):
                return name
            case .file, .block:
                return nil
            }
        }
    }

    private(set) var root: Scope
    private(set) var sourceUTF16Length: Int
    private(set) var isCancelled = false
    /// Enum cases are visible file-wide with owner gating.
    private var enumCases: [String: [Declaration]] = [:]
    /// Member declarations keyed by owner qualified name, then declared name:
    /// members declared in any body/extension of a type resolve from every
    /// body/extension of that type. The second key level matters: resolution
    /// queries one name at a time, and duplicated type names (common in
    /// generated/pasted code) used to make every query walk every same-owner
    /// member.
    private var membersByOwner: [String: [String: [Declaration]]] = [:]
    /// Qualified names that have at least one extension scope in the file.
    private var extensionOwnerNames: Set<String> = []

    // MARK: - Construction

    package init?(rootNode: Node, source: NSString) {
        sourceUTF16Length = source.length
        root = Scope(kind: .file, range: NSRange(location: 0, length: source.length))
        var builder = Builder(source: source, index: self)
        guard builder.build(from: rootNode, into: root, ownerChain: []) else {
            isCancelled = true
            return nil
        }
        rebuildMemberMap()
    }

    private func rebuildMemberMap() {
        membersByOwner.removeAll(keepingCapacity: true)
        extensionOwnerNames.removeAll(keepingCapacity: true)
        func collect(_ scope: Scope) {
            if case .typeExtension(let name) = scope.kind {
                extensionOwnerNames.insert(name)
            }
            for declaration in scope.declarations where declaration.role == .member {
                guard let owner = declaration.ownerQualifiedName else { continue }
                membersByOwner[owner, default: [:]][declaration.name, default: []].append(declaration)
            }
            for child in scope.children {
                collect(child)
            }
        }
        collect(root)
    }




    /// Reusable resolution context: the scope path containing a position. The
    /// overlay generator resolves ~12 queries per identifier; computing the
    /// root descent once per token (and reusing it across tokens on the same
    /// line) removes the dominant cost of full passes.
    final class ResolutionContext {
        fileprivate var path: [Scope] = []

        fileprivate init() {}

        /// The innermost range for which the cached path stays valid: the
        /// innermost scope's range minus its children's spans is approximated
        /// by requiring containment in the innermost scope and re-descending
        /// when a child of it contains the position.
        fileprivate func isValid(for range: NSRange) -> Bool {
            guard let innermost = path.last else { return false }
            guard SwiftScopeIndex.range(innermost.range, contains: range) else { return false }
            // Mirror collectScopePath's candidate walk exactly (children are in
            // source order but enclosing siblings can share a start): binary-
            // search the last child starting at or before the range, then walk
            // back while siblings still reach past the range start. A linear
            // scan here was a per-query cost at file scope, where the root has
            // one child per toplevel declaration.
            let children = innermost.children
            var lower = 0
            var upper = children.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if children[middle].range.location <= range.location {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            var index = lower - 1
            while index >= 0 {
                let child = children[index]
                if SwiftScopeIndex.range(child.range, contains: range) {
                    return false
                }
                if child.range.upperBound <= range.location {
                    break
                }
                index -= 1
            }
            return true
        }
    }

    func makeResolutionContext() -> ResolutionContext {
        ResolutionContext()
    }

    fileprivate func path(for range: NSRange, context: ResolutionContext?) -> [Scope] {
        if let context {
            if context.isValid(for: range) {
                return context.path
            }
            var path: [Scope] = []
            collectScopePath(containing: range, from: root, into: &path)
            context.path = path
            return path
        }
        var path: [Scope] = []
        collectScopePath(containing: range, from: root, into: &path)
        return path
    }

    // MARK: - Queries (observable semantics preserved from the old index)

    func entry(
        named name: String,
        at range: NSRange,
        allowedKinds: SymbolKindSet,
        allowedRoles: SymbolRoleSet = .any,
        context: ResolutionContext? = nil
    ) -> Resolution? {
        let path = path(for: range, context: context)

        var crossedTypeBoundary = false
        for scope in path.reversed() {
            var best: Declaration?
            let scopeQualifiedName = scope.typeQualifiedName

            func consider(_ declaration: Declaration) {
                guard declaration.name == name,
                      allowedKinds.contains(declaration.kind),
                      allowedRoles.contains(declaration.role),
                      declaration.visibleFrom <= range.location || declaration.role == .member,
                      !Self.range(declaration.declarationRange, contains: range)
                else { return }
                if let current = best {
                    if declaration.declarationRange.location > current.declarationRange.location {
                        best = declaration
                    }
                } else {
                    best = declaration
                }
            }

            if scope.declarations.count > Scope.nameIndexThreshold {
                if let indices = scope.declarationIndices(named: name) {
                    for index in indices where scope.declarations[index].role != .member {
                        consider(scope.declarations[index])
                    }
                }
            } else {
                for declaration in scope.declarations where declaration.role != .member {
                    consider(declaration)
                }
            }
            // Members resolve via the owner map so declarations in sibling bodies and
            // extensions of the same type are visible — but only until the walk
            // crosses out of the innermost enclosing type.
            if !crossedTypeBoundary, let owner = scopeQualifiedName,
               let named = membersByOwner[owner]?[name] {
                for declaration in named {
                    consider(declaration)
                }
            }
            if let best {
                return Resolution(kind: best.kind, role: best.role)
            }
            if scopeQualifiedName != nil {
                crossedTypeBoundary = true
            }
        }
        return nil
    }

    func enumCaseEntry(
        named name: String,
        at range: NSRange,
        receiverTypeName: String?
    ) -> Resolution? {
        guard let candidates = enumCases[name], !candidates.isEmpty else {
            return nil
        }
        let visible = candidates.filter { !Self.range($0.declarationRange, contains: range) }
        guard !visible.isEmpty else { return nil }

        if let receiverTypeName {
            for candidate in visible {
                let lastComponent = candidate.ownerQualifiedName?
                    .split(separator: ".").last.map(String.init)
                if lastComponent == receiverTypeName {
                    return Resolution(kind: candidate.kind, role: candidate.role)
                }
            }
            return nil
        }

        let owners = Set(visible.compactMap(\.ownerQualifiedName))
        guard owners.count == 1 else { return nil }
        return visible.first.map { Resolution(kind: $0.kind, role: $0.role) }
    }

    func declaredTypeName(
        forValueNamed name: String,
        at range: NSRange,
        context: ResolutionContext? = nil
    ) -> String? {
        let path = path(for: range, context: context)

        var crossedTypeBoundary = false
        for scope in path.reversed() {
            var best: Declaration?
            let scopeQualifiedName = scope.typeQualifiedName

            func consider(_ declaration: Declaration) {
                guard declaration.name == name,
                      declaration.kind == .variable || declaration.kind == .constant,
                      declaration.typeNameHead != nil,
                      declaration.visibleFrom <= range.location || declaration.role == .member,
                      !Self.range(declaration.declarationRange, contains: range)
                else { return }
                if let current = best {
                    if declaration.declarationRange.location > current.declarationRange.location {
                        best = declaration
                    }
                } else {
                    best = declaration
                }
            }

            if scope.declarations.count > Scope.nameIndexThreshold {
                if let indices = scope.declarationIndices(named: name) {
                    for index in indices where scope.declarations[index].role != .member {
                        consider(scope.declarations[index])
                    }
                }
            } else {
                for declaration in scope.declarations where declaration.role != .member {
                    consider(declaration)
                }
            }
            if !crossedTypeBoundary, let owner = scopeQualifiedName,
               let named = membersByOwner[owner]?[name] {
                for declaration in named {
                    consider(declaration)
                }
            }
            if let best {
                return best.typeNameHead
            }
            if scopeQualifiedName != nil {
                crossedTypeBoundary = true
            }
        }
        return nil
    }

    func isGenericParameter(
        named name: String,
        at range: NSRange,
        context: ResolutionContext? = nil
    ) -> Bool {
        entry(named: name, at: range, allowedKinds: .type, allowedRoles: .genericParameter, context: context) != nil
    }

    // MARK: - Incremental maintenance

    /// Shifts every scope/declaration range through the mutation, IN PLACE (the
    /// index is session-owned). Returns false when a range partially overlaps the
    /// replaced region; the index is then stale and must be rebuilt — partial
    /// mutation of an abandoned index is harmless because the caller discards it.
    package func shiftInPlace(
        by mutation: SyntaxEditorTextChange.Replacement,
        sourceUTF16Length newLength: Int
    ) -> Bool {
        let delta = mutation.replacement.utf16.count - mutation.length
        let oldEnd = mutation.location + mutation.length

        // A range partially overlapping the replaced region cannot be shifted
        // exactly; the index is discarded and rebuilt. (Snapping such ranges to
        // the edit point and relying on the subtree rebuild is NOT sound: hosts
        // are rebuilt from their node's children, which cannot restore
        // declarations the parent's visit attaches — closure parameters — as
        // the same-length closure-parameter-edit regression test pins.)
        func shiftRange(_ range: NSRange) -> NSRange? {
            if range.upperBound <= mutation.location { return range }
            if range.location >= oldEnd {
                return NSRange(location: range.location + delta, length: range.length)
            }
            if range.location <= mutation.location, oldEnd <= range.upperBound {
                let length = range.length + delta
                guard length >= 0 else { return nil }
                return NSRange(location: range.location, length: length)
            }
            return nil
        }

        // Scopes whose range is fully before the edit need no work at all; the
        // recursion prunes via range checks so steady typing touches O(depth + right
        // siblings) scopes rather than every node.
        func shiftScope(_ scope: Scope) -> Bool {
            if scope.range.upperBound <= mutation.location {
                return true
            }
            guard let range = shiftRange(scope.range) else { return false }
            scope.range = range
            for index in scope.declarations.indices {
                let declaration = scope.declarations[index]
                if declaration.declarationRange.upperBound <= mutation.location,
                   declaration.visibleFrom <= mutation.location {
                    continue
                }
                guard let declarationRange = shiftRange(declaration.declarationRange) else { return false }
                scope.declarations[index].declarationRange = declarationRange
                scope.declarations[index].visibleFrom = declaration.visibleFrom <= mutation.location
                    ? declaration.visibleFrom
                    : max(mutation.location, declaration.visibleFrom + delta)
            }
            for child in scope.children where !shiftScope(child) {
                return false
            }
            return true
        }

        guard shiftScope(root) else { return false }
        root.range = NSRange(location: 0, length: newLength)

        func shiftDeclarationMap(_ map: inout [String: [Declaration]]) -> Bool {
            for (name, declarations) in map {
                var shifted = declarations
                var changed = false
                for index in shifted.indices {
                    let declaration = shifted[index]
                    if declaration.declarationRange.upperBound <= mutation.location,
                       declaration.visibleFrom <= mutation.location {
                        continue
                    }
                    guard let declarationRange = shiftRange(declaration.declarationRange) else { return false }
                    shifted[index].declarationRange = declarationRange
                    shifted[index].visibleFrom = declaration.visibleFrom <= mutation.location
                        ? declaration.visibleFrom
                        : max(mutation.location, declaration.visibleFrom + delta)
                    changed = true
                }
                if changed {
                    map[name] = shifted
                }
            }
            return true
        }

        func shiftNestedDeclarationMap(_ map: inout [String: [String: [Declaration]]]) -> Bool {
            for (owner, byName) in map {
                var shiftedByName = byName
                var ownerChanged = false
                for (name, declarations) in byName {
                    var shifted = declarations
                    var changed = false
                    for index in shifted.indices {
                        let declaration = shifted[index]
                        if declaration.declarationRange.upperBound <= mutation.location,
                           declaration.visibleFrom <= mutation.location {
                            continue
                        }
                        guard let declarationRange = shiftRange(declaration.declarationRange) else { return false }
                        shifted[index].declarationRange = declarationRange
                        shifted[index].visibleFrom = declaration.visibleFrom <= mutation.location
                            ? declaration.visibleFrom
                            : max(mutation.location, declaration.visibleFrom + delta)
                        changed = true
                    }
                    if changed {
                        shiftedByName[name] = shifted
                        ownerChanged = true
                    }
                }
                if ownerChanged {
                    map[owner] = shiftedByName
                }
            }
            return true
        }

        guard shiftDeclarationMap(&enumCases), shiftNestedDeclarationMap(&membersByOwner) else {
            return false
        }
        sourceUTF16Length = newLength
        return true
    }

    /// Rebuilds the innermost scope subtree containing `envelope` from the post-edit
    /// tree and splices it in, returning the declaration changes. Returns nil when
    /// the rebuild must escalate to a full rebuild (envelope reaches file scope or
    /// type-structure changes) or was cancelled.
    package struct SubtreeUpdate {
        /// Scope ranges that bound every position whose resolution may have changed.
        package let boundedTargets: [NSRange]
        /// Declaration names whose enum-case visibility changed. These names are
        /// file-wide, but only matching identifier tokens can change color.
        package let tokenTextTargetNames: Set<String>
        /// True when a changed declaration is visible file-wide (file scope, types,
        /// or unbounded members) and targeting must widen to the whole document.
        package let requiresFullPass: Bool
    }

    package func applySubtreeUpdate(
        envelope: NSRange,
        rootNode: Node,
        source: NSString
    ) -> SubtreeUpdate? {
        // An edit confined to a comment cannot add or remove declarations; the
        // shifted index is already exact. Without this, typing in a top-level
        // comment escalates the host search to the file root — a full index
        // rebuild per keystroke.
        if let covering = deepestNode(containing: envelope, from: rootNode),
           covering.nodeType == "comment" || covering.nodeType == "multiline_comment" {
            return SubtreeUpdate(
                boundedTargets: [],
                tokenTextTargetNames: [],
                requiresFullPass: false
            )
        }

        var path: [Scope] = []
        collectScopePath(containing: envelope, from: root, into: &path)

        // Host candidates from innermost to outermost: scopes strictly containing the
        // envelope whose shifted range still corresponds to a node in the post-edit
        // tree. Transient parse restructuring (unbalanced braces while typing) breaks
        // the innermost correspondence; escalation keeps the rebuild bounded by the
        // nearest stable ancestor. The file root is the terminal candidate: a full
        // tree-walk rebuild whose declaration diff still yields bounded targets.
        var candidates: [(scope: Scope, parent: Scope?)] = []
        if path.count > 1 {
            for index in stride(from: path.count - 1, through: 1, by: -1) {
                let scope = path[index]
                guard Self.range(scope.range, contains: envelope),
                      scope.range.location < envelope.location,
                      envelope.upperBound < scope.range.upperBound
                else { continue }
                candidates.append((scope, path[index - 1]))
            }
        }
        candidates.append((root, nil))

        for (host, parent) in candidates {
            let hostNode: Node
            if host === root {
                hostNode = rootNode
            } else if let node = nodeCovering(range: host.range, from: rootNode) {
                hostNode = node
            } else {
                continue
            }

            let ownerChain: [String]
            if host === root {
                ownerChain = []
            } else {
                var chain: [String] = []
                for scope in path {
                    if let name = scope.typeQualifiedName {
                        chain = name.split(separator: ".").map(String.init)
                    }
                    if scope === host { break }
                }
                ownerChain = chain
            }

            let replacement = Scope(kind: host.kind, range: host.range)
            var rebuiltEnumCases: [String: [Declaration]] = [:]
            var builder = Builder(source: source, index: nil, enumCaseSink: { declaration in
                rebuiltEnumCases[declaration.name, default: []].append(declaration)
            })
            guard builder.buildChildren(of: hostNode, into: replacement, ownerChain: ownerChain) else {
                return nil  // cancelled
            }

            var previousHostEnumCases: [String: [Declaration]] = [:]
            for (name, cases) in enumCases {
                let inHost = cases.filter { Self.range(host.range, contains: $0.declarationRange) }
                if !inHost.isEmpty {
                    previousHostEnumCases[name] = inHost
                }
            }
            let changedEnumCaseNames = Self.changedDeclarationNames(
                previousHostEnumCases,
                rebuiltEnumCases
            )

            // The declaration diff below consults the extension topology to
            // decide whether a changed member is visible beyond the host. Fold
            // the REBUILT subtree's extensions in first: an edit that adds a
            // type's FIRST extension makes its members visible from every
            // same-owner scope, which the pre-edit set cannot see. (The set
            // only ever grows; an owner whose last extension disappeared stays
            // conservatively wide.)
            func registerRebuiltExtensionOwners(_ scope: Scope) {
                if case .typeExtension(let name) = scope.kind {
                    extensionOwnerNames.insert(name)
                }
                for child in scope.children {
                    registerRebuiltExtensionOwners(child)
                }
            }
            registerRebuiltExtensionOwners(replacement)

            var boundedTargets: [NSRange] = []
            var requiresFullPass = false

            func declarationMap(
                _ scope: Scope,
                into map: inout [String: [Declaration]],
                scopeRanges: inout [String: [NSRange]]
            ) {
                for declaration in scope.declarations {
                    map[declaration.name, default: []].append(declaration)
                    scopeRanges[declaration.name, default: []].append(scope.range)
                }
                for child in scope.children {
                    declarationMap(child, into: &map, scopeRanges: &scopeRanges)
                }
            }

            var oldDeclarations: [String: [Declaration]] = [:]
            var oldScopes: [String: [NSRange]] = [:]
            declarationMap(host, into: &oldDeclarations, scopeRanges: &oldScopes)
            var newDeclarations: [String: [Declaration]] = [:]
            var newScopes: [String: [NSRange]] = [:]
            declarationMap(replacement, into: &newDeclarations, scopeRanges: &newScopes)

            if oldDeclarations != newDeclarations {
                var names = Set(oldDeclarations.keys)
                names.formUnion(newDeclarations.keys)
                for name in names {
                    let lhs = oldDeclarations[name] ?? []
                    let rhs = newDeclarations[name] ?? []
                    guard lhs != rhs else { continue }
                    for (index, declaration) in lhs.enumerated() where !rhs.contains(declaration) {
                        appendTarget(
                            for: declaration,
                            scopeRange: oldScopes[name]?[index] ?? host.range,
                            boundedTargets: &boundedTargets,
                            requiresFullPass: &requiresFullPass
                        )
                    }
                    for (index, declaration) in rhs.enumerated() where !lhs.contains(declaration) {
                        appendTarget(
                            for: declaration,
                            scopeRange: newScopes[name]?[index] ?? host.range,
                            boundedTargets: &boundedTargets,
                            requiresFullPass: &requiresFullPass
                        )
                    }
                }
            }

            // Splice the rebuilt subtree in.
            if host === root {
                root = replacement
            } else if let parent, let childIndex = parent.children.firstIndex(where: { $0 === host }) {
                parent.children[childIndex] = replacement
            } else {
                continue
            }

            // Splice the member map and extension set, touching only owners that have
            // declarations inside the host (global iteration per keystroke is what the
            // old design choked on).
            var touchedOwners = Set<String>()
            for declarations in oldDeclarations.values {
                for declaration in declarations where declaration.role == .member {
                    if let owner = declaration.ownerQualifiedName {
                        touchedOwners.insert(owner)
                    }
                }
            }
            func collectRebuiltMembers(_ scope: Scope, into map: inout [String: [String: [Declaration]]]) {
                if case .typeExtension(let name) = scope.kind {
                    extensionOwnerNames.insert(name)
                }
                for declaration in scope.declarations where declaration.role == .member {
                    guard let owner = declaration.ownerQualifiedName else { continue }
                    touchedOwners.insert(owner)
                    map[owner, default: [:]][declaration.name, default: []].append(declaration)
                }
                for child in scope.children {
                    collectRebuiltMembers(child, into: &map)
                }
            }
            var rebuiltMembers: [String: [String: [Declaration]]] = [:]
            collectRebuiltMembers(replacement, into: &rebuiltMembers)
            for owner in touchedOwners {
                var keptByName = membersByOwner[owner] ?? [:]
                var touchedNames = Set(keptByName.keys)
                if let rebuiltByName = rebuiltMembers[owner] {
                    touchedNames.formUnion(rebuiltByName.keys)
                }
                for name in touchedNames {
                    var kept = (keptByName[name] ?? []).filter {
                        !Self.range(host.range, contains: $0.declarationRange)
                    }
                    kept.append(contentsOf: rebuiltMembers[owner]?[name] ?? [])
                    if kept.isEmpty {
                        keptByName.removeValue(forKey: name)
                    } else {
                        keptByName[name] = kept
                    }
                }
                if keptByName.isEmpty {
                    membersByOwner.removeValue(forKey: owner)
                } else {
                    membersByOwner[owner] = keptByName
                }
            }

            // Splice enum cases, touching only names present on either side.
            var touchedCaseNames = Set(previousHostEnumCases.keys)
            touchedCaseNames.formUnion(rebuiltEnumCases.keys)
            for name in touchedCaseNames {
                var kept = (enumCases[name] ?? []).filter {
                    !Self.range(host.range, contains: $0.declarationRange)
                }
                kept.append(contentsOf: rebuiltEnumCases[name] ?? [])
                if kept.isEmpty {
                    enumCases.removeValue(forKey: name)
                } else {
                    enumCases[name] = kept
                }
            }

            return SubtreeUpdate(
                boundedTargets: boundedTargets,
                tokenTextTargetNames: changedEnumCaseNames,
                requiresFullPass: requiresFullPass
            )
        }

        return nil
    }

    private static func changedDeclarationNames(
        _ lhs: [String: [Declaration]],
        _ rhs: [String: [Declaration]]
    ) -> Set<String> {
        var names = Set(lhs.keys)
        names.formUnion(rhs.keys)
        return Set(names.filter { (lhs[$0] ?? []) != (rhs[$0] ?? []) })
    }

    private func appendTarget(
        for declaration: Declaration,
        scopeRange: NSRange,
        boundedTargets: inout [NSRange],
        requiresFullPass: inout Bool
    ) {
        switch declaration.role {
        case .local, .genericParameter:
            boundedTargets.append(scopeRange)
        case .member:
            // Member visibility = owner type body + its extensions. The owning scope
            // range bounds the body; extensions elsewhere require the wider pass only
            // when extensions of this type exist. Conservative: widen to full when
            // the owner has extensions outside the host (rare while typing).
            boundedTargets.append(scopeRange)
            if let owner = declaration.ownerQualifiedName, extensionOwnerNames.contains(owner) {
                // The member is also visible in extension bodies elsewhere; without
                // tracking their ranges here, widen conservatively.
                requiresFullPass = true
            }
        case .file:
            requiresFullPass = true
        }
        if declaration.kind == .type {
            // Type declarations influence type-context classification anywhere.
            requiresFullPass = true
        }
    }

    // MARK: - Helpers

    private func collectScopePath(containing range: NSRange, from scope: Scope, into path: inout [Scope]) {
        path.append(scope)
        var current = scope
        descend: while true {
            // Children are in source order; binary-search the last child starting at
            // or before the range, then check the few candidates that can contain it.
            let children = current.children
            var lower = 0
            var upper = children.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if children[middle].range.location <= range.location {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            var index = lower - 1
            while index >= 0 {
                let child = children[index]
                if Self.range(child.range, contains: range) {
                    path.append(child)
                    current = child
                    continue descend
                }
                // Earlier siblings start earlier; once one ends before the range no
                // earlier one can contain it — except enclosing ranges that share a
                // start location, so walk while they still reach past the range start.
                if child.range.upperBound <= range.location {
                    break
                }
                index -= 1
            }
            return
        }
    }

    private func nodeCovering(range: NSRange, from rootNode: Node) -> Node? {
        // Byte-cursor descent. The previous per-level `for index in
        // 0..<childCount` scan paired O(siblings) iterations with O(index)
        // `ts_node_child` calls, which dominated planned updates whenever the
        // covering chain passed through the file root (thousands of toplevel
        // siblings). Only the first child whose end extends past the range
        // start can contain the range (siblings are ordered and disjoint), so
        // the cursor jump plus a short same-position scan is equivalent.
        var current = rootNode
        let startByte = UInt32(clamping: range.location << 1)
        let cursor = rootNode.treeCursor
        while true {
            var descended = false
            if cursor.goToFirstChild(for: startByte) {
                while true {
                    guard let child = cursor.currentNode else { break }
                    if child.range == range {
                        return child
                    }
                    if Self.range(child.range, contains: range) {
                        current = child
                        descended = true
                        break
                    }
                    if child.range.location > range.location || !cursor.gotoNextSibling() {
                        break
                    }
                }
            }
            if !descended {
                return current.range == range ? current : nil
            }
        }
    }

    /// Deepest node whose range contains `range` (byte-cursor descent).
    private func deepestNode(containing range: NSRange, from rootNode: Node) -> Node? {
        guard Self.range(rootNode.range, contains: range) else { return nil }
        var current = rootNode
        let startByte = UInt32(clamping: range.location << 1)
        let cursor = rootNode.treeCursor
        while true {
            var descended = false
            if cursor.goToFirstChild(for: startByte) {
                while true {
                    guard let child = cursor.currentNode else { break }
                    if Self.range(child.range, contains: range) {
                        current = child
                        descended = true
                        break
                    }
                    if child.range.location > range.location || !cursor.gotoNextSibling() {
                        break
                    }
                }
            }
            if !descended {
                return current
            }
        }
    }

    static func range(_ outer: NSRange, contains inner: NSRange) -> Bool {
        inner.location >= outer.location && inner.upperBound <= outer.upperBound
    }

    // MARK: - Builder

    fileprivate struct Builder {
        let source: NSString
        weak var index: SwiftScopeIndex?
        var enumCaseSink: ((Declaration) -> Void)?
        private var nodeBudget = 0

        init(source: NSString, index: SwiftScopeIndex?, enumCaseSink: ((Declaration) -> Void)? = nil) {
            self.source = source
            self.index = index
            self.enumCaseSink = enumCaseSink
        }

        mutating func build(from rootNode: Node, into scope: Scope, ownerChain: [String]) -> Bool {
            buildChildren(of: rootNode, into: scope, ownerChain: ownerChain)
        }

        /// Walks `node`'s children, attaching scopes/declarations to `scope`.
        /// Returns false on task cancellation.
        mutating func buildChildren(of node: Node, into scope: Scope, ownerChain: [String]) -> Bool {
            for childIndex in 0..<node.childCount {
                nodeBudget += 1
                if nodeBudget & 0x3FF == 0, Task.isCancelled {
                    return false
                }
                guard let child = node.child(at: childIndex) else { continue }
                guard visit(child, in: scope, ownerChain: ownerChain) else { return false }
            }
            return true
        }

        private mutating func visit(_ node: Node, in scope: Scope, ownerChain: [String]) -> Bool {
            switch node.nodeType {
            case "class_declaration":
                return visitClassLike(node, in: scope, ownerChain: ownerChain)
            case "protocol_declaration":
                return visitNamedType(node, kindNode: nil, kindString: "protocol", in: scope, ownerChain: ownerChain)
            case "function_declaration", "protocol_function_declaration":
                return visitFunction(node, in: scope, ownerChain: ownerChain)
            case "init_declaration", "deinit_declaration", "subscript_declaration":
                return visitFunctionScope(node, in: scope, ownerChain: ownerChain)
            case "property_declaration", "protocol_property_declaration":
                return visitProperty(node, in: scope, ownerChain: ownerChain)
            case "typealias_declaration", "associatedtype_declaration":
                visitTypeAlias(node, in: scope, ownerChain: ownerChain)
                return buildChildren(of: node, into: scope, ownerChain: ownerChain)
            case "macro_declaration":
                visitMacro(node, in: scope, ownerChain: ownerChain)
                return buildChildren(of: node, into: scope, ownerChain: ownerChain)
            case "operator_declaration":
                visitOperator(node, in: scope)
                return true
            case "precedence_group_declaration":
                visitPrecedenceGroup(node, in: scope, ownerChain: ownerChain)
                return true
            case "enum_entry":
                visitEnumEntry(node, in: scope, ownerChain: ownerChain)
                return buildChildren(of: node, into: scope, ownerChain: ownerChain)
            case "lambda_literal":
                return visitClosure(node, in: scope, ownerChain: ownerChain)
            case "for_statement":
                return visitFor(node, in: scope, ownerChain: ownerChain)
            case "catch_block":
                return visitCatch(node, in: scope, ownerChain: ownerChain)
            case "guard_statement":
                return visitGuard(node, in: scope, ownerChain: ownerChain)
            case "if_statement", "while_statement":
                return visitConditional(node, in: scope, ownerChain: ownerChain)
            case "switch_entry":
                return visitSwitchEntry(node, in: scope, ownerChain: ownerChain)
            case "statements":
                // Every brace-delimited statement block is a local scope (the old
                // index scoped locals to every brace pair via braceRangeIndex).
                let blockScope = Scope(kind: .block, range: node.range)
                scope.children.append(blockScope)
                return buildChildren(of: node, into: blockScope, ownerChain: ownerChain)
            default:
                return buildChildren(of: node, into: scope, ownerChain: ownerChain)
            }
        }

        // MARK: Node handlers

        private mutating func visitClassLike(_ node: Node, in scope: Scope, ownerChain: [String]) -> Bool {
            guard let kindRange = node.child(byFieldName: "declaration_kind")?.range,
                  let nameNode = node.child(byFieldName: "name")
            else {
                return buildChildren(of: node, into: scope, ownerChain: ownerChain)
            }
            let kindString = source.nativeSubstring(with: kindRange)

            if kindString == "extension" {
                let qualifiedName = source.nativeSubstring(with: nameNode.range)
                    .replacingOccurrences(of: " ", with: "")
                guard let bodyNode = node.child(byFieldName: "body") else { return true }
                let extensionScope = Scope(kind: .typeExtension(qualifiedName: qualifiedName), range: bodyNode.range)
                scope.children.append(extensionScope)
                let chain = qualifiedName.split(separator: ".").map(String.init)
                return buildChildren(of: bodyNode, into: extensionScope, ownerChain: chain)
            }

            return visitNamedType(node, kindNode: nameNode, kindString: kindString, in: scope, ownerChain: ownerChain)
        }

        private mutating func visitNamedType(
            _ node: Node,
            kindNode: Node?,
            kindString: String,
            in scope: Scope,
            ownerChain: [String]
        ) -> Bool {
            guard let nameNode = kindNode ?? node.child(byFieldName: "name") else {
                return buildChildren(of: node, into: scope, ownerChain: ownerChain)
            }
            let name = source.nativeSubstring(with: nameNode.range)
            let qualifiedName = (ownerChain + [name]).joined(separator: ".")

            scope.declarations.append(Declaration(
                name: name,
                kind: .type,
                role: role(in: scope),
                declarationRange: nameNode.range,
                visibleFrom: scope.range.location,
                typeNameHead: nil,
                ownerQualifiedName: scope.typeQualifiedName
            ))

            let genericScope = visitGenericParameters(
                of: node,
                in: scope,
                bodyNode: node.child(byFieldName: "body")
            )

            guard let bodyNode = node.child(byFieldName: "body") else {
                return true
            }
            let typeScope = Scope(kind: .type(qualifiedName: qualifiedName), range: bodyNode.range)
            (genericScope ?? scope).children.append(typeScope)
            return buildChildren(of: bodyNode, into: typeScope, ownerChain: ownerChain + [name])
        }

        private mutating func visitFunction(_ node: Node, in scope: Scope, ownerChain: [String]) -> Bool {
            guard let nameNode = node.child(byFieldName: "name") else {
                return buildChildren(of: node, into: scope, ownerChain: ownerChain)
            }
            scope.declarations.append(Declaration(
                name: source.nativeSubstring(with: nameNode.range),
                kind: .function,
                role: role(in: scope),
                declarationRange: nameNode.range,
                visibleFrom: scope.range.location,
                typeNameHead: nil,
                ownerQualifiedName: scope.typeQualifiedName
            ))
            return visitFunctionScope(node, in: scope, ownerChain: ownerChain)
        }

        private mutating func visitFunctionScope(_ node: Node, in scope: Scope, ownerChain: [String]) -> Bool {
            let bodyNode = node.child(byFieldName: "body")
                ?? directChild(of: node, nodeType: "computed_property")
            guard let bodyNode else {
                return buildChildren(of: node, into: scope, ownerChain: ownerChain)
            }

            let genericScope = visitGenericParameters(of: node, in: scope, bodyNode: bodyNode)
            let bodyScope = Scope(kind: .block, range: bodyNode.range)
            (genericScope ?? scope).children.append(bodyScope)
            collectParameters(of: node, into: bodyScope)
            return buildChildren(of: bodyNode, into: bodyScope, ownerChain: ownerChain)
        }

        private mutating func visitProperty(_ node: Node, in scope: Scope, ownerChain: [String]) -> Bool {
            let typeHead = typeAnnotationHead(of: node)
            let role = role(in: scope)

            // Comma positions split a multi-binding declaration into segments:
            // `let value = 1, copy = value` makes `value` visible to the second
            // binding's initializer (legacy per-segment scoping).
            var commaLocations: [Int] = []
            for childIndex in 0..<node.childCount {
                guard let child = node.child(at: childIndex), child.nodeType == "," else { continue }
                commaLocations.append(child.range.location)
            }

            for nameNode in patternIdentifiers(of: node) {
                let segmentEnd = commaLocations.first { $0 >= nameNode.range.upperBound }
                    ?? node.range.upperBound
                scope.declarations.append(Declaration(
                    name: source.nativeSubstring(with: nameNode.range),
                    kind: .variable,
                    role: role,
                    declarationRange: nameNode.range,
                    visibleFrom: role == .local ? segmentEnd : scope.range.location,
                    typeNameHead: typeHead,
                    ownerQualifiedName: scope.typeQualifiedName
                ))
            }
            // Accessor bodies / initializer closures nest inside.
            return buildChildren(of: node, into: scope, ownerChain: ownerChain)
        }

        private mutating func visitTypeAlias(_ node: Node, in scope: Scope, ownerChain: [String]) {
            guard let nameNode = node.child(byFieldName: "name") else { return }
            scope.declarations.append(Declaration(
                name: source.nativeSubstring(with: nameNode.range),
                kind: .type,
                role: role(in: scope),
                declarationRange: nameNode.range,
                visibleFrom: scope.range.location,
                typeNameHead: nil,
                ownerQualifiedName: scope.typeQualifiedName
            ))
        }

        private mutating func visitMacro(_ node: Node, in scope: Scope, ownerChain: [String]) {
            guard let nameNode = directChild(of: node, nodeType: "simple_identifier") else { return }
            scope.declarations.append(Declaration(
                name: source.nativeSubstring(with: nameNode.range),
                kind: .macro,
                role: .file,
                declarationRange: nameNode.range,
                visibleFrom: 0,
                typeNameHead: nil,
                ownerQualifiedName: nil
            ))
        }

        private mutating func visitOperator(_ node: Node, in scope: Scope) {
            guard let nameNode = directChild(of: node, nodeType: "custom_operator")
                ?? directChild(of: node, nodeType: "simple_identifier") else { return }
            scope.declarations.append(Declaration(
                name: source.nativeSubstring(with: nameNode.range),
                kind: .function,
                role: .file,
                declarationRange: nameNode.range,
                visibleFrom: 0,
                typeNameHead: nil,
                ownerQualifiedName: nil
            ))
        }

        private mutating func visitPrecedenceGroup(_ node: Node, in scope: Scope, ownerChain: [String]) {
            guard let nameNode = directChild(of: node, nodeType: "simple_identifier") else { return }
            let name = source.nativeSubstring(with: nameNode.range)
            scope.declarations.append(Declaration(
                name: name,
                kind: .type,
                role: role(in: scope),
                declarationRange: nameNode.range,
                visibleFrom: scope.range.location,
                typeNameHead: nil,
                ownerQualifiedName: scope.typeQualifiedName
            ))
        }

        private mutating func visitEnumEntry(_ node: Node, in scope: Scope, ownerChain: [String]) {
            let owner = ownerChain.joined(separator: ".")
            var previousType: String?
            for childIndex in 0..<node.childCount {
                guard let child = node.child(at: childIndex) else { continue }
                let type = child.nodeType ?? ""
                defer { previousType = type }
                guard type == "simple_identifier",
                      previousType == "case" || previousType == ","
                else { continue }
                let declaration = Declaration(
                    name: source.nativeSubstring(with: child.range),
                    kind: .constant,
                    role: .member,
                    declarationRange: child.range,
                    visibleFrom: 0,
                    typeNameHead: nil,
                    ownerQualifiedName: owner.isEmpty ? nil : owner
                )
                if let sink = enumCaseSink {
                    sink(declaration)
                } else {
                    index?.enumCases[declaration.name, default: []].append(declaration)
                }
            }
        }

        private mutating func visitClosure(_ node: Node, in scope: Scope, ownerChain: [String]) -> Bool {
            let closureScope = Scope(kind: .block, range: node.range)
            scope.children.append(closureScope)
            collectClosureParameters(of: node, into: closureScope)
            return buildChildren(of: node, into: closureScope, ownerChain: ownerChain)
        }

        private mutating func visitFor(_ node: Node, in scope: Scope, ownerChain: [String]) -> Bool {
            let bodyScope = Scope(kind: .block, range: node.range)
            scope.children.append(bodyScope)
            collectConditionBindings(of: node, into: bodyScope, guardStyle: false)
            return buildChildren(of: node, into: bodyScope, ownerChain: ownerChain)
        }

        private mutating func visitCatch(_ node: Node, in scope: Scope, ownerChain: [String]) -> Bool {
            let catchScope = Scope(kind: .block, range: node.range)
            scope.children.append(catchScope)
            collectConditionBindings(of: node, into: catchScope, guardStyle: false)
            return buildChildren(of: node, into: catchScope, ownerChain: ownerChain)
        }

        private mutating func visitGuard(_ node: Node, in scope: Scope, ownerChain: [String]) -> Bool {
            // Guard bindings outlive the statement: trailing condition clauses and the
            // remainder of the enclosing scope see them.
            collectConditionBindings(of: node, into: scope, guardStyle: true)
            return buildChildren(of: node, into: scope, ownerChain: ownerChain)
        }

        private mutating func visitConditional(_ node: Node, in scope: Scope, ownerChain: [String]) -> Bool {
            // if/while bodies are flat children of the statement node; bindings become
            // visible per condition clause (a clause's own initializer precedes them).
            let bodyScope = Scope(kind: .block, range: node.range)
            scope.children.append(bodyScope)
            collectConditionBindings(of: node, into: bodyScope, guardStyle: false)
            return buildChildren(of: node, into: bodyScope, ownerChain: ownerChain)
        }

        private mutating func visitSwitchEntry(_ node: Node, in scope: Scope, ownerChain: [String]) -> Bool {
            let caseScope = Scope(kind: .block, range: node.range)
            scope.children.append(caseScope)
            collectConditionBindings(of: node, into: caseScope, guardStyle: false)
            return buildChildren(of: node, into: caseScope, ownerChain: ownerChain)
        }

        /// Collects bound names from a statement's flat condition region. The grammar
        /// lays conditions out as direct children: `value_binding_pattern` is just the
        /// `let`/`var` keyword; bound names follow as bare identifiers (immediately
        /// after the keyword), as `pattern`/`tuple_pattern` wrappers, or inside case
        /// patterns where a leading `.name` is the CASE name, not a binding.
        /// Bindings flush per clause: at `,` the clause's names become visible from
        /// the comma (later clauses and the body see them; the clause's own
        /// initializer does not); at the body introducer (`{`, `:`, `else`) the final
        /// clause flushes with that boundary.
        private mutating func collectConditionBindings(
            of node: Node,
            into scope: Scope,
            guardStyle: Bool
        ) {
            var pending: [Node] = []
            var previousType: String?

            func flush(at boundary: Int) {
                for nameNode in pending {
                    let name = source.nativeSubstring(with: nameNode.range)
                    guard name != "_" else { continue }
                    scope.declarations.append(Declaration(
                        name: name,
                        kind: .variable,
                        role: .local,
                        declarationRange: nameNode.range,
                        visibleFrom: boundary,
                        typeNameHead: nil,
                        ownerQualifiedName: nil
                    ))
                }
                pending.removeAll(keepingCapacity: true)
            }

            for childIndex in 0..<node.childCount {
                guard let child = node.child(at: childIndex) else { continue }
                let type = child.nodeType ?? ""
                switch type {
                case "value_binding_pattern":
                    previousType = type
                case "simple_identifier":
                    if previousType == "value_binding_pattern" {
                        pending.append(child)
                    }
                    previousType = type
                case "pattern", "tuple_pattern":
                    collectIdentifiers(of: child, into: &pending)
                    previousType = type
                case ",":
                    flush(at: child.range.location)
                    previousType = type
                case "{", ":", "else", "statements":
                    flush(at: child.range.location)
                    // Body region reached; stop scanning conditions.
                    return
                default:
                    previousType = type
                }
            }
            flush(at: node.range.upperBound)
        }

        // MARK: extraction helpers

        private func role(in scope: Scope) -> SymbolRole {
            switch scope.kind {
            case .file: return .file
            case .type, .typeExtension: return .member
            case .block: return .local
            }
        }

        @discardableResult
        private mutating func visitGenericParameters(of node: Node, in scope: Scope, bodyNode: Node?) -> Scope? {
            guard let parameterList = firstDescendant(of: node, nodeType: "type_parameters", maxDepth: 2) else {
                return nil
            }
            let scopeRange = bodyNode.map {
                NSRange(
                    location: parameterList.range.location,
                    length: $0.range.upperBound - parameterList.range.location
                )
            } ?? node.range
            let genericScope = Scope(kind: .block, range: scopeRange)
            scope.children.append(genericScope)
            for childIndex in 0..<parameterList.childCount {
                guard let parameter = parameterList.child(at: childIndex),
                      parameter.nodeType == "type_parameter" else { continue }
                guard let nameNode = directChild(of: parameter, nodeType: "type_identifier") else { continue }
                genericScope.declarations.append(Declaration(
                    name: source.nativeSubstring(with: nameNode.range),
                    kind: .type,
                    role: .genericParameter,
                    declarationRange: nameNode.range,
                    visibleFrom: scopeRange.location,
                    typeNameHead: nil,
                    ownerQualifiedName: nil
                ))
            }
            return genericScope
        }

        private mutating func collectParameters(of node: Node, into bodyScope: Scope) {
            for childIndex in 0..<node.childCount {
                guard let child = node.child(at: childIndex), child.nodeType == "parameter" else { continue }
                // Internal name = the second simple_identifier if present, else the first.
                var identifiers: [Node] = []
                for parameterChildIndex in 0..<child.childCount {
                    guard let parameterChild = child.child(at: parameterChildIndex),
                          parameterChild.nodeType == "simple_identifier" else { continue }
                    identifiers.append(parameterChild)
                }
                guard let nameNode = identifiers.count > 1 ? identifiers[1] : identifiers.first else { continue }
                let name = source.nativeSubstring(with: nameNode.range)
                guard name != "_" else { continue }
                bodyScope.declarations.append(Declaration(
                    name: name,
                    kind: .variable,
                    role: .local,
                    declarationRange: nameNode.range,
                    visibleFrom: bodyScope.range.location,
                    typeNameHead: typeAnnotationHead(of: child),
                    ownerQualifiedName: nil
                ))
            }
        }

        private mutating func collectClosureParameters(of node: Node, into closureScope: Scope) {
            guard let captureOrParams = firstDescendant(of: node, nodeType: "lambda_function_type", maxDepth: 2)
                ?? firstDescendant(of: node, nodeType: "lambda_function_type_parameters", maxDepth: 3)
            else { return }
            func collect(_ node: Node) {
                for childIndex in 0..<node.childCount {
                    guard let child = node.child(at: childIndex) else { continue }
                    if child.nodeType == "lambda_parameter" || child.nodeType == "simple_identifier" {
                        let nameNode = child.nodeType == "simple_identifier"
                            ? child
                            : directChild(of: child, nodeType: "simple_identifier")
                        if let nameNode {
                            let name = source.nativeSubstring(with: nameNode.range)
                            if name != "_" {
                                closureScope.declarations.append(Declaration(
                                    name: name,
                                    kind: .variable,
                                    role: .local,
                                    declarationRange: nameNode.range,
                                    visibleFrom: closureScope.range.location,
                                    typeNameHead: nil,
                                    ownerQualifiedName: nil
                                ))
                            }
                        }
                    } else {
                        collect(child)
                    }
                }
            }
            collect(captureOrParams)
        }

        private mutating func appendPatternBindings(from node: Node, into scope: Scope, visibleFrom: Int) {
            if node.nodeType == "simple_identifier" {
                let name = source.nativeSubstring(with: node.range)
                guard name != "_" else { return }
                scope.declarations.append(Declaration(
                    name: name,
                    kind: .variable,
                    role: .local,
                    declarationRange: node.range,
                    visibleFrom: visibleFrom,
                    typeNameHead: nil,
                    ownerQualifiedName: nil
                ))
                return
            }
            for childIndex in 0..<node.childCount {
                guard let child = node.child(at: childIndex) else { continue }
                // Do not descend into expressions (e.g. `case .foo(let x)` keeps
                // only bound identifiers; member references are not bindings).
                if child.nodeType == "simple_identifier" || child.nodeType == "pattern"
                    || child.nodeType == "value_binding_pattern" || child.nodeType == "tuple_pattern" {
                    appendPatternBindings(from: child, into: scope, visibleFrom: visibleFrom)
                }
            }
        }

        private func conditionBindingPatterns(of node: Node) -> [Node] {
            var results: [Node] = []
            for childIndex in 0..<node.childCount {
                guard let child = node.child(at: childIndex) else { continue }
                if child.nodeType == "value_binding_pattern" {
                    results.append(child)
                } else if child.nodeType != "statements", child.range.length > 0 {
                    results.append(contentsOf: conditionBindingPatterns(of: child))
                }
            }
            return results
        }

        private func patternIdentifiers(of propertyNode: Node) -> [Node] {
            var results: [Node] = []
            for childIndex in 0..<propertyNode.childCount {
                guard let child = propertyNode.child(at: childIndex), child.nodeType == "pattern" else { continue }
                collectIdentifiers(of: child, into: &results)
            }
            return results
        }

        private func collectIdentifiers(of node: Node, into results: inout [Node]) {
            if node.nodeType == "simple_identifier" {
                results.append(node)
                return
            }
            for childIndex in 0..<node.childCount {
                guard let child = node.child(at: childIndex) else { continue }
                collectIdentifiers(of: child, into: &results)
            }
        }

        private func typeAnnotationHead(of node: Node) -> String? {
            guard let annotation = firstDescendant(of: node, nodeType: "type_annotation", maxDepth: 2)
                ?? node.child(byFieldName: "type")
            else { return nil }
            guard let identifier = firstDescendant(of: annotation, nodeType: "type_identifier", maxDepth: 4) else {
                return nil
            }
            return source.nativeSubstring(with: identifier.range)
        }

        private func directChild(of node: Node, nodeType: String) -> Node? {
            for childIndex in 0..<node.childCount {
                guard let child = node.child(at: childIndex) else { continue }
                if child.nodeType == nodeType {
                    return child
                }
            }
            return nil
        }

        private func firstDescendant(of node: Node, nodeType: String, maxDepth: Int = .max) -> Node? {
            guard maxDepth > 0 else { return nil }
            for childIndex in 0..<node.childCount {
                guard let child = node.child(at: childIndex) else { continue }
                if child.nodeType == nodeType {
                    return child
                }
                if let found = firstDescendant(of: child, nodeType: nodeType, maxDepth: maxDepth - 1) {
                    return found
                }
            }
            return nil
        }
    }
}
