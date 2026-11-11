// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

struct BO2RuntimeEntry: Codable {
    let appID: UInt32
    let mode: String
    let executable: String
    let steamExecutableSHA256: String?
    let unpackedExecutableSHA256: String?
    let frameworkSHA256: String
    let sectionsSHA256: String
    let nativeProvider: Bool
    var originalToUnpackedVerified: Bool
}

struct BO2RuntimeCatalog {
    enum Availability: Equatable {
        case ready(mode: String)
        case unavailable(String)

        var message: String {
            switch self {
            case .ready: return "Ready to play"
            case .unavailable(let reason): return reason
            }
        }
    }
    private struct Document: Codable { let version: Int; let entries: [BO2RuntimeEntry] }
    private let entries: [UInt32: BO2RuntimeEntry]

    init(bundleRoot: URL) {
        let loaded = try? Data(contentsOf: bundleRoot.appendingPathComponent("RuntimeCatalog.json"))
        let document = loaded.flatMap { try? JSONDecoder().decode(Document.self, from: $0) }
        self = (document?.version == 1 ? try? Self(entries: document!.entries) : nil) ?? Self.empty
    }

    private static let empty = try! Self(entries: [])

    init(entries: [BO2RuntimeEntry]) throws {
        var result: [UInt32: BO2RuntimeEntry] = [:]
        for entry in entries {
            guard Self.mode(appID: entry.appID) == entry.mode,
                  Self.executable(appID: entry.appID) == entry.executable,
                  result[entry.appID] == nil,
                  Self.validHash(entry.frameworkSHA256), Self.validHash(entry.sectionsSHA256),
                  entry.steamExecutableSHA256.map(Self.validHash) ?? true,
                  entry.unpackedExecutableSHA256.map(Self.validHash) ?? true,
                  !entry.originalToUnpackedVerified ||
                    (entry.steamExecutableSHA256 != nil && entry.unpackedExecutableSHA256 != nil) else {
                throw SteamFileError.invalid("Invalid runtime compatibility catalogue.")
            }
            result[entry.appID] = entry
        }
        self.entries = result
    }

    static func mode(appID: UInt32) -> String? {
        [202970: "sps", 202990: "mps", 212910: "zms"][appID]
    }

    private static func executable(appID: UInt32) -> String? {
        [202970: "t6sp.exe", 202990: "t6mp.exe", 212910: "t6zm.exe"][appID]
    }

    func entry(appID: UInt32) -> BO2RuntimeEntry? { entries[appID] }

    /// Run off the main actor: sections are large and must be streamed.
    func check(appID: UInt32, bundleRoot: URL, gameRoot: URL?, downloaded: Bool) throws -> Availability {
        guard let entry = entries[appID] else { return .unavailable("Runtime unavailable for this game") }
        guard entry.nativeProvider else { return .unavailable("Steam session support is unavailable in this runtime") }
        let framework = bundleRoot.appendingPathComponent("Frameworks/\(entry.mode).framework/\(entry.mode)")
        let sections = bundleRoot.appendingPathComponent("Modes/\(entry.mode)/pe_sections.bin")
        guard try Self.sha256(framework) == entry.frameworkSHA256,
              try Self.sha256(sections) == entry.sectionsSHA256 else {
            return .unavailable("Runtime files do not match this build")
        }
        guard let gameRoot,
              FileManager.default.fileExists(atPath: gameRoot.appendingPathComponent(entry.executable).path),
              FileManager.default.fileExists(atPath: gameRoot.appendingPathComponent("zone/all").path) else {
            return .unavailable("Game files are not installed")
        }
        if downloaded {
            guard entry.originalToUnpackedVerified, let originalHash = entry.steamExecutableSHA256 else {
                return .unavailable("Downloaded-game compatibility has not been verified")
            }
            guard try Self.sha256(gameRoot.appendingPathComponent(entry.executable)) == originalHash else {
                return .unavailable("This executable version is not supported")
            }
        }
        return .ready(mode: entry.mode)
    }

    static func sha256(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SteamFileError.invalid("A runtime file is missing or unsafe.")
        }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty else { break }
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validHash(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
