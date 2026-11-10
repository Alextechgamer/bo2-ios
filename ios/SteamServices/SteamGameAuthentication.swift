// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 BO2 iOS contributors
// Madeira Converter Exception: see ../SteamAuth/LICENSE-EXCEPTION.md

import Foundation

/// Requests Steam-issued tickets. The complete encrypted envelope stays opaque.
/// Account changes invalidate outstanding replies; Steam decides entitlement.
@MainActor
final class SteamGameAuthentication {
    static let maxUserDataBytes = 64 * 1024
    private struct RateKey: Hashable { let steamID: UInt64; let appID: UInt32 }
    private let session: any SteamCMSession
    private let now: @MainActor () -> TimeInterval
    private let timeout: TimeInterval
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var pending: [UInt32: UInt64] = [:]
    private var submitted: [RateKey: TimeInterval] = [:]
    /// Locally announced presence, not proof of game-service acceptance.
    private(set) var announcedAppID: UInt32?
    private var announcedSteamID: UInt64 = 0
    private var gameTransition: UInt64?

    init(session: any SteamCMSession,
         now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         timeout: TimeInterval = 20) {
        self.session = session
        self.now = now
        self.timeout = timeout
    }

    func accountChanged() {
        generation &+= 1
        pending.removeAll()
        announcedAppID = nil
        announcedSteamID = 0
        gameTransition = nil
        // Keep each account's recent submission times across sign-out/relogin.
    }

    func beginGameSession(appID: UInt32) async throws {
        try Task.checkCancellation()
        guard appID != 0, announcedAppID == nil, gameTransition == nil else { throw SteamError.invalidMessage }
        sequence &+= 1
        let operation = sequence, accountGeneration = generation
        gameTransition = operation
        defer { if gameTransition == operation { gameTransition = nil } }
        try await session.ensureConnected()
        try Task.checkCancellation()
        guard generation == accountGeneration, session.steamID != 0 else { throw SteamError.disconnected }
        let steamID = session.steamID
        do {
            try await session.sendClientMessage(eMsg: .clientGamesPlayed,
                body: CMsgClientGamesPlayed.serialize(appID: appID))
            try Task.checkCancellation()
            guard generation == accountGeneration, session.steamID == steamID,
                  gameTransition == operation else { throw SteamError.disconnected }
            announcedSteamID = steamID
            announcedAppID = appID
        } catch {
            // A cancelled write may already have reached Steam. Clear presence
            // from an uncancelled task, but never send on a different account.
            let cleanup = Task { @MainActor in
                guard generation == accountGeneration, session.steamID == steamID,
                      gameTransition == operation else { return }
                do { try await session.sendClientMessage(eMsg: .clientGamesPlayed, body: Data()) }
                catch {
                    if generation == accountGeneration, session.steamID == steamID {
                        await session.disconnectGracefully()
                    }
                }
            }
            await cleanup.value
            throw error
        }
    }

    func endGameSession() async throws {
        guard announcedAppID != nil else { return }
        try Task.checkCancellation()
        guard gameTransition == nil else { throw SteamError.invalidMessage }
        let accountGeneration = generation, steamID = announcedSteamID
        guard session.steamID == steamID, steamID != 0 else { throw SteamError.disconnected }
        sequence &+= 1
        let operation = sequence
        gameTransition = operation
        defer { if gameTransition == operation { gameTransition = nil } }
        try await session.sendClientMessage(eMsg: .clientGamesPlayed, body: Data())
        guard generation == accountGeneration, session.steamID == steamID,
              gameTransition == operation else { throw SteamError.disconnected }
        announcedAppID = nil
        announcedSteamID = 0
    }

    func requestEncryptedAppTicket(appID: UInt32, userData: Data) async throws -> Data {
        try Task.checkCancellation()
        guard appID != 0, userData.count <= Self.maxUserDataBytes,
              timeout.isFinite, timeout > 0, timeout <= 120 else { throw SteamError.invalidMessage }
        guard pending[appID] == nil else { throw SteamError.serviceRefused(29) }
        guard pending.count < 128 else { throw SteamError.rateLimited }
        sequence &+= 1
        let operation = sequence, accountGeneration = generation
        pending[appID] = operation
        defer { if pending[appID] == operation { pending.removeValue(forKey: appID) } }

        try await session.ensureConnected()
        try Task.checkCancellation()
        guard generation == accountGeneration, session.steamID != 0 else { throw SteamError.disconnected }
        let steamID = session.steamID
        let key = RateKey(steamID: steamID, appID: appID)
        let time = now()
        guard time.isFinite else { throw SteamError.invalidMessage }
        if let previous = submitted[key], time - previous < 60 { throw SteamError.serviceRefused(25) }
        submitted = submitted.filter { time - $0.value < 60 }
        guard submitted.count < 128 else { throw SteamError.rateLimited }
        // A request that times out may already have reached Steam; do not retry
        // it within the same minute or manufacture a replacement result.
        submitted[key] = time
        let body = CMsgClientRequestEncryptedAppTicket(appID: appID, userData: userData).serialize()
        let reply = try await session.sendAndWait(eMsg: .clientRequestEncryptedAppTicket, body: body,
            responseEMsg: .clientRequestEncryptedAppTicketResponse, timeout: timeout)
        try Task.checkCancellation()
        guard generation == accountGeneration, session.steamID == steamID,
              pending[appID] == operation else { throw SteamError.disconnected }
        let response = try CMsgClientRequestEncryptedAppTicketResponse.deserialize(from: reply.body)
        guard response.result == 1 else { throw SteamError.serviceRefused(response.result) }
        guard response.appID == appID else { throw SteamError.invalidMessage }
        try response.validateEncryptedTicket()
        return response.encodedTicket
    }
}
