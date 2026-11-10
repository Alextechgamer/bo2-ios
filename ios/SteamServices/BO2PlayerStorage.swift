// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 BO2 iOS contributors
// Madeira Converter Exception: see ../SteamAuth/LICENSE-EXCEPTION.md
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct BO2PlayerStorage {
    struct Paths {
        let players: URL
        let backups: URL
        let cloudBaseline: URL
    }
    let root: URL

    func paths(steamID: UInt64, appID: UInt32) throws -> Paths {
        guard root.isFileURL, steamID != 0, [UInt32(202970),202990,212910].contains(appID) else {
            throw SteamFileError.invalid("A verified account and supported game are required.")
        }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        try directory(base)
        let account = base.appendingPathComponent(String(steamID), isDirectory: true)
        try directory(account)
        let game = account.appendingPathComponent(String(appID), isDirectory: true)
        try directory(game)
        let players = game.appendingPathComponent("players", isDirectory: true)
        let backups = game.appendingPathComponent("backups", isDirectory: true)
        try directory(players); try directory(backups)
        return Paths(players: players, backups: backups,
                     cloudBaseline: game.appendingPathComponent("cloud-baseline.json"))
    }

    private func directory(_ url: URL) throws {
        let files = FileManager.default
        if let attributes = try? files.attributesOfItem(atPath: url.path) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw SteamFileError.invalid("Player storage must use ordinary directories.")
            }
        } else { try files.createDirectory(at: url, withIntermediateDirectories: true) }
    }

    /// Copy only a matching owner's legacy files into an empty destination.
    /// Originals remain available, and a failed copy never publishes partial saves.
    func migrateLegacy(from legacy: URL, verifiedLegacySteamID: UInt64,
                       steamID: UInt64, appID: UInt32) throws -> Bool {
        guard steamID != 0, verifiedLegacySteamID == steamID else { return false }
        let destination = try paths(steamID: steamID, appID: appID).players
        let files = FileManager.default
        guard files.fileExists(atPath: legacy.path) else { return false }
        guard try files.contentsOfDirectory(atPath: destination.path).isEmpty else { return false }
        let sourceAttributes = try files.attributesOfItem(atPath: legacy.path)
        guard sourceAttributes[.type] as? FileAttributeType == .typeDirectory else {
            throw SteamFileError.invalid("Legacy player storage must be an ordinary directory.")
        }
        var enumerationFailure: Error?
        guard let items = files.enumerator(at: legacy, includingPropertiesForKeys: nil,
            errorHandler: { _, error in enumerationFailure = error; return false }) else {
            throw SteamFileError.invalid("Could not inspect legacy player files.")
        }
        for case let file as URL in items {
            let type = try files.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
            guard type == .typeDirectory || type == .typeRegular else {
                throw SteamFileError.invalid("Legacy player files must not contain symbolic links or special files.")
            }
        }
        if let enumerationFailure { throw enumerationFailure }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".players-migration-" + UUID().uuidString, isDirectory: true)
        defer { if files.fileExists(atPath: staging.path) { try? files.removeItem(at: staging) } }
        try files.copyItem(at: legacy, to: staging)
        guard try files.contentsOfDirectory(atPath: destination.path).isEmpty else { return false }
        // POSIX rename atomically replaces only an empty destination directory.
        // A concurrent writer makes it fail rather than overwriting new progress.
        let result = staging.path.withCString { source in
            destination.path.withCString { target in rename(source, target) }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return true
    }
}
