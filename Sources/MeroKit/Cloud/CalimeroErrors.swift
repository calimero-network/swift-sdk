import Foundation

// What a Calimero 1.0 node's refusals mean to a caller. Port of mero-js
// `cloud-v2/errors.ts`.
//
// The node answers an error as `{ error: CODE, message, details }` with an
// HTTP status. ``errorFrom(status:body:retryAfter:)`` is the one place the
// client turns that into an error a caller can switch on; every call, view
// and event stream goes through it. It matches the status and the code
// together, never the status alone. Anything it does not recognise stays a
// plain ``CalimeroError`` carrying both.
//
// Every typed error is a subclass of ``CalimeroError``, so
// `catch let error as CalimeroError` and its `status` and `code` keep working
// for all of them, and `catch let error as AppError` picks out one.

/// A refusal the node answered. (== mero-js `CalimeroError`.)
public class CalimeroError: Error, LocalizedError, CustomStringConvertible, @unchecked Sendable {
    /// The HTTP status.
    public let status: Int
    /// The node's code (`NOT_FOUND`, `APP_ERROR`, …).
    public let code: String
    /// The node's message.
    public let message: String
    /// The node's `details`.
    public let details: [String: JSONValue]

    public init(status: Int, code: String, message: String, details: [String: JSONValue] = [:]) {
        self.status = status
        self.code = code
        self.message = message
        self.details = details
    }

    public var errorDescription: String? { "\(status) \(code): \(message)" }
    public var description: String { errorDescription ?? code }
}

/// `401 UNAUTHENTICATED` that refreshing could not answer: sign in (again)
/// and repeat the request. The client refreshes once by itself when it holds
/// a refresh token; this reaches a caller when there is none (an API key) or
/// the refresh was refused. (== mero-js `LoginRequired`.)
public final class LoginRequired: CalimeroError, @unchecked Sendable {
    public init(_ message: String, details: [String: JSONValue] = [:]) {
        super.init(status: 401, code: "UNAUTHENTICATED", message: message, details: details)
    }
}

/// `421 WRONG_NODE`: this node runs a mero-tee release the account's owners
/// have not approved, so it neither issues nor takes the account's sessions.
/// The client moves to the next node it was given (`nodes`) and repeats the
/// request once by itself; this reaches a caller when it knows no other node,
/// when the next one refused too, or after a sign-in (which needs the passkey
/// again: repeat it, and it goes to the next node). (== mero-js `WrongNode`.)
public final class WrongNode: CalimeroError, @unchecked Sendable {
    public init(_ message: String, details: [String: JSONValue] = [:]) {
        super.init(status: 421, code: "WRONG_NODE", message: message, details: details)
    }
}

/// `421 NOT_LEADER`: the request must run on the leader, which
/// `details.leaderUrl` names. The client repeats the request once there when
/// the leader is one of the nodes it was given (and so attests under the same
/// policy); otherwise this reaches the caller. mero-js maps this to a plain
/// `CalimeroError`; the type is an addition, a `CalimeroError` all the same.
public final class NotLeader: CalimeroError, @unchecked Sendable {
    /// The leader's URL, when the node named it.
    public let leaderUrl: String?

    public init(_ message: String, details: [String: JSONValue] = [:]) {
        leaderUrl = details["leaderUrl"]?.stringValue
        super.init(status: 421, code: "NOT_LEADER", message: message, details: details)
    }
}

/// `404 NOT_FOUND`: what the request names does not exist for this caller.
/// For an app this does not say whether it exists: an account the app does
/// not admit gets the same answer. (== mero-js `NotFound`.)
public final class NotFound: CalimeroError, @unchecked Sendable {
    public init(_ message: String, details: [String: JSONValue] = [:]) {
        super.init(status: 404, code: "NOT_FOUND", message: message, details: details)
    }
}

