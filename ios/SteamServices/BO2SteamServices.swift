// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 BO2 iOS contributors
// Madeira Converter Exception: see ../SteamAuth/LICENSE-EXCEPTION.md

import Combine
import Foundation

struct BO2SteamLibrarySnapshot {
    let steamID: UInt64
    let apps: [SteamAppInfo]
}

enum BO2SteamServiceState {
    case signedOut
    case refreshing(previous: BO2SteamLibrarySnapshot?)
    case ready(BO2SteamLibrarySnapshot)
    case failed(message: String, previous: BO2SteamLibrarySnapshot?)

    var snapshot: BO2SteamLibrarySnapshot? {
        switch self {
        case .signedOut: return nil
        case .ready(let snapshot): return snapshot
        case .refreshing(let previous), .failed(_, let previous): return previous
        }
    }
}

@MainActor
final class BO2SteamServices: ObservableObject {
    static let shared = BO2SteamServices(session: SteamSession())

    @Published private(set) var state: BO2SteamServiceState = .signedOut
    @Published private(set) var authenticatedSteamID: UInt64 = 0
    @Published private(set) var vacBannedApps: [UInt32]?
    let session: any SteamCMSession
    let authentication: SteamGameAuthentication
    private let credentialsAvailable: @MainActor () -> Bool
    private let credentialRevision: @MainActor () -> UInt64
    private var observedCredentialRevision: UInt64
    private let fetchOwnedApps: @MainActor () async throws -> [SteamAppInfo]
    private var generation: UInt64 = 0
    private var refreshTask: Task<Void, Never>?
    private var accountObserver: NSObjectProtocol?
    private var accountChangeTask: Task<Void, Never>?

    init(session: any SteamCMSession,
         credentialsAvailable: @escaping @MainActor () -> Bool = { SteamSignIn.isSignedIn },
         credentialRevision: @escaping @MainActor () -> UInt64 = { SteamSignIn.revision },
         fetchOwnedApps: (@MainActor () async throws -> [SteamAppInfo])? = nil) {
        self.session = session
        self.authentication = SteamGameAuthentication(session: session, credentialRevision: credentialRevision)
        self.credentialsAvailable = credentialsAvailable
        self.credentialRevision = credentialRevision
        self.observedCredentialRevision = credentialRevision()
        let fetcher = SteamLibraryFetcher(session: session)
        self.fetchOwnedApps = fetchOwnedApps ?? { try await fetcher.fetchOwnedApps() }
        accountObserver = NotificationCenter.default.addObserver(
            forName: SteamSignIn.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, observedCredentialRevision != credentialRevision() else { return }
                await accountChanged()
            }
        }
        authenticatedSteamID = session.steamID
        vacBannedApps = session.vacBannedApps
        session.identityDidChange = { [weak self] steamID in self?.authenticatedSteamID = steamID }
        session.vacStatusDidChange = { [weak self] apps in self?.vacBannedApps = apps }
    }

    deinit {
        refreshTask?.cancel()
        accountChangeTask?.cancel()
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
    }

    func accountChanged() async {
        observedCredentialRevision = credentialRevision()
        authentication.accountChanged()
        authenticatedSteamID = 0
        vacBannedApps = nil
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        state = .signedOut
        if let previous = accountChangeTask {
            await previous.value
            return
        }
        let task = Task { await session.disconnectGracefully() }
        accountChangeTask = task
        await task.value
        accountChangeTask = nil
    }

    func refreshOwnedLibrary() async {
        if observedCredentialRevision != credentialRevision() { await accountChanged() }
        if let teardown = accountChangeTask { await teardown.value }
        guard credentialsAvailable() else {
            await accountChanged()
            return
        }
        if let existing = refreshTask {
            await existing.value
            return
        }
        let accountGeneration = generation
        let accountRevision = credentialRevision()
        let previous = state.snapshot
        state = .refreshing(previous: previous)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await session.ensureConnected()
                try Task.checkCancellation()
                guard generation == accountGeneration, credentialRevision() == accountRevision else { return }
                let steamID = session.steamID
                guard steamID != 0 else { throw SteamError.invalidCredentials }
                authenticatedSteamID = steamID
                state = .refreshing(previous: previous?.steamID == steamID ? previous : nil)
                let apps = try await fetchOwnedApps()
                try Task.checkCancellation()
                guard generation == accountGeneration, credentialRevision() == accountRevision,
                      session.steamID == steamID else { return }
                state = .ready(BO2SteamLibrarySnapshot(steamID: steamID, apps: apps))
            } catch {
                guard generation == accountGeneration, credentialRevision() == accountRevision,
                      !Task.isCancelled else { return }
                let retained = session.steamID == 0 || previous?.steamID == session.steamID ? previous : nil
                state = .failed(message: SteamSignIn.message(error), previous: retained)
            }
            if generation == accountGeneration { refreshTask = nil }
        }
        refreshTask = task
        await task.value
    }

    func cancelLibraryRefresh() {
        guard refreshTask != nil else { return }
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        let previous = state.snapshot
        let matching = previous?.steamID == authenticatedSteamID ? previous : nil
        state = .failed(message: "Refresh cancelled. Showing the last library update.", previous: matching)
    }
}
