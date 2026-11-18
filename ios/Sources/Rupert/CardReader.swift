import Foundation

/// A card reader the phone runs for one payment (docs/card-reader.md).
///
/// Rupert's server fixes what to charge; the reader charges it and says what happened. Card data
/// stays inside the reader: the only things that come back are the fields of `CardReadResult`,
/// which are the fields Rupert's server accepts. Nothing else about a card exists in the app.
///
/// This repository holds the protocol and a fake (`FakeCardReader`, debug builds only). A reader
/// backed by a payment provider's SDK is supplied from outside this repository.
protocol CardReader: Sendable {
    /// Whether this phone can take a card right now, so the tender can be hidden or refused.
    func availability() async -> CardReaderAvailability

    /// Runs the reader once for `request` and returns when it has an answer. Called at most once
    /// for a payment attempt, and never again for the same reference.
    func read(_ request: CardReadRequest) async -> CardReadResult

    /// Closes the reader if it is open. The pending `read` then returns: `cancelled` when nothing
    /// was charged, or the real result when the card had already been read.
    func cancel() async
}

enum CardReaderAvailability: Equatable, Sendable {
    case available
    case unavailable(CardReaderUnavailableReason)
}

enum CardReaderUnavailableReason: String, Equatable, Sendable {
    /// The phone's hardware or iOS version cannot read cards.
    case unsupportedDevice
    /// iPads do not read contactless cards.
    case iPad
    /// The reader is not offered in this country or region.
    case region
    /// Rupert's server has the feature off for this deployment or workspace.
    case featureOff
    /// No reader is built into this app, or the store's reader account is not set up.
    case notConfigured
}

/// What the server told the app to charge. Every value comes from Rupert's server
/// (`POST /native/reader_attempts/start`), never from the web page.
struct CardReadRequest: Equatable, Sendable {
    /// Rupert's reference for the payment; the provider attaches it to the sale.
    let reference: String
    /// The exact total to charge, in the currency's minor unit. Tips and fees are off in the reader.
    let amountCents: Int
    /// The part of `amountCents` that is a tip already chosen at the register.
    let tipCents: Int
    let currency: String
    /// The reader must not be open after this moment.
    let expiresAt: Date
    /// Non-secret values the provider's reader needs, passed through as the server sent them.
    let providerParameters: [String: String]
}

enum CardBrand: String, CaseIterable, Sendable {
    case visa = "Visa", mastercard = "Mastercard", amex = "Amex", discover = "Discover", jcb = "JCB"
}

enum CardEntryMethod: String, CaseIterable, Sendable {
    case contactless, chip, swipe, manual
}

/// Everything a reader may say about one read: an outcome and six optional facts. These are the
/// fields Rupert's server accepts in a report and no others. A value that is not in the accepted
/// form, or that looks like a card number, is dropped when the result is made.
struct CardReadResult: Equatable, Sendable {
    enum Status: String, CaseIterable, Sendable {
        case approved, declined
        /// The customer or the cashier closed the reader. Nothing was charged.
        case cancelled
        /// The reader could not finish. Whether a card was charged is not known.
        case failed
        /// No answer in time. Whether a card was charged is not known.
        case timedOut
    }

    let status: Status
    let providerReference: String?
    let amountCents: Int?
    let cardBrand: CardBrand?
    let lastFour: String?
    let entryMethod: CardEntryMethod?
    let approvalCode: String?

    init(status: Status, providerReference: String? = nil, amountCents: Int? = nil, cardBrand: CardBrand? = nil,
         lastFour: String? = nil, entryMethod: CardEntryMethod? = nil, approvalCode: String? = nil) {
        self.status = status
        self.providerReference = Self.accepted(providerReference, pattern: "\\A[A-Za-z0-9-]{1,40}\\z")
        self.amountCents = amountCents.flatMap { (1...9_999_999).contains($0) ? $0 : nil }
        self.cardBrand = cardBrand
        self.lastFour = Self.accepted(lastFour, pattern: "\\A[0-9]{4}\\z")
        self.entryMethod = entryMethod
        self.approvalCode = Self.accepted(approvalCode, pattern: "\\A[A-Za-z0-9]{1,12}\\z")
    }

    static let cancelled = CardReadResult(status: .cancelled)
    static let failed = CardReadResult(status: .failed)
    static let timedOut = CardReadResult(status: .timedOut)

    /// The status only: what is kept when the facts of a read are no longer in memory.
    var statusOnly: CardReadResult { CardReadResult(status: status) }

    /// The `result` object of a report to Rupert's server. The server takes four statuses: a
    /// time-out is a failure, and so is an approval without an amount (the server needs the
    /// amount to accept an approval, and looks the payment up itself either way).
    var reportFields: [String: Any] {
        var fields: [String: Any] = [:]
        switch status {
        case .approved: fields["status"] = amountCents == nil ? "failed" : "approved"
        case .declined: fields["status"] = "declined"
        case .cancelled: fields["status"] = "cancelled"
        case .failed, .timedOut: fields["status"] = "failed"
        }
        if let providerReference { fields["provider_reference"] = providerReference }
        if let amountCents { fields["amount_cents"] = amountCents }
        if let cardBrand { fields["card_brand"] = cardBrand.rawValue }
        if let lastFour { fields["last_four"] = lastFour }
        if let entryMethod { fields["entry_method"] = entryMethod.rawValue }
        if let approvalCode { fields["auth_code"] = approvalCode }
        return fields
    }

    /// `value` when it has the accepted form and no run of digits long enough to be a card number.
    private static func accepted(_ value: String?, pattern: String) -> String? {
        guard let value, value.range(of: pattern, options: .regularExpression) != nil,
              value.range(of: "[0-9]{12,}", options: .regularExpression) == nil else { return nil }
        return value
    }
}

/// The reader in builds that have none: every shipped build today.
struct UnavailableCardReader: CardReader {
    var reason: CardReaderUnavailableReason = .notConfigured

    func availability() async -> CardReaderAvailability { .unavailable(reason) }
    func read(_ request: CardReadRequest) async -> CardReadResult { .failed }
    func cancel() async {}
}

/// The reader this build takes payments with.
enum CardReaders {
    /// Release builds: the provided reader, or none. Debug builds may ask for the fake with
    /// `RUPERT_FAKE_CARD_READER` in the scheme's environment, as `RUPERT_DEV_ORIGIN` picks a
    /// local server; the fake is not compiled into a release build at all.
    ///
    /// A reader backed by a provider's SDK comes from outside this repository: a private build
    /// adds its own sources with a type named `ProvidedCardReader` and sets the
    /// `RUPERT_CARD_READER_PROVIDER` compilation condition (docs/card-reader.md). Nothing in this
    /// repository sets it.
    static func make(environment: [String: String] = ProcessInfo.processInfo.environment) -> any CardReader {
#if DEBUG
        if let fake = FakeCardReader(environment: environment) { return fake }
#endif
#if RUPERT_CARD_READER_PROVIDER
        return ProvidedCardReader()
#else
        return UnavailableCardReader()
#endif
    }
}
