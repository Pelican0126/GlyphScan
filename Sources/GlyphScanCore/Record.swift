import Foundation

/// Identifier for a record. The library never interprets it — the consumer
/// maps it back to its own storage.
public typealias RecordID = Int64

/// Role of a field within a record. `primary` carries most of the record's
/// identity (a question stem, an invoice line description); `secondary` is
/// supporting detail (answer options, a SKU). Generalises the old
/// "stem vs options" split so the engine is domain-agnostic.
public enum FieldRole: Sendable, Equatable {
    case primary
    case secondary
}

public struct MatchField: Sendable, Equatable {
    public let text: String
    public let role: FieldRole

    public init(text: String, role: FieldRole) {
        self.text = text
        self.role = role
    }
}

/// A short record the scanner can match against. Implement this on your own
/// type, or use `SimpleRecord`.
public protocol MatchableRecord {
    var id: RecordID { get }
    var fields: [MatchField] { get }
}

public extension MatchableRecord {
    /// Primary fields joined with a space — the "stem" equivalent.
    var primaryText: String {
        fields.lazy.filter { $0.role == .primary }.map(\.text).joined(separator: " ")
    }

    /// Secondary fields joined with a space — the "options" equivalent.
    var secondaryText: String {
        fields.lazy.filter { $0.role == .secondary }.map(\.text).joined(separator: " ")
    }
}

/// A ready-made value-type record for in-memory corpora, tests, and simple
/// consumers.
public struct SimpleRecord: MatchableRecord, Sendable, Equatable {
    public let id: RecordID
    public let fields: [MatchField]

    public init(id: RecordID, fields: [MatchField]) {
        self.id = id
        self.fields = fields
    }

    /// Convenience: one primary "stem" plus zero or more secondary options.
    public init(id: RecordID, stem: String, options: [String] = []) {
        var fields: [MatchField] = [MatchField(text: stem, role: .primary)]
        fields += options.map { MatchField(text: $0, role: .secondary) }
        self.init(id: id, fields: fields)
    }
}
