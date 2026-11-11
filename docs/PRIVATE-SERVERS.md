# Private servers, relays and verification

This page covers joining and hosting LAN-mode matches, the Mac relay, the USB fallback, the offline match verifiers and the optional installation service. For installing and playing, see [INSTALL.md](INSTALL.md).

## Join a private server

Package the app with `--lan-root "$LAN_BUILD"`. Under each of `mps/` and `zms/`, provide the LAN-capable mode framework and its `pluto_pe_sections.bin`. In the launcher choose **Join Private Server**, pick the mode and enter the server's IPv4 address and port. The launcher checks the server's challenge response, protocol, session mode and active-match flag before it starts the game. Choose your team and class in the game's own menus.

## Host a private match

On Windows, supply a private installation directory containing `Plutonium/bin/plutonium-bootstrapper-win32.exe`, the r5369 runtime and storage files, and your licensed installation under `game/`. These commands each start a dedicated process and print its PID. Supply the Windows host's LAN IPv4 address in `$env:SERVER_LAN_IP`.

```powershell
py -3 lan/serve_private.py aftermath $env:SERVER_LAN_IP --root $env:PRIVATE_INSTALL
py -3 lan/serve_private.py tranzit $env:SERVER_LAN_IP --root $env:PRIVATE_INSTALL
```

Aftermath uses UDP port 24985 and TranZit uses UDP port 24988. Permit incoming traffic on the selected ports from the players' local network. In **Join Private Server**, choose the matching mode and enter the Windows host's LAN address and port. Each server writes its log inside the private installation directory.

### Optional relay through a Mac

Use this setup when the Windows game host is on a different network and the iPhone shares Wi-Fi with a Mac. The Mac and Windows host must be connected to the same Tailscale network. The iPhone only needs access to the Mac's Wi-Fi address.

1. On Windows, start each required dedicated server bound to loopback, substituting `127.0.0.1` for `$env:SERVER_LAN_IP` in the commands above.
2. On the Mac, start the gateway with its Wi-Fi interface address and subnet prefix, its Tailscale IPv4 address, and the Windows host's Tailscale IPv4 address. Permit UDP 24985 and 24988 from the Wi-Fi subnet and TCP 29489 from the Windows host over Tailscale.

   ```sh
   python3 lan/lan_tunnel.py gateway "$MAC_WIFI_CIDR" "$MAC_TAILNET_IP" "$WINDOWS_TAILNET_IP"
   ```

3. On Windows, run the forwarder and leave both bridge processes running while playing.

   ```powershell
   py -3 lan/lan_tunnel.py forward $env:MAC_TAILNET_IP
   ```

4. Join the Mac's Wi-Fi IPv4 address with the selected game port on the phone. The gateway accepts traffic from its configured Wi-Fi subnet and accepts a tunnel from the specified Windows peer. The forwarder sends the game packets to the loopback dedicated servers.

### USB fallback for a Mac-connected iPhone

When packaging the app, pass `--private-server "$GATEWAY_IP"` along with `--lan-root`. Choose the private LAN IPv4 address that the Mac can use to reach the game server. In the separate Mac relay setup above, use the Mac gateway's Wi-Fi address and keep both relay processes running.

Plug one trusted iPhone into the Mac, then start the USB helper on the Mac with the same address.

```sh
python3 lan/usb_join_fallback.py "$GATEWAY_IP"
```

In **Join Private Server**, use the configured address and the selected mode's standard port. The phone first sends a direct UDP query. If it times out, the phone opens a loopback control port and the helper uses the Mac's system usbmuxd service to forward the compatibility query. After a compatible reply, it forwards game packets over the cable. The launcher displays the selected transport while the match loads.

If the cable or stream drops during a match, the helper keeps the verified session for two minutes and reconnects the game stream on the same gateway socket. The launcher sends the join command 65 seconds after the mode starts and repeats it up to twice if the client state has not changed; pass `-BO2ConnectDelay <seconds>` or `-BO2MenuKeyDelay <seconds>` as launch arguments to adjust the waits. The reconnect and retry paths have not yet been exercised on a device.

On the tested iPhone, the direct Wi-Fi query timed out. The USB path returned the compatibility reply, established the game connection and loaded the map. The private server recorded the client joining.

## Verify an instrumented two-player run

The offline verifiers read an existing `match.log`, `ios.jsonl.gz` and `windows.jsonl` in a private run directory. They require the staged event and snapshot records produced by the game test instrumentation. Ordinary server logs alone do not contain those records.

Run `python3 lan/verify_pair.py "$PRIVATE_RUN"` for Aftermath or `python3 lan/verify_tranzit.py "$PRIVATE_RUN"` for Zombies. The Aftermath verifier checks observed movement, damage, kills and armed respawns. The Zombies verifier checks observed movement, zombie kills and reciprocal revives. Results print to the terminal.

## Optional installation service

Stage only game files in a private directory named `steam-library`, next to the ownership receipt. Run the following commands to index the files and start the owner-restricted service.

```sh
python3 ios/index_library.py "$PRIVATE/steam-library" "$PRIVATE/steam-index.json"
python3 ios/steam_install_server.py "$PRIVATE" "$TAILNET_HTTPS_ORIGIN" --port 8080
```

Expose the loopback service through the supplied tailnet HTTPS origin and pass the same origin to the packager with `--library-origin`. The service validates Steam OpenID sign-in against the account in the private receipt. The phone verifies each downloaded file against the supplied manifest.

The Metal library compiler takes separately provided shader source files. The archive assembler takes a locally signed application shell and a private game ZIP, then verifies each file against the app's resource seal. Each tool accepts `--help`.

The Git allowlist covers only the source files and this README. Keep account receipts, signing material, server addresses, private libraries, compiled frameworks, archives and device reports outside the repository.