/// `412 CONFIRM_REQUIRED`: the call needs the account holder's passkey over a
/// challenge in `details`. The `*Confirmed` methods answer it themselves; it
/// reaches a caller only from a method that was given no passkey.
/// (== mero-js `ConfirmRequired`.)
public final class ConfirmRequired: CalimeroError, @unchecked Sendable {
    public init(_ message: String, details: [String: JSONValue] = [:]) {
        super.init(status: 412, code: "CONFIRM_REQUIRED", message: message, details: details)
    }
}

/// The user declined the passkey prompt a confirmation asked for. Nothing was
/// sent. Not a node refusal, so not a ``CalimeroError``. (== mero-js `ConfirmCancelled`.)
public struct ConfirmCancelled: Error, LocalizedError, Sendable {
    public let cause: String?

    public init(cause: String? = nil) {
        self.cause = cause
    }

    public var errorDescription: String? { "the passkey confirmation was cancelled" }
}

/// `413 ARGS_TOO_LARGE`: the call's arguments are over the node's limit; it
/// did not run. (== mero-js `ArgsTooLarge`.)
public final class ArgsTooLarge: CalimeroError, @unchecked Sendable {
    public init(_ message: String, details: [String: JSONValue] = [:]) {
        super.init(status: 413, code: "ARGS_TOO_LARGE", message: message, details: details)
    }
}

/// `409 IDEMPOTENCY_MISMATCH`: the idempotency key was used before with
/// different arguments. (== mero-js `IdempotencyMismatch`.)
public final class IdempotencyMismatch: CalimeroError, @unchecked Sendable {
    public init(_ message: String, details: [String: JSONValue] = [:]) {
        super.init(status: 409, code: "IDEMPOTENCY_MISMATCH", message: message, details: details)
    }
}

/// `409 RELEASE_DEADLINE`: a mero-tee release's deadline has passed and the
/// set that governs this work has not approved it or a newer one, so new work
/// is refused. Approving ``release`` lifts it. (== mero-js `ReleaseDeadlineError`.)
public final class ReleaseDeadlineError: CalimeroError, @unchecked Sendable {
    /// The release to approve.
    public let release: String
    /// Its deadline, RFC 3339 (`""` when the node did not say).
    public let after: String

    public init(_ message: String, details: [String: JSONValue] = [:]) {
        release = details["release"]?.stringValue ?? ""
        after = details["after"]?.stringValue ?? ""
        super.init(status: 409, code: "RELEASE_DEADLINE", message: message, details: details)
    }
}

/// `409 CONSENT_STALE`: what a consent page showed changed before the person
/// approved. Nothing was approved; ask for a new consent request.
/// (== mero-js `ConsentStale`.)
public final class ConsentStale: CalimeroError, @unchecked Sendable {
    public init(_ message: String, details: [String: JSONValue] = [:]) {
        super.init(status: 409, code: "CONSENT_STALE", message: message, details: details)
    }
}

/// `422 APP_ERROR`: the app refused the call. ``appCode`` is the app's
/// declared error (`Taken`, `Forbidden`, …) and ``fields`` its named fields.
/// The call was logged, so its idempotency key is spent. (== mero-js `AppError`.)
public final class AppError: CalimeroError, @unchecked Sendable {
    public let appCode: String
    public let fields: [String: JSONValue]

    public init(_ message: String, details: [String: JSONValue] = [:]) {
        // The node puts the app's error in `details` as `{ code, fields }`; an
        // older node nests it under `details.error`. Positional payloads
        // (`"0"`, `"1"`) are never read as fields.
        let source: [String: JSONValue] =
            details["code"]?.stringValue != nil ? details : (details["error"]?.objectValue ?? [:])
        appCode = source["code"]?.stringValue ?? ""
        fields = source["fields"]?.objectValue ?? [:]
        super.init(status: 422, code: "APP_ERROR", message: message, details: details)
    }
}

/// `422 TRAP`: the run trapped (`OutOfFuel`, `OutOfMemory`, …). The call was
/// logged. (== mero-js `TrapError`.)
public final class TrapError: CalimeroError, @unchecked Sendable {
    public let kind: String

