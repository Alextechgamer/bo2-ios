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
}
