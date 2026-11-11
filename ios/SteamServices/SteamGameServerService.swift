// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 BO2 iOS contributors
// Madeira Converter Exception: see ../SteamAuth/LICENSE-EXCEPTION.md
import Combine
import Foundation

/// A separate anonymous CM connection. A player identity or a local game
/// announcement never establishes a server identity or secure policy.
@MainActor
final class SteamGameServerService {
    struct Configuration {
        let ip: UInt32
        let steamPort: UInt16
        let gamePort: UInt16
        let queryPort: UInt16
        let serverMode: UInt32
        let version: String
        var dedicated: Bool
        let gameDirectory: String
    }
    struct Snapshot: Equatable {
        var steamID: UInt64 = 0
        var loggedOn = false
        var secure: Bool?
        var publicIPv4: UInt32 = 0
    }
    struct Event {
        let callbackID: UInt32
        let result: UInt32
        let secure: Bool?
    }
    @Published private(set) var snapshot = Snapshot()
    var eventsDidChange: (@MainActor () -> Void)?
    var serverSteamID: UInt64 { snapshot.steamID }
    var isLoggedOn: Bool { snapshot.loggedOn }
    var secureStatus: Bool? { snapshot.secure }
    var publicIPv4: UInt32 { snapshot.publicIPv4 }
    private let appID: UInt32
    private let session: SteamSession
    private var lease: UUID?
    private var generation: UInt64 = 0
    private var starting = false
    private var events: [Event] = []

    init(appID: UInt32, session: SteamSession? = nil) {
        self.appID = appID
        self.session = session ?? SteamSession(authentication: .anonymousGameServer(appID: appID))
        self.session.identityDidChange = { [weak self] id in
            guard let self, id == 0, snapshot.loggedOn else { return }
            snapshot = Snapshot()
            emit(callback: 103, result: 3)
        }
    }

    func start(_ configuration: Configuration) async throws {
        try Task.checkCancellation()
        guard session.anonymousGameServerAppID == appID, [UInt32(202990),212910].contains(appID),
              configuration.serverMode == 3, configuration.gamePort != 0,
              !configuration.version.isEmpty, configuration.version.utf8.count <= 128,
              configuration.gameDirectory.utf8.count <= 128, !starting, !snapshot.loggedOn else {
            throw SteamError.invalidMessage
        }
        starting = true
        generation &+= 1
        let attempt = generation
        defer { if generation == attempt { starting = false } }
        do {
            lease = try session.acquireRuntimeLease()
            try await session.ensureConnected()
            try Task.checkCancellation()
            guard generation == attempt else { throw SteamError.disconnected }
            let id = session.steamID
            guard id >> 56 == 1, (id >> 52) & 15 == 4, id & 0xffffffff != 0 else {
                throw SteamError.invalidMessage
            }
            session.registerHandler(for: .gsStatusReply) { [weak self] message in
                guard let self, generation == attempt, snapshot.loggedOn else { return }
                do {
                    let secure = try Self.policy(message)
                    snapshot.secure = secure
                    emit(callback: 115, result: 1, secure: secure)
                } catch { snapshot.secure = nil }
            }
            snapshot = Snapshot(steamID: id, loggedOn: true, secure: nil, publicIPv4: session.publicIPv4 ?? 0)
            emit(callback: 101, result: 1)
            var status = ProtobufEncoder()
            status.writeUInt32(fieldNumber: 1, value: appID)
            // These are requested server flags, not confirmed policy.
            status.writeUInt32(fieldNumber: 2, value: 1 | 2 | (configuration.dedicated ? 4 : 0))
            status.writeUInt32(fieldNumber: 3, value: configuration.ip)
            status.writeUInt32(fieldNumber: 4, value: UInt32(configuration.gamePort))
            status.writeString(fieldNumber: 5, value: configuration.gameDirectory)
            status.writeString(fieldNumber: 6, value: configuration.version)
            status.writeUInt32(fieldNumber: 7, value: UInt32(configuration.queryPort))
            try await session.sendClientMessage(eMsg: .gsServerType, body: status.data)
            try Task.checkCancellation()
            guard generation == attempt, session.steamID == id else { throw SteamError.disconnected }
        } catch {
            guard generation == attempt else { throw error }
            let wasLoggedOn = snapshot.loggedOn
            snapshot = Snapshot()
            if let lease { session.releaseRuntimeLease(lease); self.lease = nil }
            await session.disconnectGracefully()
            guard generation == attempt else { throw error }
            emit(callback: wasLoggedOn ? 103 : 102, result: Self.result(error))
            throw error
        }
    }

    func stop() async {
        generation &+= 1
        starting = false
        snapshot = Snapshot()
        events.removeAll()
        if let lease { session.releaseRuntimeLease(lease); self.lease = nil }
        await session.disconnectGracefully()
    }

    func drainEvents() -> [Event] {
        let completed = events
        events.removeAll()
        return completed
    }

    private func emit(callback: UInt32, result: UInt32, secure: Bool? = nil) {
        // At most connection/policy/disconnection events are normally pending.
        // A misbehaving consumer cannot create unbounded storage.
        if events.count >= 128 { events.removeFirst() }
        events.append(Event(callbackID: callback, result: result, secure: secure))
        eventsDidChange?()
    }

    private static func result(_ error: Error) -> UInt32 {
        switch error {
        case SteamError.logonDenied(let result), SteamError.serviceRefused(let result): return result
        case SteamError.connectionTimeout: return 16
        case SteamError.disconnected, is CancellationError: return 3
        default: return 2
        }
    }

    private static func policy(_ message: SteamMessageCodec.IncomingMessage) throws -> Bool {
        guard message.isProtobuf, message.rawEMsg == 774, message.body.count <= 4096 else {
            throw SteamError.invalidMessage
        }
        var decoder = ProtobufDecoder(message.body)
        var secure = false // Proto2 default after a genuine GSStatusReply arrives.
        while let tag = try decoder.readTag() {
            if tag.fieldNumber == 1 {
                guard tag.wireType == .varint else { throw SteamError.invalidMessage }
                let value = try decoder.readVarint()
                guard value <= 1 else { throw SteamError.invalidMessage }
                secure = value == 1
            } else { try decoder.skip(wireType: tag.wireType) }
        }
        return secure
    }
}
