// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 BO2 iOS contributors
// Madeira Converter Exception: see ../SteamAuth/LICENSE-EXCEPTION.md
#if canImport(UIKit)
import Foundation
import UIKit

/// Downloads the signed-in account's own copy of the game from Steam's content
/// servers into the app's game folder. Steam issues the depot keys only to an
/// account that owns the game; nothing is fetched from anywhere else and the
/// files are stored as Steam delivers them.
@MainActor
@objc(BO2GameDownload)
final class BO2GameDownload: NSObject {
    /// The games whose mode this app was built with. An app built from fewer
    /// executables does not fetch the files of the modes it cannot run.
    private static let apps: [(id: UInt32, name: String)] = {
        let all: [(id: UInt32, name: String, mode: String)] =
            [(202970, "Campaign", "sps"), (202990, "Multiplayer", "mps"), (212910, "Zombies", "zms")]
        let built = all.filter { app in
            guard let root = Bundle.main.resourceURL else { return false }
            return FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Modes/\(app.mode)/pe_sections.bin").path)
        }
        return (built.isEmpty ? all : built).map { (id: $0.id, name: $0.name) }
    }()
    private static var task: Task<Void, Never>?

    @objc(isRunning) static var isRunning: Bool { task != nil }

    @objc(startWithStatus:)
    static func start(status: @escaping (String, Bool) -> Void) {
        guard task == nil else { return }
        guard SteamSignIn.isSignedIn else {
            status("Sign in to Steam first, then tap Game Files again.", true)
            return
        }
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task { @MainActor in
            let message: String
            do {
                try await run { status($0, false) }
                message = "Game files installed. Choose a mode to play."
            } catch is CancellationError {
                message = "Download paused. Tap Game Files to continue."
            } catch {
                message = Task.isCancelled ? "Download paused. Tap Game Files to continue."
                    : SteamSignIn.message(error) + " Tap Game Files to try again."
            }
            UIApplication.shared.isIdleTimerDisabled = false
            task = nil
            status(message, true)
        }
    }

    @objc static func cancel() { task?.cancel() }

    private static func run(_ status: @escaping (String) -> Void) async throws {
        let files = FileManager.default
        let support = try files.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
        let installed = support.appendingPathComponent("BO2GameFiles", isDirectory: true)
        let partial = support.appendingPathComponent("BO2GameFiles.partial", isDirectory: true)
        let journals = support.appendingPathComponent("BO2GameFiles.download", isDirectory: true)
        // An existing install is checked and repaired in place; a first
        // download only becomes the game folder once every part is there.
        let existing = files.fileExists(atPath: installed.path)
        let target = existing ? installed : partial
        try files.createDirectory(at: target, withIntermediateDirectories: true)

        status("Connecting to Steam…")
        let session = BO2SteamServices.shared.session
        try await session.ensureConnected()
        let fetcher = SteamLibraryFetcher(session: session)
        let downloader = DepotDownloader(session: session)
        var done = 0
        var refused: Error?
        for (index, app) in apps.enumerated() {
            try Task.checkCancellation()
            let label = "\(app.name) (\(index + 1) of \(apps.count))"
            status("Reading \(label) from Steam…")
            guard let info = try await fetcher.fetchInstallInfo(appID: app.id) else { continue }
            do {
                try await downloader.install(info, into: target, journals: journals,
                    ownedDepots: { try? await fetcher.ownedDepotIDs() },
                    progress: { progress in
                        switch progress.phase {
                        case .preparing: status("Checking \(label)…")
                        case .finishing: status("Finishing \(label)…")
                        case .downloading:
                            status(String(format: "Downloading %@ · %.0f%% of %.1f GB · %.1f MB/s", label,
                                          progress.fraction * 100, Double(progress.totalBytes) / 1e9,
                                          progress.bytesPerSecond / 1e6))
                        }
                    })
                done += 1
            } catch SteamError.depotKeyNotFound(let depot) {
                // A mode this account does not own is left out.
                refused = SteamError.depotKeyNotFound(depot)
            } catch SteamError.depotNotFound(let id) {
                refused = SteamError.depotNotFound(id)
            }
        }
        guard done > 0 else { throw refused ?? SteamError.depotNotFound(apps[0].id) }
        if !existing { try files.moveItem(at: partial, to: installed) }
        try? files.removeItem(at: journals)
    }
}
#endif
