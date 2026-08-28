// JSONRPC.swift
//
// The newline-framed JSON-RPC 2.0 codec for the local API (02): request/response
// envelopes, a general `JSONValue` for params and event detail payloads, and the
// stable error model whose `data.kind` set is frozen by 02.

import Foundation

// MARK: - JSONValue

/// An arbitrary JSON value. Used where the shape is dynamic: incoming `params`
/// before a method decodes them into a typed struct, and event `detail` payloads
/// (kind-specific JSON) rendered back out on events.get.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Parse a stored JSON string (event detail) into a value, defaulting to an
    /// empty object when the text is empty or unparseable.
    static func parse(_ text: String) -> JSONValue {
        guard let data = text.data(using: .utf8),
              let v = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return .object([:]) }
        return v
    }

    /// The object's members if this is an object, else nil.
    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var intValue: Int? {
        if case .int(let i) = self { return i }
        if case .double(let d) = self {
            // Int(Double) is a runtime trap for non-finite or out-of-Int64-range
            // doubles, so guard before converting. 2^63 is not exactly
            // representable as a Double, so the upper bound is a strict `<`
            // against 9223372036854775808.0 (the next representable value above
            // Int64.max). In-range doubles keep truncating, e.g. 5.9 -> 5.
            guard d.isFinite, d >= -9223372036854775808.0, d < 9223372036854775808.0 else { return nil }
            return Int(d)
        }
        return nil
    }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
}

// MARK: - Request envelope

/// A JSON-RPC id: string, integer, or null. Echoed verbatim on the response.
public enum RPCID: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid id")
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .null: try c.encodeNil()
        }
    }
}

public struct RPCRequest: Decodable {
    public var jsonrpc: String?
    public var id: RPCID?
    public var method: String
    public var params: JSONValue?
}

// MARK: - Errors

/// The stable machine-readable error kinds (02). `invalid_params` additionally
/// names the offending key in its human message.
public enum APIErrorKind: String, Sendable {
    case unauthorized
    case notFound = "not_found"
    case scannerUnavailable = "scanner_unavailable"
    case permissionMissing = "permission_missing"
    case esInactive = "es_inactive"
    case invalidParams = "invalid_params"
    case conflict
}

/// A domain error carrying a JSON-RPC `code`, a plain human `message` that states
/// the recovering action, and the stable `data.kind`. `extraData` rides in
/// `data` alongside `kind` (e.g. the running scanId on a conflict).
public struct APIError: Error, Sendable {
    public var code: Int
    public var message: String
    public var kind: APIErrorKind
    public var extraData: [String: JSONValue]

    public init(code: Int, message: String, kind: APIErrorKind, extraData: [String: JSONValue] = [:]) {
        self.code = code
        self.message = message
        self.kind = kind
        self.extraData = extraData
    }

    // Convenience constructors with the conventional codes.
    public static func unauthorized(_ message: String = "Unauthorized. The first message on a connection must be auth.hello with the API token from ~/Library/Application Support/Plugsight/api-token.") -> APIError {
        APIError(code: -32001, message: message, kind: .unauthorized)
    }
    public static func notFound(_ message: String) -> APIError {
        APIError(code: -32000, message: message, kind: .notFound)
    }
    public static func invalidParams(_ message: String) -> APIError {
        APIError(code: -32602, message: message, kind: .invalidParams)
    }
    public static func conflict(_ message: String, extraData: [String: JSONValue] = [:]) -> APIError {
        APIError(code: -32000, message: message, kind: .conflict, extraData: extraData)
    }
    public static func scannerUnavailable(_ message: String) -> APIError {
        APIError(code: -32000, message: message, kind: .scannerUnavailable)
    }
}

// MARK: - Response encoding

/// Encode a successful result envelope to a single line (no embedded newlines;
/// JSONEncoder never emits raw newlines in compact output).
enum RPCEncoder {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    /// `{ "jsonrpc":"2.0", "id":<id>, "result":<result> }`
    static func result<T: Encodable>(id: RPCID?, _ value: T) throws -> Data {
        try encoder.encode(SuccessEnvelope(id: id ?? .null, result: value))
    }

    /// `{ "jsonrpc":"2.0", "id":<id>, "error":{code,message,data:{kind,...}} }`
    static func error(id: RPCID?, _ error: APIError) -> Data {
        var data: [String: JSONValue] = error.extraData
        data["kind"] = .string(error.kind.rawValue)
        let env = ErrorEnvelope(
            id: id ?? .null,
            error: .init(code: error.code, message: error.message, data: .object(data))
        )
        // Error envelopes are simple and must never themselves throw.
        return (try? encoder.encode(env)) ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"internal error","data":{"kind":"conflict"}}}"#.utf8)
    }

    /// A JSON-RPC notification (no id): `{ "jsonrpc":"2.0","method":..,"params":..}`
    static func notification<T: Encodable>(method: String, params: T) throws -> Data {
        try encoder.encode(NotificationEnvelope(method: method, params: params))
    }

    private struct SuccessEnvelope<T: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id: RPCID
        let result: T
    }
    private struct ErrorEnvelope: Encodable {
        struct Body: Encodable { let code: Int; let message: String; let data: JSONValue }
        let jsonrpc = "2.0"
        let id: RPCID
        let error: Body
    }
    private struct NotificationEnvelope<T: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let method: String
        let params: T
    }
}

// MARK: - Typed params decoding

extension JSONValue {
    /// Decode this value into a typed Codable params struct, mapping any failure
    /// to an invalid_params error.
    func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let DecodingError.keyNotFound(key, _) {
            throw APIError.invalidParams("Missing required parameter '\(key.stringValue)'.")
        } catch let DecodingError.typeMismatch(_, ctx) {
            let key = ctx.codingPath.last?.stringValue ?? "params"
            throw APIError.invalidParams("Parameter '\(key)' has the wrong type.")
        } catch {
            throw APIError.invalidParams("Could not parse the request parameters.")
        }
    }
}
