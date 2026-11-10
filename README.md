# BO2 iOS launcher source

This repository contains the UIKit launcher, Metal surface, touch controls, private server transport, and local packaging tools for an iOS adaptation of Black Ops II. Running the game requires a separately acquired licensed game installation, translated iOS mode frameworks, and their matching guest sections. Building the transport also requires the runtime shim headers, hook definitions and, for Multiplayer, a privately generated script index and bytecode.

## Build a personal package

Use macOS with Xcode, XcodeGen, Python 3.11 or later and an Apple development signing identity. Keep private inputs and build outputs in a separate directory.

1. Put each translated framework under `device/<mode>/<mode>.framework` in your build directory, and the associated `pe_sections.bin` under `conversion/boot_cache/<mode>/`. The mode names are `sps`, `mps` and `zms`.
2. Supply a ZIP of your own installation with the game files at the archive root. With the owning Steam account signed in on the Mac, run `python3 ios/steam_receipt.py "$PRIVATE/SteamOwnership.plist"` to generate the private ownership receipt.
3. Use the packaging command below with your build directory, archive, desired output and temporary work directory. Supply your own bundle identifier and development team. The script signs the app locally.

```sh
python3 ios/package_game.py "$BUILD" "$GAME_ZIP" "$OUTPUT_IPA" "$WORK" \
  --team "$DEVELOPMENT_TEAM" --bundle-id "$BUNDLE_ID" \
  --receipt "$PRIVATE/SteamOwnership.plist"
```

For **Join Private Server**, also pass `--lan-root "$LAN_BUILD"`. Under each of `mps/` and `zms/`, provide the LAN-capable mode framework and its `pluto_pe_sections.bin`. The launcher checks the address entered on the phone with a UDP challenge before starting the selected mode.

## Optional installation service

Stage only game files in a private directory named `steam-library`, next to the ownership receipt. Run the following commands to index the files and start the owner-restricted service.

```sh
python3 ios/index_library.py "$PRIVATE/steam-library" "$PRIVATE/steam-index.json"
python3 ios/steam_install_server.py "$PRIVATE" "$TAILNET_HTTPS_ORIGIN" --port 8080
```

Expose the loopback service through the supplied tailnet HTTPS origin and pass the same origin to the packager with `--library-origin`. The service validates Steam OpenID sign-in against the account in the private receipt. The phone verifies each downloaded file against the supplied manifest.

The Metal library compiler takes separately provided shader source files. The archive assembler takes a locally signed application shell and a private game ZIP, then verifies each file against the app's resource seal. Each tool accepts `--help`.

The Git allowlist covers only the source files and this README. Keep account receipts, signing material, server addresses, private libraries, compiled frameworks, archives and device reports outside the repository.
