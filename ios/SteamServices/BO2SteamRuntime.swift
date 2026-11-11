// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 BO2 iOS contributors
// Madeira Converter Exception: see ../SteamAuth/LICENSE-EXCEPTION.md
import Combine
import Foundation
#if canImport(Darwin)
import Darwin
#endif

@MainActor
@objc(BO2SteamLaunch)
final class BO2SteamLaunch: NSObject {
    @objc let gameDirectory: String
    fileprivate let context: BO2SteamRuntimeContext
    private let services: BO2SteamServices
    private let lease: UUID
    private let revision: UInt64
    private let account: UInt64
    private var finished = false

    fileprivate init(gameDirectory: URL, context: BO2SteamRuntimeContext,
                     services: BO2SteamServices, lease: UUID, account: UInt64, revision: UInt64) {
        self.gameDirectory = gameDirectory.path
        self.context = context
        self.services = services
        self.lease = lease
        self.account = account
        self.revision = revision
        super.init()
    }

    @objc(installInHandle:)
    func install(in handle: UnsafeMutableRawPointer) -> Bool {
        guard !finished, SteamSignIn.revision == revision, context.steamID() == account,
              let symbol = dlsym(handle, "bo2_ios_set_steam_provider") else { return false }
        typealias Install = @convention(c) (UnsafePointer<BO2SteamProviderV1>?) -> Bool
        let install = unsafeBitCast(symbol, to: Install.self)
        var provider = context.makeProvider()
        guard withUnsafePointer(to: &provider, { install($0) }) else { return false }
        BO2SteamRuntime.retainInstalledContext(context)
        return true
    }

    @objc func finish() {
        guard !finished else { return }
        finished = true
        context.close()
        Task { @MainActor [self] in
            if SteamSignIn.revision == revision, services.session.steamID == account {
                do { try await services.authentication.endGameSession() }
                catch { await services.session.disconnectGracefully() }
            }
            services.session.releaseRuntimeLease(lease)
            BO2SteamRuntime.launchFinished(self)
        }
    }
}

@MainActor
@objc(BO2SteamRuntime)
final class BO2SteamRuntime: NSObject {
    private static var preparing = false
    private static var active: BO2SteamLaunch?
    // The existing launcher runs one game per process. Retain installed borrowed
    // contexts until process exit so late native/audio callbacks cannot use freed memory.
    private static var installedContexts: [BO2SteamRuntimeContext] = []
    fileprivate static func retainInstalledContext(_ context: BO2SteamRuntimeContext) {
        if !installedContexts.contains(where: { $0 === context }) { installedContexts.append(context) }
    }
    fileprivate static func launchFinished(_ launch: BO2SteamLaunch) {
        if active === launch { active = nil }
    }

    @objc(prepareMode:assets:legacySteamID:completion:)
    static func prepare(mode: String, assets: URL, legacySteamID: UInt64,
                        completion: @escaping (BO2SteamLaunch?, NSError?) -> Void) {
        guard !preparing, active == nil else {
            completion(nil, SteamFileError.invalid("A game session is already active or this mode is unavailable.") as NSError)
            return
        }
        preparing = true
        Task { @MainActor in
            defer { preparing = false }
            do {
                let support = try FileManager.default.url(for: .applicationSupportDirectory,
                    in: .userDomainMask, appropriateFor: nil, create: true)
                let launch = try await prepareLaunch(mode: mode, assets: assets,
                    legacySteamID: legacySteamID, services: .shared,
                    storageRoot: support.appendingPathComponent("BO2Accounts", isDirectory: true))
                active = launch
                completion(launch, nil)
            } catch {
                completion(nil, error as NSError)
            }
        }
    }

