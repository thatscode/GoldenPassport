import Foundation

/// One row of the import preview (docs/design/authenticator-import.md, section 4).
public struct ImportCandidate: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case new
        /// An account with the same secret and settings is already in the list, under this name.
        case exists(String)
        /// The name was taken; this was the name before a number was added.
        case renamed(String)
        case unsupported(MigratedAccount.Problem)
    }

    public let id: Int
    public var name: String
    public let issuer: String
    /// Algorithm, digits and period, or why the account can't be imported.
    public let summary: String
    /// nil for unsupported accounts.
    public let url: String?
    public let status: Status
    public var isSelected: Bool
}

/// Which codes of a Google Authenticator export split over several QR codes have been read.
public struct BatchProgress: Equatable, Sendable {
    public let id: Int
    public let size: Int
    /// 0-based indexes.
    public let read: Set<Int>

    /// 1-based numbers of the codes not read yet, as Google Authenticator counts them.
    public var missing: [Int] {
        (0..<size).filter { !read.contains($0) }.map { $0 + 1 }
    }
}

public enum ImportAddResult: Equatable, Sendable {
    /// This many new rows.
    case added(Int)
    /// Everything in it is already in the preview.
    case alreadyRead
    /// Neither an otpauth link nor a migration code.
    case notAnAccount
    /// Looked like one but couldn't be read; the message says why.
    case invalid(String)
}

public enum ImportNameIssue: Equatable, Sendable {
    /// `row` is 1-based, counting every row of the preview.
    case empty(row: Int)
    case duplicate(row: Int, name: String)
}

/// Collects accounts from QR codes and pasted text into a preview: duplicates are dropped,
/// accounts already in the list are marked, clashing names get a number.
public struct AuthenticatorImport {
    public private(set) var candidates: [ImportCandidate] = []

    private let existingNames: Set<String>
    /// Identity (secret and settings) → name of the account already in the list.
    private let existingIdentities: [String: String]
    private var candidateIdentities: Set<String> = []
    private var readPayloads: Set<String> = []
    private var batchSizes: [Int: Int] = [:]
    private var batchRead: [Int: Set<Int>] = [:]
    private var nextID = 0

    public init(existing: [Account]) {
        existingNames = Set(existing.map(\.name))
        var identities: [String: String] = [:]
        for account in existing {
            guard let totp = try? OTPAuthURL(string: account.url).totp else { continue }
            identities[Self.identity(totp)] = identities[Self.identity(totp)] ?? account.name
        }
        existingIdentities = identities
    }

    /// Exports split over several QR codes, by batch id; single codes aren't listed.
    public var batches: [BatchProgress] {
        batchSizes.keys.sorted().compactMap { id in
            guard let size = batchSizes[id], size > 1 else { return nil }
            return BatchProgress(id: id, size: size, read: batchRead[id] ?? [])
        }
    }

    /// One QR code payload or one line of text.
    public mutating func add(payload rawPayload: String) -> ImportAddResult {
        let payload = rawPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return .notAnAccount }
        if readPayloads.contains(payload) { return .alreadyRead }

        if GoogleAuthenticatorMigration.isMigrationURL(payload) {
            let batch: MigrationBatch
            do {
                batch = try GoogleAuthenticatorMigration.parse(payload)
            } catch {
                return .invalid(error.localizedDescription)
            }
            readPayloads.insert(payload)
            batchSizes[batch.batchID] = max(batchSizes[batch.batchID] ?? 0, batch.batchSize)
            batchRead[batch.batchID, default: []].insert(batch.batchIndex)
            let added = batch.accounts.filter { addMigrated($0) }.count
            return added == 0 && !batch.accounts.isEmpty ? .alreadyRead : .added(added)
        }

