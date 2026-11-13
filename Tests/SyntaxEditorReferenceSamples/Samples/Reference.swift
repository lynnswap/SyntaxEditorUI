import Foundation
import Observation

// MARK: - Reference highlighting surface

/// Renders a compact reference model.
///
/// - Parameters:
///   - input: A value loaded from https://example.invalid/reference.
/// - Returns: Rows that exercise documentation markup and links.
/// - Warning: This fixture is parsed for highlighting only.
@attached(member, names: named(CodingKeys))
@attached(extension, conformances: Codable)
macro AutoCodable() = #externalMacro(module: "ReferenceMacros", type: "AutoCodableMacro")

@freestanding(expression)
macro localized(_ key: StaticString) -> String = #externalMacro(module: "ReferenceMacros", type: "LocalizedMacro")

@propertyWrapper
struct Clamped<Value: Comparable> {
    var wrappedValue: Value {
        didSet { wrappedValue = min(max(wrappedValue, range.lowerBound), range.upperBound) }
    }
    let range: ClosedRange<Value>

    init(wrappedValue: Value, _ range: ClosedRange<Value>) {
        self.range = range
        self.wrappedValue = min(max(wrappedValue, range.lowerBound), range.upperBound)
    }
}

@resultBuilder
enum RowBuilder {
    static func buildBlock(_ rows: String...) -> [String] { rows }
}

protocol ReferenceRenderable {
    associatedtype Output

    func render() async throws -> Output
}

precedencegroup ReferencePrecedence {
    associativity: left
    higherThan: AdditionPrecedence
    assignment: false
}

infix operator <+>: ReferencePrecedence

package typealias ReferenceID = UUID
fileprivate let globalLimit = 100

open class OpenReferenceBase {}

@AutoCodable
@Observable
@MainActor
final class ReferenceStore: OpenReferenceBase, @unchecked Sendable, ReferenceRenderable {
    enum State: String, CaseIterable {
        case idle
        case loading
        case ready
        case failed
    }

    struct Item<ID: Hashable>: Identifiable {
        let id: ID
        var title: String
        var metadata: [String: String]
    }

    @Clamped(0...globalLimit) var progress = 42
    var state: State = .ready
    private(set) var items: [Item<ReferenceID>] = []
    static let placeholder = Item(id: UUID(), title: "Untitled", metadata: [:])

    subscript(item id: ReferenceID) -> Item<ReferenceID>? {
        items.first { $0.id == id }
    }
    isolated deinit {
    }

    func render() async throws -> [String] {
        try await load().map(\.title)
    }

    func load() async throws -> some Sequence<Item<ReferenceID>> {
        defer { state = .ready }
        state = .loading

        #if os(iOS)
        let platform = "iOS"
        #elseif os(macOS)
        let platform = "macOS"
        #else
        let platform = "other"
        #endif

        #if swift(>=5.9) && compiler(>=6.0)
        let toolchain = "modern"
        #else
        let toolchain = "legacy"
        #endif

        #if canImport(UIKit, _version: 17.0)
        let runtime = "UIKit"
        #else
        let runtime = "portable"
        #endif

        if #available(macOS 15.0, iOS 18.0, *) {
            let title = #localized("reference.title")
            let pattern = #/item-(?<number>\d+)-(?<kind>[A-Z]+)/#
            let matched = try pattern.firstMatch(in: "item-42-OK")?.output.number != nil
            items = [
                Item(
                    id: UUID(),
                    title: "\(title) \(platform) \(toolchain) \(runtime) \(matched)",
                    metadata: ["scope": "preview"]
                ),
            ]
        } else {
            items = []
        }

        return items
    }

    func inspect(_ value: borrowing ReferenceStore) -> any ReferenceRenderable {
        value
    }

    func replace(with value: consuming ReferenceStore) {
        self.items = value.items
    }
}

actor ReferenceCache<Key: Hashable, Value> {
    private var storage: [Key: Value] = [:]

    func value(for key: Key, create: @Sendable () async throws -> Value) async rethrows -> Value {
        if let cached = storage[key] {
            return cached
        }
        let value = try await create()
        storage[key] = value
        return value
    }
}

extension ReferenceStore {
    @MainActor
    func rows(@RowBuilder content: () -> [String]) -> [String] {
        content().map { "\($0): \(state.rawValue)" }
    }
}

func <+> (lhs: ReferenceStore.State, rhs: ReferenceStore.State) -> ReferenceStore.State {
    switch (lhs, rhs) {
    case (.failed, _), (_, .failed):
        return .failed
    case (.ready, .ready):
        return .ready
    default:
        return .loading
    }
}

#sourceLocation(file: "Reference.swift", line: 200)
let sourceLocationCheck: Any? = nil
#sourceLocation()