    static func prepareLaunch(mode: String, assets: URL, legacySteamID: UInt64,
                              services: BO2SteamServices, storageRoot: URL) async throws -> BO2SteamLaunch {
        let modes: [String: UInt32] = ["sps":202970, "mps":202990, "zms":212910]
        guard let appID = modes[mode], assets.isFileURL else {
            throw SteamFileError.invalid("This game mode is unavailable.")
        }
        let revision = SteamSignIn.revision
        guard SteamSignIn.isSignedIn else { throw SteamError.invalidCredentials }
        await services.refreshOwnedLibrary()
        try Task.checkCancellation()
        guard SteamSignIn.revision == revision, case .ready(let snapshot) = services.state,
              snapshot.steamID == services.session.steamID else { throw SteamError.disconnected }
        let owned = Set(snapshot.apps.map(\.appID))
        guard owned.contains(appID) else {
            throw SteamFileError.invalid("This Steam account does not own the selected game.")
        }
        let bans = try await services.session.awaitVACBannedApps(timeout: 15)
        try Task.checkCancellation()
        guard SteamSignIn.revision == revision, services.session.steamID == snapshot.steamID else {
            throw SteamError.disconnected
        }
        guard !bans.contains(appID) else {
            throw SteamFileError.invalid("Steam reports a VAC ban for this game.")
        }
        let lease = try services.session.acquireRuntimeLease()
        do {
            let storage = BO2PlayerStorage(root: storageRoot)
            let paths = try storage.paths(steamID: snapshot.steamID, appID: appID)
            _ = try storage.migrateLegacy(from: assets.appendingPathComponent("players"),
                verifiedLegacySteamID: legacySteamID, steamID: snapshot.steamID, appID: appID)
            let game = try gameDirectory(assets: assets, players: paths.players)
            guard SteamSignIn.revision == revision else { throw SteamError.disconnected }
            let context = try BO2SteamRuntimeContext(services: services, steamID: snapshot.steamID,
                appID: appID, ownedApps: owned, installedDLC: [])
            try await services.authentication.beginGameSession(appID: appID)
            guard SteamSignIn.revision == revision, context.steamID() == snapshot.steamID else {
                context.close()
                throw SteamError.disconnected
            }
            return BO2SteamLaunch(gameDirectory: game, context: context, services: services,
                lease: lease, account: snapshot.steamID, revision: revision)
        } catch {
            services.session.releaseRuntimeLease(lease)
            throw error
        }
    }

    private static func gameDirectory(assets: URL, players: URL) throws -> URL {
        let files = FileManager.default
        let game = players.deletingLastPathComponent().appendingPathComponent("game", isDirectory: true)
        if let type = try? files.attributesOfItem(atPath: game.path)[.type] as? FileAttributeType {
            guard type == .typeDirectory else { throw SteamFileError.invalid("Game storage must be an ordinary directory.") }
        } else { try files.createDirectory(at: game, withIntermediateDirectories: true) }
        var links = try files.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.lowercased() != "players" }
            .map { ($0.lastPathComponent, $0) }
        links.append(("players", players))
        for (name, target) in links {
            let destination = game.appendingPathComponent(name)
            let previous = try? files.destinationOfSymbolicLink(atPath: destination.path)
            if previous == target.path { continue }
            if previous != nil { try files.removeItem(at: destination) }
            try files.createSymbolicLink(at: destination, withDestinationURL: target)
        }
        return game
    }
}

/// Native game-thread callbacks use this synchronized, account-pinned context.
/// Network work always hops to MainActor. The launcher owns its lifetime through
/// game exit and every outstanding callback; the C ABI borrows its pointer.
final class BO2SteamRuntimeContext: @unchecked Sendable {
    private enum Ticket { case pending; case finished(Data?, UInt32) }
    private let lock = NSLock()
    private let services: BO2SteamServices
    private let account: UInt64
    private let appID: UInt32
    private let revision: UInt64
    private let owned: Set<UInt32>
    private let installed: Set<UInt32>
    private var valid = true
    private var sequence: UInt64 = 0
    private var tickets: [UInt64: Ticket] = [:]
    private var tasks: [UInt64: Task<Void, Never>] = [:]
    private var identitySubscription: AnyCancellable?
    private var securitySubscription: AnyCancellable?
    private var bannedApps: Set<UInt32>?
    private let gameServer: SteamGameServerService?
    private var serverSubscription: AnyCancellable?
    private var serverConfiguration: SteamGameServerService.Configuration?
    private var serverGeneration: UInt64 = 0
    private var serviceGeneration: UInt64 = 0
    private var serverRequested = false
    private var serverID: UInt64 = 0
    private var serverLoggedOn = false
    private var serverSecure: Int32 = -1
    private var serverPublicIP: UInt32 = 0
    private var serverEvents: [BO2SteamServerEvent] = []

