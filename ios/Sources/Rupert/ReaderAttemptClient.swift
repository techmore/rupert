import Foundation
import WebKit

/// Sends one request and returns the answer. The app's sends carry the web views' session cookie;
/// tests pass a stub, so no test touches the network.
protocol ReaderHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Why a call to Rupert's server did not give a usable answer.
enum ReaderAPIFailure: Error, Equatable {
    /// No answer at all: offline, timed out, connection dropped.
    case network
    /// An answer with this HTTP status. 404: the feature is off or the token is unknown.
    /// 403: no POS permission, or another device owns the attempt. 422: refused.
    case status(Int)
    /// A success whose body is not what the contract says.
    case malformed

    /// Worth sending again: the server may never have seen it, or was briefly unwell.
    var isRetryable: Bool {
        switch self {
        case .network: return true
        case let .status(code): return code >= 500 || code == 408 || code == 429
        case .malformed: return false
        }
    }

    var httpStatus: Int? {
        if case let .status(code) = self { return code }
        return nil
    }
}

/// The server's answer to start: what to charge, fixed by the server.
struct ReaderAttemptStart: Equatable, Sendable {
    let reference: String
    let amountCents: Int
    let tipCents: Int
    let currency: String
    let expiresAt: Date
    let reader: [String: String]
}

/// The server's answer to a report or a cancel: the attempt's status at that moment. `unknown`
/// means reported and awaiting the server's own lookup; only the page shows the confirmed outcome.
struct ReaderAttemptAck: Equatable, Sendable {
    let status: String
    let reported: Bool
}

/// The three calls the app makes for a phone card reader payment. The register page opens the
/// attempt and reads its status itself; the app is never given a checkout id.
///
///     POST /native/reader_attempts/start   {token, device_id}
///     POST /native/reader_attempts/result  {token, device_id, result}
///     POST /native/reader_attempts/cancel  {token, device_id}
struct ReaderAttemptClient: Sendable {
    let baseURL: @Sendable () -> URL
    let transport: any ReaderHTTPTransport
    var userAgent = "Rupert iOS"

    func start(token: String, deviceID: String) async -> Result<ReaderAttemptStart, ReaderAPIFailure> {
        await post("/native/reader_attempts/start", ["token": token, "device_id": deviceID]).flatMap { json in
            guard let reference = json["reference"] as? String, reference.range(of: "\\A[A-Za-z0-9]{1,50}\\z", options: .regularExpression) != nil,
                  let amount = Self.integer(json["amount_cents"]), (1...9_999_999).contains(amount),
                  let currency = json["currency"] as? String, currency.range(of: "\\A[A-Z]{3}\\z", options: .regularExpression) != nil,
                  let expiry = (json["expires_at"] as? String).flatMap(Self.date) else { return .failure(.malformed) }
            let tip = Self.integer(json["tip_cents"]) ?? 0
            guard (0...amount).contains(tip) else { return .failure(.malformed) }
            var reader: [String: String] = [:]
            for (key, value) in json["reader"] as? [String: Any] ?? [:] {
                if let text = value as? String { reader[key] = text } else if let number = Self.integer(value) { reader[key] = String(number) }
            }
            return .success(ReaderAttemptStart(reference: reference, amountCents: amount, tipCents: tip, currency: currency,
                                               expiresAt: expiry, reader: reader))
        }
    }

    func report(token: String, deviceID: String, result: CardReadResult) async -> Result<ReaderAttemptAck, ReaderAPIFailure> {
        await post("/native/reader_attempts/result", ["token": token, "device_id": deviceID, "result": result.reportFields]).flatMap(Self.ack)
    }

    func cancel(token: String, deviceID: String) async -> Result<ReaderAttemptAck, ReaderAPIFailure> {
        await post("/native/reader_attempts/cancel", ["token": token, "device_id": deviceID]).flatMap(Self.ack)
    }

    private func post(_ path: String, _ body: [String: Any]) async -> Result<[String: Any], ReaderAPIFailure> {
        guard let url = URL(string: path, relativeTo: baseURL())?.absoluteURL,
              let data = try? JSONSerialization.data(withJSONObject: body) else { return .failure(.malformed) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = data
        guard let (answer, response) = try? await transport.send(request) else { return .failure(.network) }
        guard response.statusCode == 200 else { return .failure(.status(response.statusCode)) }
        guard let json = try? JSONSerialization.jsonObject(with: answer) as? [String: Any] else { return .failure(.malformed) }
        return .success(json)
    }

    private static func ack(_ json: [String: Any]) -> Result<ReaderAttemptAck, ReaderAPIFailure> {
        guard let status = json["status"] as? String, ["submitting", "unknown", "paid", "declined"].contains(status),
              let reported = json["reported"] as? Bool else { return .failure(.malformed) }
        return .success(ReaderAttemptAck(status: status, reported: reported))
    }

    /// A whole number, and not a JSON true or false (which Foundation would also hand over as 1 or 0).
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == number.doubleValue.rounded(), abs(number.doubleValue) < 1e15 else { return nil }
        return number.intValue
    }

    static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

/// The app's transport: the web views' session cookie for the request's host, as the push token
/// registration sends it (PushRegistration), and no redirects. A signed-out session answers with
/// a redirect to the sign-in page; following it would read a web page as a payment answer.
struct WebSessionTransport: ReaderHTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let signed = await withCheckedContinuation { continuation in
            PushRegistration.withWebCookies(request) { continuation.resume(returning: $0) }
        }
        let (data, response) = try await URLSession.shared.data(for: signed, delegate: NoRedirects())
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

/// The app install identifier the server ties an attempt to. Made once and kept, so it is the
/// same after a relaunch; a reinstall makes a new one. It identifies nothing but this install.
enum InstallIdentifier {
    static let key = "rupert.reader.installIdentifier"

    static func current(in defaults: UserDefaults = .standard) -> String {
        if let saved = defaults.string(forKey: key), isUsable(saved) { return saved }
        var made = UUID().uuidString.lowercased()
        while !isUsable(made) { made = UUID().uuidString.lowercased() }
        defaults.set(made, forKey: key)
        return made
    }

    /// The server's form (16 to 64 letters, digits or dashes), and no long run of digits: the
    /// server refuses any request with something shaped like a card number in it, and about one
    /// random UUID in a thousand has such a run. An install must never be the unlucky one.
    static func isUsable(_ value: String) -> Bool {
        value.range(of: "\\A[A-Za-z0-9-]{16,64}\\z", options: .regularExpression) != nil
            && value.range(of: "[0-9](-?[0-9]){9,}", options: .regularExpression) == nil
    }
}
