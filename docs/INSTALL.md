# Install and play

This guide is for someone setting the port up on their own iPhone. It covers what you need, how to build and install the app, and how to play.

## Quick start

This is the shortest path: an app without the game files inside, which downloads them from Steam on the phone. Every command is run in Terminal on the Mac. The sections after this one explain each part and the other options.

**1. Install the build tools.** Install Xcode from the App Store and open it once so it installs the iPhone platform. Install [Homebrew](https://brew.sh), then:

```sh
brew install xcodegen cmake python@3.12
```

**2. Install bo2-mac's app, version `v0.2.0-test.4`.** Follow [bo2-mac's README](https://github.com/adrbn/bo2-mac#install) so that `Black Ops II.app` is in `/Applications`. This build uses the translation tools inside that app. Check that they are there:

```sh
ls "/Applications/Black Ops II.app/Contents/Resources/toolchain/llvm@17"
```

**3. Put your three unpacked executables in place.** The build reads these three files, made from your own Steam copy:

```
~/.bo2-native/steam/t6sp.exe.unpacked.exe
~/.bo2-native/steam/t6mp.exe.unpacked.exe
~/.bo2-native/steam/t6zm.exe.unpacked.exe
```

[bo2-mac's README](https://github.com/adrbn/bo2-mac#install) says what they are. Neither project provides a tool to make them. Each file is checked by SHA-256, so a wrong file is refused straight away. Never share them.

**4. Get this repository.**

```sh
git clone https://github.com/Alextechgamer/bo2-ios.git
```

```sh
cd bo2-ios
```

**5. Check that everything is in place.** `~/bo2-ios-build` is the folder the build works in; any folder on a disk with 30 GB free will do. The check takes a few seconds and names the first thing that is missing.

```sh
ios/setup.sh ~/bo2-ios-build check
```

**6. Build.** Replace `com.yourname.bo2` with a bundle identifier of your own.

```sh
BUNDLE_ID=com.yourname.bo2 ios/setup.sh ~/bo2-ios-build
```

This translates the game, compiles it and packages the app. It is a long build: plan for an hour or more, and leave the Mac awake and plugged in. If it stops, run the same command again and it carries on from where it was. When it ends it prints:

```
IPA: /Users/<you>/bo2-ios-build/out/BlackOpsII.ipa
```

**7. Sign and install the IPA.** The IPA from step 6 is unsigned. Either:

- sign and install it with SideStore or a signing service, or
- build it signed with your own Apple team instead, by adding `TEAM=<your team id>` in front of the command in step 6 (the team id is in Xcode → Settings → Accounts, or on your Apple Developer membership page), then drag the IPA onto your phone in Xcode → Window → Devices and Simulators.

A free Apple ID works, but the app stops opening after 7 days and must be installed again.

**8. On the phone.** Open the app, tap **Sign in to Steam**, then tap **Game Files** and let it download your game (well over 10 GB; stay on Wi-Fi and power). When it says **Game files installed**, pick a mode.

Read [Before you play online](#before-you-play-online) first.

### If the build stops

The setup prints one line starting with `setup:` that says what went wrong.

| Message | What to do |
|---|---|
| `xcodegen is not installed`, `cmake is not installed` | Run the `brew install` line in step 1. |
| `Xcode with the iPhone SDK is not installed` | Open Xcode once and let it install the iOS platform, then run `sudo xcode-select -s /Applications/Xcode.app`. |
| `bo2-mac's tools were not found` | Step 2. If the app is somewhere else, add `BO2MAC_APP="/path/to/Black Ops II.app"` in front of the command. |
| `t6sp.exe.unpacked.exe is missing` (or `t6mp`, `t6zm`) | Step 3. If they are in another folder, add `BO2_INPUTS=/path/to/folder` in front of the command. |
| `has N GB free; 30 is asked for` | Free some space, or use a work folder on another disk. |
| `libvpx did not build`, `Unicorn did not build`, `did not link` | The message names a log file. Open it; the last lines say why. |
| `some slices did not compile` | Run the same command again. If it repeats, the `.FAILED` files in the folder it names hold the compiler's messages. |
| `set BUNDLE_ID for the package stage` | Add `BUNDLE_ID=com.yourname.bo2` in front of the command. |

## Without a Mac

**A full build has not been run this way yet.** Only the test mode has: on November 15, 2026 it passed in six minutes on GitHub's Mac (macOS 15.8, Xcode 16.4, 3 cores, 7 GB of memory, 98 GB of disk free after clean-up). That covers the tools download, the source patches and the two libraries. Translating, compiling, linking and packaging the game there are untested, and so is the resulting app. Treat it as experimental.

GitHub rents out Apple silicon Macs by the minute for automated builds. The workflow in [.github/workflows/build-ipa.yml](../.github/workflows/build-ipa.yml) runs the quick start's build on one of them and hands you the unsigned IPA, which you then sign and install from Windows or Linux.

Know these three things before you start:

- **It must be a private repository.** In a public repository, and a fork of this one is always public, other people can download what a build produces. That would publish an app containing your game's code. The workflow refuses to build in a public repository.
- **It is probably not free.** GitHub gives a free personal account about $12 of build time a month for private repositories, and its Macs cost about $0.06 a minute, so roughly three hours. The build may take longer than that on GitHub's three-core Macs; it has not been timed. Past the free amount GitHub stops the build unless you have set a spending limit and a payment method.
- **Your three executables go onto GitHub's servers**, in your own private repository. Delete them afterwards.

Steps:

1. On GitHub, choose **+** → **Import repository**, give it `https://github.com/Alextechgamer/bo2-ios` as the source, and set the new repository to **Private**. Do not use Fork.
2. In your private repository, open **Releases** → **Draft a new release**. Type `inputs` as the tag, attach your three files (`t6sp.exe.unpacked.exe`, `t6mp.exe.unpacked.exe`, `t6zm.exe.unpacked.exe`) and publish it. The release is only visible to you because the repository is private.
3. Open **Actions** → **Build IPA** → **Run workflow**. Enter a bundle identifier of your own and start it. To test the machine first without any game files, tick **preflight**; that takes a few minutes.
4. When the run finishes, download **BlackOpsII-unsigned** from the run's page. It is kept for one day.
5. Delete the `inputs` release and the downloaded artifact from the repository.
6. Sign and install the IPA with SideStore, Sideloadly or a signing service, then carry on from step 8 of the quick start.

If a build fails, the run's page says which stage stopped, and a **build-logs** download holds the detailed logs. A job is cut off after six hours.

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

This is the fuller version of the quick start, with the optional ownership receipt. Here `$PRIVATE` is a private folder of your own outside this repository, `$WORK` is the build folder (`~/bo2-ios-build` in the quick start) and `$DEVICE_ID` is your phone's identifier from `xcrun devicectl list devices`.

1. Optional. With the owning Steam account signed in to Steam on the Mac, create the ownership receipt. It lets local modes start without a Steam sign-in on the phone:

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
   - **No receipt:** leave `RECEIPT` out and skip step 1. The app then holds no account, and every mode, local play included, starts on the Steam account signed in on the phone. This is the quick start's build; it was run on the test phone on November 11, 2026, signed with a signing service.
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

Not checked: the Steam download itself (no manifest or file has been fetched with it yet; the download code is iDeck's, adapted to this app's folders, and iDeck's offline test of it has not been ported), Zombies online with Steam, an online session or a private-server join with frameworks linked by the setup, the Hksc download and build in `deps` (the link used a copy built earlier from the same commit), the signed (`TEAM`) and `GAME_ZIP` paths of the packager since they were changed, a full run for all three modes from nothing, a run on a second Mac, the unsigned IPA after SideStore or a signing service has signed it, and the result on a phone.

Since then, on the test phone (owner's report, November 11, 2026): the unsigned IPA without a receipt was signed with a signing service and installed, Steam sign-in worked, **Game Files** downloaded the game, and online Multiplayer was played. This supersedes the entries above for the Steam download, the re-signed unsigned IPA and the result on a phone.

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
2. Tap **Game Files**. The app asks Steam for the Campaign, Multiplayer and Zombies files your account owns and downloads them from Steam's content servers into its own storage: the base game in English, without DLC. Allow well over 10 GB; the size has not been measured. The line under the cards shows the mode, the percentage and the speed.
3. Keep the app open and the phone on Wi-Fi and power. Tapping **Game Files** again pauses; so does leaving the app. Tap it once more to carry on: finished parts are kept and checked, not downloaded again.
4. When it says **Game files installed**, pick a mode.

Steam only hands the files to an account that owns the game. Nothing is downloaded from anywhere else, and the files are stored as Steam delivers them. Tapping **Game Files** on an app that already has downloaded files asks first, then checks them against Steam and replaces any file that differs.

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