    @MainActor
    init(services: BO2SteamServices, steamID: UInt64, appID: UInt32,
         ownedApps: Set<UInt32>, installedDLC: Set<UInt32>, gameServer: SteamGameServerService? = nil) throws {
        guard steamID != 0, services.session.steamID == steamID,
              services.authenticatedSteamID == steamID, ownedApps.contains(appID) else {
            throw SteamFileError.invalid("A verified Steam account and game license are required.")
        }
        guard let banned = services.vacBannedApps, !banned.contains(appID) else {
            throw SteamFileError.invalid("Steam account security status is unavailable or this game has a VAC ban.")
        }
        self.services = services
        self.account = steamID
        self.appID = appID
        self.revision = SteamSignIn.revision
        self.owned = ownedApps
        self.installed = installedDLC.intersection(ownedApps)
        self.bannedApps = Set(banned)
        self.gameServer = gameServer ?? ([UInt32(202990),212910].contains(appID) ? SteamGameServerService(appID: appID) : nil)
        identitySubscription = services.$authenticatedSteamID.sink { [weak self] current in
            guard let self, current != account else { return }
            close()
        }
        securitySubscription = services.$vacBannedApps.sink { [weak self] apps in
            guard let self else { return }
            lock.lock()
            bannedApps = apps.map { Set($0) }
            lock.unlock()
            if apps == nil || apps!.contains(appID) { close() }
        }
        serverSubscription = self.gameServer?.$snapshot.sink { [weak self] snapshot in
            guard let self else { return }
            lock.lock(); defer { lock.unlock() }
            guard currentLocked(), serverRequested, serviceGeneration == serverGeneration else { return }
            serverID = snapshot.steamID
            serverLoggedOn = snapshot.loggedOn
            serverSecure = snapshot.secure.map { $0 ? 1 : 0 } ?? -1
            serverPublicIP = snapshot.publicIPv4
        }
        self.gameServer?.eventsDidChange = { [weak self] in
            guard let self, let gameServer = self.gameServer else { return }
            let events = gameServer.drainEvents()
            lock.lock(); defer { lock.unlock() }
            guard currentLocked(), serverRequested, serviceGeneration == serverGeneration else { return }
            for event in events {
                if serverEvents.count >= 128 { serverEvents.removeFirst() }
                var copy = BO2SteamServerEvent()
                copy.callbackID = event.callbackID; copy.result = event.result
                copy.secure = event.secure == true ? 1 : 0
                serverEvents.append(copy)
            }
        }
    }

