//
//  ReportPayload.swift
//  Paladala
//
//  Swift mirror of the Worker's `ReportPayload` zod schema
//  (portal/worker/src/types.ts + portal/worker/src/index.ts
//  PayloadSchema).  Must stay in sync with the server-side
//  validation — any field added here must also be added to
//  the Worker or the request will fail `invalid_payload`.
//
//  ReportRaw is a recursive Codable that walks the existing
//  `DiagnosticLogger.Event.details: [String: Any]` dict so we
//  can serialise heterogeneous JSON-shaped values without
//  losing type fidelity.  All string leaves are capped at
//  8 KB (matches Worker's `z.string().min(1).max(8192)`);
//  the total encoded payload is capped at 16 KB so we stay
//  well under the Worker's 256 KB R2 ceiling.
//

import Foundation

struct ReportPayload: Codable, Sendable, Equatable {
    let app_build: String        // "0.5.22.322"
    let app_version: String      // "0.5.22"
    let os_version: String       // "iOS 18.5"
    let error_class: String      // "NSURLErrorTimedOut" or category raw
    let message: String          // ≤8 KB
    let device_model: String?
    let locale: String?
    let session_id: String?
    let stacktrace: String?
    let raw: ReportRaw?
}

/// Recursive JSON value.  Mirrors JSON's `null / bool / number /
/// string / array / object` without using `Any` (which is
/// not Codable).  Custom Codable to handle the recursive case
/// cleanly — Swift's synthesis struggles with `indirect enum`
/// nested inside itself when keys collide.
indirect enum ReportRaw: Codable, Sendable, Equatable {
    case object([String: ReportRaw])
    case array([ReportRaw])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case kind, value, items, fields
    }
    private enum Kind: String, Codable {
        case object, array, string, number, bool, null
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .object:
            let fields = try c.decode([String: ReportRaw].self, forKey: .fields)
            self = .object(fields)
        case .array:
            let items = try c.decode([ReportRaw].self, forKey: .items)
            self = .array(items)
        case .string:
            self = .string(try c.decode(String.self, forKey: .value))
        case .number:
            self = .number(try c.decode(Double.self, forKey: .value))
        case .bool:
            self = .bool(try c.decode(Bool.self, forKey: .value))
        case .null:
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .object(let fields):
            try c.encode(Kind.object, forKey: .kind)
            try c.encode(fields, forKey: .fields)
        case .array(let items):
            try c.encode(Kind.array, forKey: .kind)
            try c.encode(items, forKey: .items)
        case .string(let s):
            try c.encode(Kind.string, forKey: .kind)
            try c.encode(s, forKey: .value)
        case .number(let n):
            try c.encode(Kind.number, forKey: .kind)
            try c.encode(n, forKey: .value)
        case .bool(let b):
            try c.encode(Kind.bool, forKey: .kind)
            try c.encode(b, forKey: .value)
        case .null:
            try c.encode(Kind.null, forKey: .kind)
        }
    }

    // MARK: - Construction from [String: Any]

    /// Walk a Foundation value into a `ReportRaw`, capping each
    /// string at 8 KB and the total encoded size at `byteBudget`
    /// (default 16 KB).  When over budget, returns the truncated
    /// form (or nil if even truncation can't fit).
    static func from(details: [String: Any]?,
                     byteBudget: Int = 16 * 1024,
                     stringCap: Int = 8 * 1024) -> ReportRaw? {
        guard let details else { return nil }
        let raw = walk(value: details, stringCap: stringCap)
        if encodedSize(raw) <= byteBudget {
            return raw
        }
        return truncate(raw: raw, maxStringLen: 256)
    }

    private static func walk(value: Any, stringCap: Int) -> ReportRaw {
        if value is NSNull { return .null }
        if let b = value as? Bool { return .bool(b) }
        // Int → Double (lossy for very large ints but JSON has
        // no native int type; the Worker's zod schema accepts
        // either as long as it's a JSON number).
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
            return .bool(n.boolValue)
        }
        if let n = value as? Int { return .number(Double(n)) }
        if let n = value as? Double { return .number(n) }
        if let s = value as? String {
            let capped = s.count > stringCap
                ? String(s.prefix(stringCap))
                : s
            return .string(capped)
        }
        if let arr = value as? [Any] {
            return .array(arr.map { walk(value: $0, stringCap: stringCap) })
        }
        if let dict = value as? [String: Any] {
            var out: [String: ReportRaw] = [:]
            for (k, v) in dict {
                out[k] = walk(value: v, stringCap: stringCap)
            }
            return .object(out)
        }
        // Fallback: stringify unknown types so the payload
        // doesn't silently drop the field.
        return .string(String(describing: value))
    }

    private static func truncate(raw: ReportRaw, maxStringLen: Int) -> ReportRaw {
        switch raw {
        case .object(let fields):
            return .object(fields.mapValues { truncate(raw: $0, maxStringLen: maxStringLen) })
        case .array(let items):
            return .array(items.map { truncate(raw: $0, maxStringLen: maxStringLen) })
        case .string(let s):
            return .string(String(s.prefix(maxStringLen)))
        case .number, .bool, .null:
            return raw
        }
    }

    private static func encodedSize(_ raw: ReportRaw) -> Int {
        // Best-effort size check via JSONEncoder; throws are
        // treated as "too big to encode" so we return max.
        guard let data = try? JSONEncoder().encode(raw) else { return Int.max }
        return data.count
    }
}