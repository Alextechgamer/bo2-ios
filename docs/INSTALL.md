# Install and play

This guide is for someone setting the port up on their own iPhone. It covers what you need, how to build and install the app, and how to play.

## What you need

| Item | Notes |
|---|---|
| A Steam account that owns Black Ops II | Campaign is app 202970, Multiplayer 202990, Zombies 212910. |
| Your own copy of the game files | Installed through Steam on a PC or Mac, then zipped with the game files at the archive root. |
| A Mac with Xcode, XcodeGen and Python 3.11 or later | The app is built and signed on the Mac. |
| An Apple developer signing identity | A free Apple ID works, but the app then expires after 7 days and must be reinstalled. |
| An iPhone on iOS 16 or later | Tested on an iPhone 17 Pro Max only. The game data needs several gigabytes free. |
| The translated mode frameworks and guest sections | **Not in this repository.** They are produced from your own game executables by a separate conversion toolchain and cannot be shared, because they contain the game's code. |

The last row is the hard one. Without the three frameworks (`sps`, `mps`, `zms`) and their `pe_sections.bin` files, the launcher builds but has nothing to run.

## Build and install

1. Put each framework under `device/<mode>/<mode>.framework` in a private build directory, and each `pe_sections.bin` under `conversion/boot_cache/<mode>/`.
2. With the owning Steam account signed in on the Mac, create the ownership receipt:

   ```sh
   python3 ios/steam_receipt.py "$PRIVATE/SteamOwnership.plist"
   ```

3. Build and sign the app with your own team and bundle identifier:

   ```sh
   python3 ios/package_game.py "$BUILD" "$GAME_ZIP" "$OUTPUT_IPA" "$WORK" \
     --team "$DEVELOPMENT_TEAM" --bundle-id "$BUNDLE_ID" \
     --receipt "$PRIVATE/SteamOwnership.plist"
   ```

4. Install the IPA on the phone from Xcode (Window → Devices and Simulators → drag the IPA onto the phone), or with:

   ```sh
   xcrun devicectl device install app --device "$DEVICE_ID" "$OUTPUT_IPA"
   ```

5. On the phone, trust the developer profile under Settings → General → VPN & Device Management, then open the app.

Installing over an existing copy keeps its game data and saves. Deleting the app removes them.

## First launch

1. Tap **Sign in to Steam** at the top right. Use your Steam account name and password, or the QR code with the Steam app. Approve the Steam Guard prompt.
2. The button changes to **Steam · Signed in**. The session is stored in the app's own Keychain entry on this phone. Tap it again to sign out.
3. Pick a mode:
   - **Campaign** and **Zombies** start locally.
   - **Multiplayer** asks for **Play Online with Steam** or **Play Local**.
   - **Join Private Server** connects to a LAN-mode server by address. See [PRIVATE-SERVERS.md](PRIVATE-SERVERS.md) for hosting one.

**Game Files** opens the private library installer described in [PRIVATE-SERVERS.md](PRIVATE-SERVERS.md). Downloading the game straight from Steam inside the app is not implemented yet; the game files come from the package or from that installer.

## Controls

The game starts in **Menu**, where a tap is a mouse click. When a Multiplayer or Zombies match starts, the on-screen controls appear by themselves. The small button at the top left switches between **Menu** and **Controls** by hand; Campaign always needs that.

| Control | Action |
|---|---|
| Left side of the screen | Move stick, appears under the thumb. Push fully forward to sprint. |
| Right side of the screen | Swipe to look. |
| FIRE, ADS | Shoot and aim. A swipe that starts on either keeps turning the view. |
| JUMP, CROUCH, RELOAD, SWAP, KNIFE, FRAG, TAC | As labelled. RELOAD is also Use. |
| II, SCORE | Pause menu and scoreboard. |
| Arrows | Scorestreaks, and moving through in-match menus. JUMP confirms. |
| Gear | Look method and speed, ADS **Hold** or **Tap**, **Edit layout**, **Reset layout**. |

**Swipe** look is the default: the view follows your finger the way it follows a mouse. **Stick** turns at a speed set by how fast you swipe. With ADS set to **Tap**, one tap aims and the next stops. **Edit layout** lets you drag any pad anywhere and resize the selected one with the slider; tap **Done** to save. A hardware controller works at the same time as the touch controls.

## If something goes wrong

- **No sound:** raise the volume and check the ring switch. The app asks iOS to play through the silent switch; this has not been confirmed on a phone yet.
- **The app closes during a match:** reopen it. The first screen says so, and the log of that session is kept in the app's Caches folder as `last-run.log` (`previous-run.log` for the one before). Copy it off with Xcode's Devices window → the app → Download Container.
- **"Game networking requires an active Steam session":** sign in again, then retry.
- **The app will not open after a week:** the signing profile expired. Rebuild and install over the top.

## Before you play online

This is an unofficial client using your real Steam account on the official servers. It cannot run Steam's anti-cheat modules; if the service asks for one, the app stops the session rather than answering. Whether using it puts an account at risk is unknown. Use it with that in mind.