    private func currentLocked() -> Bool { valid && SteamSignIn.revision == revision }
    func steamID() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return currentLocked() ? account : 0
    }
    func ownsApp(_ app: UInt32) -> Bool { steamID() != 0 && owned.contains(app) }
    func dlcInstalled(_ app: UInt32) -> Bool { steamID() != 0 && installed.contains(app) }
    func vacStatus(_ app: UInt32) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard SteamSignIn.revision == revision else { return -1 }
        if bannedApps?.contains(app) == true { return 1 }
        return valid && bannedApps != nil ? 0 : -1
    }

    func initializeServer(_ config: BO2SteamServerConfig, version: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard currentLocked(), gameServer != nil, serverConfiguration == nil,
              config.serverMode == 3, config.gamePort != 0, !version.isEmpty else { return false }
        serverGeneration &+= 1
        serverRequested = false
        serverConfiguration = SteamGameServerService.Configuration(ip: config.ip, steamPort: config.steamPort,
            gamePort: config.gamePort, queryPort: config.queryPort, serverMode: config.serverMode,
            version: version, dedicated: false, gameDirectory: "")
        return true
    }

    func setDedicatedServer(_ dedicated: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard currentLocked(), !serverRequested else { return }
        serverConfiguration?.dedicated = dedicated
    }

    private func currentServer(_ epoch: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return currentLocked() && serverGeneration == epoch
    }

    private func activateServer(_ epoch: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard currentLocked(), serverGeneration == epoch else { return false }
        serviceGeneration = epoch
        return true
    }

    func logOnAnonymous() {
        lock.lock()
        guard currentLocked(), let config = serverConfiguration, let gameServer, !serverRequested else {
            lock.unlock(); return
        }
        serverRequested = true
        let epoch = serverGeneration
        lock.unlock()
        Task { @MainActor [self] in
            guard currentServer(epoch) else { return }
            // Every new server generation waits for the old connection to close.
            await gameServer.stop()
            guard activateServer(epoch) else { return }
            do { try await gameServer.start(config) }
            catch { /* The service preserves failure/disconnect events. */ }
        }
    }

    func serverSnapshot() -> (id: UInt64, loggedOn: Bool, secure: Int32, publicIP: UInt32) {
        lock.lock(); defer { lock.unlock() }
        guard currentLocked() else { return (0,false,-1,0) }
        return (serverID,serverLoggedOn,serverSecure,serverPublicIP)
    }

    func pollServerEvent(_ event: UnsafeMutablePointer<BO2SteamServerEvent>?) -> Int32 {
        guard let event else { return -1 }
        lock.lock(); defer { lock.unlock() }
        guard currentLocked() else { return -1 }
        guard !serverEvents.isEmpty else { return 0 }
        event.pointee = serverEvents.removeFirst()
        return 1
    }

    func shutdownServer() {
        lock.lock()
        serverGeneration &+= 1
        let epoch = serverGeneration
        serverConfiguration = nil; serverRequested = false
        serverID = 0; serverLoggedOn = false; serverSecure = -1; serverPublicIP = 0
        serverEvents.removeAll()
        lock.unlock()
        Task { @MainActor [self] in
            guard currentServer(epoch) else { return }
            await gameServer?.stop()
        }
    }

    func requestTicket(_ data: Data) -> UInt64 {
        lock.lock()
        guard tickets.count < 128 else { lock.unlock(); return 0 }
        sequence &+= 1
        let handle = sequence
        let current = currentLocked()
        tickets[handle] = current ? .pending : .finished(nil, 3)
        lock.unlock()
        guard current else { return handle }
        let task = Task { @MainActor [self] in
            do {
                try Task.checkCancellation()
                guard steamID() == account, services.session.steamID == account else { throw SteamError.disconnected }
                let bytes = try await services.authentication.requestEncryptedAppTicket(appID: appID, userData: data)
                complete(handle, data: bytes, result: 1)
            } catch { complete(handle, data: nil, result: Self.resultCode(error)) }
        }
        lock.lock()
        if case .pending? = tickets[handle], currentLocked() {
            tasks[handle] = task
            lock.unlock()
        } else {
            lock.unlock()
            task.cancel()
        }
        return handle
    }

    private static func resultCode(_ error: Error) -> UInt32 {
        switch error {
        case SteamError.serviceRefused(let result), SteamError.logonDenied(let result): return result
        case SteamError.connectionTimeout: return 16
        case SteamError.rateLimited: return 25
        case SteamError.disconnected, SteamError.invalidCredentials, is CancellationError: return 3
        default: return 2
        }
    }

    private func complete(_ handle: UInt64, data: Data?, result: UInt32) {
        lock.lock(); defer { lock.unlock() }
        guard case .pending? = tickets[handle] else { return }
        if !currentLocked() { tickets[handle] = .finished(nil, 3) }
        else if result == 1, let data, !data.isEmpty, data.count <= 64 * 1024 {
            tickets[handle] = .finished(data, 1)
        } else { tickets[handle] = .finished(nil, result == 0 || result == 1 ? 2 : result) }
        tasks.removeValue(forKey: handle)
    }

    func poll(_ handle: UInt64, destination: UnsafeMutableRawPointer?, capacity: UInt32,
              required: UnsafeMutablePointer<UInt32>?, result: UnsafeMutablePointer<UInt32>?) -> Int32 {
        required?.pointee = 0; result?.pointee = 8
        guard let required, let result else { return -1 }
        lock.lock(); defer { lock.unlock() }
        guard currentLocked() else { result.pointee = 3; return -1 }
        guard let ticket = tickets[handle] else { return -1 }
        switch ticket {
        case .pending: result.pointee = 0; return 0
        case .finished(let data, let status):
            result.pointee = status
            guard status == 1, let data else { return -1 }
            required.pointee = UInt32(data.count)
            guard capacity >= data.count, let destination else { return -2 }
            data.withUnsafeBytes { bytes in destination.copyMemory(from: bytes.baseAddress!, byteCount: data.count) }
            return 1
        }
    }

    func releaseTicket(_ handle: UInt64) {
        lock.lock()
        tickets.removeValue(forKey: handle)
        let task = tasks.removeValue(forKey: handle)
        lock.unlock()
        task?.cancel()
    }

    func close() {
        lock.lock()
        guard valid else { lock.unlock(); return }
        valid = false
        serverGeneration &+= 1
        serverConfiguration = nil; serverRequested = false
        serverID = 0; serverLoggedOn = false; serverSecure = -1; serverPublicIP = 0
        serverEvents.removeAll()
        tickets = tickets.mapValues { _ in .finished(nil, 3) }
        let cancelled = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        for task in cancelled { task.cancel() }
        Task { @MainActor [gameServer] in await gameServer?.stop() }
    }

    func makeProvider() -> BO2SteamProviderV1 {
        var provider = BO2SteamProviderV1()
        provider.version = UInt32(BO2_STEAM_PROVIDER_VERSION)
        provider.structSize = UInt32(MemoryLayout<BO2SteamProviderV1>.size)
        provider.context = Unmanaged.passUnretained(self).toOpaque()
        provider.steamID = bo2_launcher_steam_id
        provider.isLoggedOn = bo2_launcher_steam_logged_on
        provider.ownsApp = bo2_launcher_steam_owns
        provider.dlcInstalled = bo2_launcher_steam_dlc
        provider.requestEncryptedTicket = bo2_launcher_request_ticket
        provider.pollEncryptedTicket = bo2_launcher_poll_ticket
        provider.releaseTicket = bo2_launcher_release_ticket
        provider.vacStatus = bo2_launcher_vac_status
        if gameServer != nil {
            provider.initGameServer = bo2_launcher_server_init
            provider.setDedicatedServer = bo2_launcher_server_dedicated
            provider.logOnAnonymous = bo2_launcher_server_logon
            provider.gameServerSteamID = bo2_launcher_server_id
            provider.gameServerLoggedOn = bo2_launcher_server_logged_on
            provider.gameServerSecure = bo2_launcher_server_secure
            provider.pollGameServerEvent = bo2_launcher_server_event
            provider.shutdownGameServer = bo2_launcher_server_shutdown
            provider.gameServerPublicIP = bo2_launcher_server_public_ip
        }
        return provider
    }
}

