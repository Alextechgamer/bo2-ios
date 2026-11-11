# Install and play

This guide is for someone setting the port up on their own iPhone. It covers what you need, how to build and install the app, and how to play.

## What you need

| Item | Notes |
|---|---|
| A Steam account that owns Black Ops II | Campaign is app 202970, Multiplayer 202990, Zombies 212910. |
| Your own copy of the game files | Downloaded inside the app from Steam with your account (**Game Files**), or installed through Steam on a PC and zipped with the game files at the archive root. |
| An Apple silicon Mac with Xcode, XcodeGen, CMake and Python 3.11 or later | The game's code is translated and the app is built on the Mac. Allow about 30 GB of free disk. |
| [bo2-mac](https://github.com/adrbn/bo2-mac)'s `Black Ops II.app` | It carries the translation tools this build uses. |
| Your three unpacked executables in `~/.bo2-native/steam/` | bo2-mac's README explains what they are. They are checked by SHA-256. Never share them. |
| A way to sign the app | Your own Apple team in Xcode, or SideStore or a signing service for the unsigned IPA. A free Apple ID works, but the app then expires after 7 days. |
| An iPhone on iOS 16 or later | Tested on an iPhone 17 Pro Max only. The game data needs several gigabytes free. |

There is no ready-made IPA and there cannot be one: the app contains the game's code, translated from your own copy, and an IPA signed for one person's devices does not install on another's.

## Build and install

1. With the owning Steam account signed in on the Mac, create the ownership receipt:

   ```sh
   python3 ios/steam_receipt.py "$PRIVATE/SteamOwnership.plist"
   ```

2. Run the setup. It translates the three executables, builds a framework for each mode and packages the app. It is a long build (Zombies alone took about 20 minutes on the test Mac); if it stops, run the same command again and it carries on.

   ```sh
   RECEIPT="$PRIVATE/SteamOwnership.plist" BUNDLE_ID=com.example.bo2 ios/setup.sh "$WORK"
   ```

   - **Signed with Xcode:** add `TEAM=<your team id>`. The IPA installs on devices registered to that team.
   - **Unsigned:** leave `TEAM` out, then sign `$WORK/out/BlackOpsII.ipa` with SideStore or a signing service.
   - **Game files inside the app:** add `GAME_ZIP=<zip of your game folder>`. The IPA is then about 16 GB, too large for most signing tools.
   - **Online play:** the Steam network transport is linked into Multiplayer and Zombies by default, and the launcher offers online play for both. `ONLINE=0` leaves it out.
   - **Private servers:** linked into Zombies by default. Multiplayer also needs `PLUTO_LUA_ZIP=<zip>`, your own capture of the nine interface scripts an r5369 server sends; without it Multiplayer is built without the private-server transport and the setup says so. `PRIVATE_SERVER=0` leaves it out of both.
   - **Game files downloaded afterwards:** without `GAME_ZIP` the app starts with no game files and says so. Sign in to Steam in the app and tap **Game Files**; see [Download the game files](#download-the-game-files). The private library installer in [PRIVATE-SERVERS.md](PRIVATE-SERVERS.md) is still there: pass its address as `LIBRARY_ORIGIN=<https origin>` and **Game Files** offers both.

   To run one stage at a time, name it: `ios/setup.sh "$WORK" check`, then `source`, `deps`, `convert`, `fold`, `link`, `package`.

3. Install a signed IPA from Xcode (Window → Devices and Simulators → drag the IPA onto the phone), or with:

   ```sh
   xcrun devicectl device install app --device "$DEVICE_ID" "$WORK/out/BlackOpsII.ipa"
   ```

4. On the phone, trust the developer profile under Settings → General → VPN & Device Management, then open the app.

### What the setup does not build yet

- **Multiplayer on private servers, unless you supply the scripts.** That link compiles nine interface scripts captured from an r5369 server. They are not in this repository and the setup checks the ones you supply by hash. Without them **Join Private Server** does not work for Multiplayer. Zombies needs nothing extra.
- **A build with `ONLINE=0`** stops with "Game networking requires an active Steam session." when **Play Online with Steam** is picked.
- **A mode built without the private-server transport** reports that its `pluto_pe_sections.bin` file is missing when a private server is joined in that mode.
- **Multiplayer with online play but no private-server transport**, the default without the scripts, is a combination that has not been played on a phone. The tested phone build had both.
- **Precompiled shaders.** The app compiles shaders as they are first used.
- **Signing by someone else changes the frameworks.** After SideStore or a signing service re-signs the app, the Steam library screen reports "Runtime files do not match this build". The mode cards on the first screen do not use that check.

### How far this has been checked

On one Apple silicon Mac mini with Xcode 26, November 11, 2026:

- `check`, `source`, `deps`, `link` and `package` ran for all three modes and produced an unsigned IPA without the game files.
- `link` ran three ways: Multiplayer with online only, Multiplayer with online and private servers, and Zombies with both. The Multiplayer and Zombies frameworks export the same entry points as the build that was played online and on private servers on the test phone, apart from that build's older touch-control classes, and their private-server memory images are identical to that build's.
- `convert` and `fold` ran from nothing for Zombies only: about 10 minutes to translate and 9 minutes to compile. Campaign and Multiplayer reused a translation made earlier with the same tools.
- The three frameworks were started in the iPhone simulator: Zombies and Multiplayer reached their main menus and Campaign played its opening video.
- The launcher with the Steam download compiled for the phone and the simulator and was packaged. In the simulator, without a signed-in account, **Game Files** answered "Sign in to Steam first".

- The tools were bo2-mac's app at `218dc80`, the same commit the setup pins the source to. The finished build folder was about 10 GB; the peak during the build was not measured.

Not checked: the Steam download itself (no manifest or file has been fetched with it yet; the download code is iDeck's, adapted to this app's folders), Zombies online with Steam, an online session or a private-server join with frameworks linked by the setup, the Hksc download and build in `deps` (the link used a copy built earlier from the same commit), the signed (`TEAM`) and `GAME_ZIP` paths of the packager since they were changed, a full run for all three modes from nothing, a run on a second Mac, the unsigned IPA after SideStore or a signing service has signed it, and the result on a phone.

Installing over an existing copy keeps its game data and saves. Deleting the app removes them.

## First launch

1. Tap **Sign in to Steam** at the top right. Use your Steam account name and password, or the QR code with the Steam app. Approve the Steam Guard prompt.
2. The button changes to **Steam · Signed in**. The session is stored in the app's own Keychain entry on this phone. Tap it again to sign out.
3. Pick a mode:
   - **Campaign** and **Zombies** start locally.
   - **Multiplayer** asks for **Play Online with Steam** or **Play Local**.
   - **Join Private Server** connects to a LAN-mode server by address. See [PRIVATE-SERVERS.md](PRIVATE-SERVERS.md) for hosting one.

## Download the game files

If the app was built without `GAME_ZIP`, it has no game files yet.

1. Sign in to Steam (above).
2. Tap **Game Files**. The app asks Steam for the Campaign, Multiplayer and Zombies files your account owns and downloads them from Steam's content servers into its own storage: about 16 GB, English only. The line under the cards shows the mode, the percentage and the speed.
3. Keep the app open and the phone on Wi-Fi and power. Tapping **Game Files** again pauses; so does leaving the app. Tap it once more to carry on: finished parts are kept and checked, not downloaded again.
4. When it says **Game files installed**, pick a mode.

Steam only hands the files to an account that owns the game. Nothing is downloaded from anywhere else, and the files are stored as Steam delivers them. Tapping **Game Files** on an app that already has downloaded files checks them against Steam and repairs any part that differs.

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
