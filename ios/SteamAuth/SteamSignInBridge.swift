// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 BO2 iOS contributors
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
// BO2 UIKit integration for the iDeck Steam sign-in module.

import SwiftUI
import UIKit

@MainActor
@objc(BO2SteamSignIn)
final class BO2SteamSignIn: NSObject {
    @objc(presentFromViewController:)
    static func present(fromViewController presenter: UIViewController) {
        guard presenter.presentedViewController == nil else { return }
        let controller = UIHostingController(rootView: SteamSignInView())
        controller.modalPresentationStyle = .formSheet
        presenter.present(controller, animated: true)
    }

    @objc static func accountName() -> String? {
        SteamSignIn.accountName
    }

    @objc(presentLibraryFromViewController:)
    static func presentLibrary(fromViewController presenter: UIViewController) {
        guard presenter.presentedViewController == nil else { return }
        let view = BO2SteamLibraryView(services: .shared) { [weak presenter] mode in
            guard ["sps", "mps", "zms"].contains(mode) else { return }
            presenter?.dismiss(animated: true) {
                NotificationCenter.default.post(name: Notification.Name("BO2SteamLibraryPlay"),
                    object: nil, userInfo: ["mode": mode])
            }
        }
        let controller = UIHostingController(rootView: view)
        controller.modalPresentationStyle = .formSheet
        presenter.present(controller, animated: true)
    }
}