private func steamRuntime(_ pointer: UnsafeMutableRawPointer?) -> BO2SteamRuntimeContext? {
    pointer.map { Unmanaged<BO2SteamRuntimeContext>.fromOpaque($0).takeUnretainedValue() }
}

@_cdecl("bo2_launcher_steam_id")
func bo2_launcher_steam_id(_ context: UnsafeMutableRawPointer?) -> UInt64 { steamRuntime(context)?.steamID() ?? 0 }
@_cdecl("bo2_launcher_steam_logged_on")
func bo2_launcher_steam_logged_on(_ context: UnsafeMutableRawPointer?) -> Bool { bo2_launcher_steam_id(context) != 0 }
@_cdecl("bo2_launcher_steam_owns")
func bo2_launcher_steam_owns(_ context: UnsafeMutableRawPointer?, _ appID: UInt32) -> Bool { steamRuntime(context)?.ownsApp(appID) ?? false }
@_cdecl("bo2_launcher_steam_dlc")
func bo2_launcher_steam_dlc(_ context: UnsafeMutableRawPointer?, _ appID: UInt32) -> Bool { steamRuntime(context)?.dlcInstalled(appID) ?? false }
@_cdecl("bo2_launcher_vac_status")
func bo2_launcher_vac_status(_ context: UnsafeMutableRawPointer?, _ appID: UInt32) -> Int32 { steamRuntime(context)?.vacStatus(appID) ?? -1 }
@_cdecl("bo2_launcher_request_ticket")
func bo2_launcher_request_ticket(_ context: UnsafeMutableRawPointer?, _ data: UnsafeRawPointer?, _ size: UInt32) -> UInt64 {
    guard let runtime = steamRuntime(context), size <= 64 * 1024, size == 0 || data != nil else { return 0 }
    let copy = size == 0 ? Data() : Data(bytes: data!, count: Int(size))
    return runtime.requestTicket(copy)
}
@_cdecl("bo2_launcher_poll_ticket")
func bo2_launcher_poll_ticket(_ context: UnsafeMutableRawPointer?, _ handle: UInt64,
    _ destination: UnsafeMutableRawPointer?, _ capacity: UInt32,
    _ required: UnsafeMutablePointer<UInt32>?, _ result: UnsafeMutablePointer<UInt32>?) -> Int32 {
    guard let runtime = steamRuntime(context) else { required?.pointee = 0; result?.pointee = 3; return -1 }
    return runtime.poll(handle, destination: destination, capacity: capacity, required: required, result: result)
}
@_cdecl("bo2_launcher_release_ticket")
func bo2_launcher_release_ticket(_ context: UnsafeMutableRawPointer?, _ handle: UInt64) { steamRuntime(context)?.releaseTicket(handle) }