    public init(_ message: String, details: [String: JSONValue] = [:]) {
        kind = details["kind"]?.stringValue ?? ""
        super.init(status: 422, code: "TRAP", message: message, details: details)
    }
}

/// Whether a call the node answered 503 may have committed: `.no` when the
/// node says it did not (`TIMEOUT`, `MIGRATING`), `.unknown` otherwise. Never
/// a plain boolean: "unknown" must not read as "no". (== mero-js `Committed`.)
public enum Committed: String, Sendable, Equatable {
    case no
    case unknown
}

/// Any `503`, or a connection that failed, after the client's retries with
/// the same idempotency key ran out. ``reason`` is the node's code in lower
/// case (`timeout`, `migrating`, `unavailable`, …), or `network` when the node
/// gave no answer at all (code `NETWORK`); such a call may have committed.
/// (== mero-js `UnavailableError`.)
public final class UnavailableError: CalimeroError, @unchecked Sendable {
    public let reason: String
    public let committed: Committed
    /// Seconds the node asked to wait, when it said.
    public let retryAfter: Double?
    /// What failed, when the node gave no answer.
    public let cause: Error?

    public init(
        code: String, message: String, details: [String: JSONValue] = [:], retryAfter: Double? = nil,
        cause: Error? = nil
    ) {
        reason = code.lowercased()
        committed = code == "TIMEOUT" || code == "MIGRATING" ? .no : .unknown
        self.retryAfter = retryAfter
        self.cause = cause
        super.init(status: 503, code: code, message: message, details: details)
    }
}

/// The error for a refusal the node answered with `status` and `body` (its
/// JSON `{ error, message, details }`, or whatever it sent). The one place
/// statuses become typed errors. (== mero-js `errorFrom`.)
public func errorFrom(status: Int, body: JSONValue?, retryAfter header: String? = nil) -> CalimeroError {
    let value = body?.objectValue ?? [:]
    let code = value["error"]?.stringValue ?? "ERROR"
    let message = value["message"]?.stringValue ?? ""
    let details = value["details"]?.objectValue ?? [:]
    if status == 503 {
        var retryAfter: Double?
        for candidate in [
            details["retryAfter"]?.doubleValue, header.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) },
        ] {
            if let candidate, candidate.isFinite, candidate >= 0 {
                retryAfter = candidate
                break
            }
        }
        return UnavailableError(code: code, message: message, details: details, retryAfter: retryAfter)
    }
    switch "\(status) \(code)" {
    case "401 UNAUTHENTICATED": return LoginRequired(message, details: details)
    case "421 WRONG_NODE": return WrongNode(message, details: details)
    case "421 NOT_LEADER": return NotLeader(message, details: details)
    case "404 NOT_FOUND": return NotFound(message, details: details)
    case "409 IDEMPOTENCY_MISMATCH": return IdempotencyMismatch(message, details: details)
    case "409 RELEASE_DEADLINE": return ReleaseDeadlineError(message, details: details)
    case "409 CONSENT_STALE": return ConsentStale(message, details: details)
    case "412 CONFIRM_REQUIRED": return ConfirmRequired(message, details: details)
    case "413 ARGS_TOO_LARGE": return ArgsTooLarge(message, details: details)
    case "422 APP_ERROR": return AppError(message, details: details)
    case "422 TRAP": return TrapError(message, details: details)
    default: return CalimeroError(status: status, code: code, message: message, details: details)
    }
}

/// ``errorFrom(status:body:retryAfter:)`` for a raw body: JSON when it is,
/// else its text as the message.
public func errorFrom(status: Int, data: Data, retryAfter: String? = nil) -> CalimeroError {
    if data.isEmpty { return errorFrom(status: status, body: .object([:]), retryAfter: retryAfter) }
    if let json = try? MeroJSON.decode(JSONValue.self, from: data) {
        return errorFrom(status: status, body: json, retryAfter: retryAfter)
    }
    return errorFrom(
        status: status, body: .object(["message": .string(String(decoding: data, as: UTF8.self))]),
        retryAfter: retryAfter)
}