        guard payload.lowercased().hasPrefix("otpauth://") else { return .notAnAccount }
        let parsed: OTPAuthURL
        do {
            parsed = try OTPAuthURL(string: payload)
        } catch {
            return .invalid(error.localizedDescription)
        }
        readPayloads.insert(payload)
        return addSupported(name: parsed.suggestedName, issuer: parsed.issuer ?? "", url: payload, totp: parsed.totp)
            ? .added(1) : .alreadyRead
    }

    /// Several lines; blank lines are skipped.
    public mutating func add(text: String) -> [ImportAddResult] {
        text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { add(payload: $0) }
    }

    public mutating func setName(_ name: String, for id: Int) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[index].name = name
    }

    /// Unsupported rows stay unselected.
    public mutating func setSelected(_ selected: Bool, for id: Int) {
        guard let index = candidates.firstIndex(where: { $0.id == id }), candidates[index].url != nil else { return }
        candidates[index].isSelected = selected
    }

    /// The first selected row whose name is empty or already used (by the list or an earlier selected row).
    public var nameIssue: ImportNameIssue? {
        var used = existingNames
        for (offset, candidate) in candidates.enumerated() where candidate.isSelected && candidate.url != nil {
            let name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { return .empty(row: offset + 1) }
            if used.contains(name) { return .duplicate(row: offset + 1, name: name) }
            used.insert(name)
        }
        return nil
    }

    /// The selected, supported rows in order, with trimmed names.
    public var entries: [(name: String, url: String)] {
        candidates.compactMap { candidate in
            guard candidate.isSelected, let url = candidate.url else { return nil }
            return (name: candidate.name.trimmingCharacters(in: .whitespacesAndNewlines), url: url)
        }
    }

    // MARK: - Adding rows

    private mutating func addMigrated(_ account: MigratedAccount) -> Bool {
        if let problem = account.problem {
            let identity = "unsupported:\(account.secret.base64EncodedString()):\(account.label)"
            guard candidateIdentities.insert(identity).inserted else { return false }
            append(ImportCandidate(id: takeID(), name: account.label, issuer: account.issuer, summary: problem.reason,
                                   url: nil, status: .unsupported(problem), isSelected: false))
            return true
        }
        guard let url = account.otpauthURL, let parsed = try? OTPAuthURL(string: url) else { return false }
        return addSupported(name: account.label, issuer: account.issuer, url: url, totp: parsed.totp)
    }

    private mutating func addSupported(name rawName: String, issuer: String, url: String, totp: TOTP) -> Bool {
        let identity = Self.identity(totp)
        guard candidateIdentities.insert(identity).inserted else { return false }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? String(localized: "未命名") : trimmed
        let summary = String(localized: "\(totp.algorithm.rawValue) · \(totp.digits) 位 · \(totp.period) 秒")
        if let existingName = existingIdentities[identity] {
            append(ImportCandidate(id: takeID(), name: name, issuer: issuer, summary: summary, url: url,
                                   status: .exists(existingName), isSelected: false))
        } else if isTaken(name) {
            append(ImportCandidate(id: takeID(), name: uniqueName(for: name), issuer: issuer, summary: summary, url: url,
                                   status: .renamed(name), isSelected: true))
        } else {
            append(ImportCandidate(id: takeID(), name: name, issuer: issuer, summary: summary, url: url,
                                   status: .new, isSelected: true))
        }
        return true
    }

    private mutating func append(_ candidate: ImportCandidate) {
        candidates.append(candidate)
    }

    private mutating func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private func isTaken(_ name: String) -> Bool {
        existingNames.contains(name) || candidates.contains { $0.name == name }
    }

    /// "name (2)", "name (3)", … whichever is free first.
    private func uniqueName(for name: String) -> String {
        var number = 2
        while isTaken("\(name) (\(number))") { number += 1 }
        return "\(name) (\(number))"
    }

    private static func identity(_ totp: TOTP) -> String {
        "\(totp.algorithm.rawValue):\(totp.digits):\(totp.period):\(totp.secret.base64EncodedString())"
    }
}
