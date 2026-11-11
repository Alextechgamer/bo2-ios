// SPDX-License-Identifier: GPL-3.0-or-later
#if canImport(UIKit)
import SwiftUI

struct BO2SteamLibraryView: View {
    @ObservedObject var services: BO2SteamServices
    let selected: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var availability: [UInt32: BO2RuntimeCatalog.Availability] = [:]
    @State private var checking = false
    @State private var search = ""

    private var snapshot: BO2SteamLibrarySnapshot? {
        guard let snapshot = services.state.snapshot,
              snapshot.steamID == services.authenticatedSteamID else { return nil }
        return snapshot
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Play supported games from your Steam library. Official online play is not verified yet.")
                        .foregroundStyle(.secondary)
                    status
                }
                if let snapshot {
                    ForEach(snapshot.apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }, id: \.appID) { app in
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(app.name.isEmpty ? "Steam app \(app.appID)" : app.name)
                                Text(availability[app.appID]?.message ??
                                     (BO2RuntimeCatalog.mode(appID: app.appID) == nil ?
                                      "Runtime unavailable for this game" : "Checking installed files…"))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if case .ready(let mode) = availability[app.appID] {
                                Button("Play") { selected(mode) }.disabled(checking)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Steam library")
            .searchable(text: $search, prompt: "Search owned games")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh") { Task { await services.refreshOwnedLibrary() } }
                }
            }
            .task { await services.refreshOwnedLibrary() }
            .task(id: services.authenticatedSteamID) { await checkRuntimes() }
            .onDisappear { services.cancelLibraryRefresh() }
        }
    }

    @ViewBuilder private var status: some View {
        switch services.state {
        case .signedOut: Text("Sign in to Steam to see your games.")
        case .refreshing:
            HStack { ProgressView(); Text("Updating your library…"); Spacer()
                Button("Cancel") { services.cancelLibraryRefresh() } }
        case .failed(let message, _): Text(message).foregroundStyle(.secondary)
        case .ready(let snapshot): Text("\(snapshot.apps.count) owned games and apps")
        }
    }

    private func checkRuntimes() async {
        availability = [:]
        checking = true
        defer { checking = false }
        let root = Bundle.main.bundleURL
        let bundledGame = root.appendingPathComponent("Game")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let bundled = FileManager.default.fileExists(atPath: bundledGame.path)
        let game = bundled ? bundledGame : support?.appendingPathComponent("BO2GameFiles")
        let worker = Task.detached(priority: .utility) {
            let catalog = BO2RuntimeCatalog(bundleRoot: root)
            var result: [UInt32: BO2RuntimeCatalog.Availability] = [:]
            for appID in [UInt32(202970), 202990, 212910] {
                try Task.checkCancellation()
                do { result[appID] = try catalog.check(appID: appID, bundleRoot: root, gameRoot: game, downloaded: !bundled) }
                catch is CancellationError { throw CancellationError() }
                catch { result[appID] = .unavailable("Installed files could not be verified") }
            }
            return result
        }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            availability = result
        } catch { }
    }
}
#endif