@_cdecl("bo2_launcher_server_init")
func bo2_launcher_server_init(_ context: UnsafeMutableRawPointer?, _ configuration: UnsafePointer<BO2SteamServerConfig>?) -> Bool {
    guard let runtime = steamRuntime(context), let configuration else { return false }
    let config = configuration.pointee
    guard config.versionSize > 0, config.versionSize <= 128, let bytes = config.version,
          let version = String(data: Data(bytes: bytes, count: Int(config.versionSize)), encoding: .utf8),
          !version.contains("\0") else { return false }
    return runtime.initializeServer(config, version: version)
}
@_cdecl("bo2_launcher_server_dedicated")
func bo2_launcher_server_dedicated(_ context: UnsafeMutableRawPointer?, _ dedicated: Bool) { steamRuntime(context)?.setDedicatedServer(dedicated) }
@_cdecl("bo2_launcher_server_logon")
func bo2_launcher_server_logon(_ context: UnsafeMutableRawPointer?) { steamRuntime(context)?.logOnAnonymous() }
@_cdecl("bo2_launcher_server_id")
func bo2_launcher_server_id(_ context: UnsafeMutableRawPointer?) -> UInt64 { steamRuntime(context)?.serverSnapshot().id ?? 0 }
@_cdecl("bo2_launcher_server_logged_on")
func bo2_launcher_server_logged_on(_ context: UnsafeMutableRawPointer?) -> Bool { steamRuntime(context)?.serverSnapshot().loggedOn ?? false }
@_cdecl("bo2_launcher_server_secure")
func bo2_launcher_server_secure(_ context: UnsafeMutableRawPointer?) -> Int32 { steamRuntime(context)?.serverSnapshot().secure ?? -1 }
@_cdecl("bo2_launcher_server_event")
func bo2_launcher_server_event(_ context: UnsafeMutableRawPointer?, _ event: UnsafeMutablePointer<BO2SteamServerEvent>?) -> Int32 { steamRuntime(context)?.pollServerEvent(event) ?? -1 }
@_cdecl("bo2_launcher_server_shutdown")
func bo2_launcher_server_shutdown(_ context: UnsafeMutableRawPointer?) { steamRuntime(context)?.shutdownServer() }
@_cdecl("bo2_launcher_server_public_ip")
func bo2_launcher_server_public_ip(_ context: UnsafeMutableRawPointer?) -> UInt32 { steamRuntime(context)?.serverSnapshot().publicIP ?? 0 }
