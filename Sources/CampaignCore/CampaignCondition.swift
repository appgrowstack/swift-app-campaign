import Foundation

/// A condition: `all`, `any`, or one value compared with one operator. Nested at most 3 groups deep.
indirect enum CampaignCondition: Sendable, Equatable {
    case all([CampaignCondition])
    case any([CampaignCondition])
    case leaf(Subject, Operator)

    enum Subject: Sendable, Equatable {
        case prop(String)
        case fact(String)
    }

    enum Operator: Sendable, Equatable {
        case eq(CampaignValue)
        case ne(CampaignValue)
        case `in`([CampaignValue])
        case notIn([CampaignValue])
        case gte(Double)
        case lte(Double)
        case exists(Bool)
    }

    static let maxDepth = 3
    static let operatorNames: Set<String> = ["eq", "ne", "in", "not_in", "gte", "lte", "exists"]

    enum SubjectKind { case prop, fact }

    /// Reads a condition, or throws the reason the campaign cannot be used.
    static func parse(_ json: JSONValue, subject kind: SubjectKind, registry: CampaignRegistry,
                      depth: Int = 0) throws(CampaignRejection) -> CampaignCondition {
        guard let object = json.object, !object.isEmpty else { throw .invalid }
        if object.count == 1, let (key, value) = object.first, key == "all" || key == "any" {
            guard depth < maxDepth, let items = value.array, !items.isEmpty else { throw .invalid }
            var children: [CampaignCondition] = []
            for item in items {
                children.append(try parse(item, subject: kind, registry: registry, depth: depth + 1))
            }
            return key == "all" ? .all(children) : .any(children)
        }
        let subjectKey = kind == .prop ? "prop" : "fact"
        guard object.count == 2, let name = object[subjectKey]?.string,
              let (opName, opValue) = object.first(where: { $0.key != subjectKey }) else { throw .invalid }
        guard operatorNames.contains(opName) else { throw .init(.unknownOperator) }
        let subject: Subject
        if kind == .fact {
            guard registry.fact(name) != nil else { throw .init(.unknownFact) }
            subject = .fact(name)
        } else {
            subject = .prop(name)
        }
        return .leaf(subject, try parseOperator(opName, opValue))
    }

    private static func parseOperator(_ name: String, _ value: JSONValue) throws(CampaignRejection) -> Operator {
        switch name {
        case "eq", "ne":
            guard let scalar = value.scalar else { throw .invalid }
            return name == "eq" ? .eq(scalar) : .ne(scalar)
        case "in", "not_in":
            guard let items = value.array, (1...50).contains(items.count) else { throw .invalid }
            let scalars = items.compactMap(\.scalar)
            guard scalars.count == items.count, Set(scalars.map(\.kind)).count == 1 else { throw .invalid }
            return name == "in" ? .in(scalars) : .notIn(scalars)
        case "gte", "lte":
            guard let number = value.number else { throw .invalid }
            return name == "gte" ? .gte(number) : .lte(number)
        default:
            guard let flag = value.bool else { throw .invalid }
            return .exists(flag)
        }
    }

    var facts: [String] {
        switch self {
        case .all(let children), .any(let children): children.flatMap(\.facts)
        case .leaf(.fact(let name), _): [name]
        case .leaf: []
        }
    }
}

/// The reason a campaign was rejected while reading it.
struct CampaignRejection: Error, Equatable {
    let reason: CampaignRejectReason
    init(_ reason: CampaignRejectReason) { self.reason = reason }
    static let invalid = CampaignRejection(.invalid)
}

/// What a leaf found when it looked up its value.
enum CampaignLookup: Sendable, Equatable {
    case value(CampaignValue)
    /// Not there, or failed to read.
    case unavailable
}

extension CampaignCondition.Operator {
    /// `nil` when the value and the operand are of different types.
    func matches(_ lookup: CampaignLookup) -> Bool? {
        guard case .value(let value) = lookup else {
            if case .exists(let flag) = self { return !flag }
            return false
        }
        switch self {
        case .eq(let operand): return value.equals(operand)
        case .ne(let operand): return value.equals(operand).map { !$0 }
        case .in(let operands):
            guard operands.first?.kind == value.kind else { return nil }
            return operands.contains { value.equals($0) == true }
        case .notIn(let operands):
            guard operands.first?.kind == value.kind else { return nil }
            return !operands.contains { value.equals($0) == true }
        case .gte(let operand): return value.number.map { $0 >= operand }
        case .lte(let operand): return value.number.map { $0 <= operand }
        case .exists(let flag): return flag
        }
    }
}
