# Third-party notices

bo2-ios is licensed under the GNU General Public License, version 3 or later ([LICENSE](LICENSE)). It builds on the
work below. Each entry says where the work is used and under which terms.

## In this repository

| Work | Where | Licence |
|---|---|---|
| [iDeck](https://github.com/kuscholar/iDeck) (Madeira `SwiftSteam`), revision `2ac39beff91251d36f3ad6331d3f8402b3c10e18` | [ios/SteamAuth/](ios/SteamAuth/), the session, library and metadata files under [ios/SteamServices/Core/](ios/SteamServices/Core/) and [ios/SteamServices/Library/](ios/SteamServices/Library/), and the content download files under [ios/SteamServices/Content/](ios/SteamServices/Content/) except `zstd_edu.*` | GPL-3.0-or-later with the Madeira Converter Exception. Text in [ios/SteamAuth/COPYING](ios/SteamAuth/COPYING) and [ios/SteamAuth/LICENSE-EXCEPTION.md](ios/SteamAuth/LICENSE-EXCEPTION.md); provenance and the list of changes in [ios/SteamAuth/UPSTREAM.md](ios/SteamAuth/UPSTREAM.md). Per-file copyright notices are kept. |
| [Zstandard](https://github.com/facebook/zstd) educational decoder, as carried by iDeck at the revision above | [ios/SteamServices/Content/zstd_edu.c](ios/SteamServices/Content/zstd_edu.c) and `zstd_edu.h` | BSD-style licence or GPLv2, at the user's option; Copyright (c) Meta Platforms, Inc. and affiliates. Used here under the BSD-style licence. |
| [bo2-mac](https://github.com/adrbn/bo2-mac), v0.2.0-test.4 (`218dc8040956c0ec033eed02fe39866b7967892a`) | [ios/runtime.patch](ios/runtime.patch) is a set of changes to its runtime; [ios/convert_modes.py](ios/convert_modes.py), [ios/link_mode.py](ios/link_mode.py) and [ios/fold_modes.sh](ios/fold_modes.sh) drive its converter | GPL-3.0 |
| Steam interface declarations from [source-sdk-2013](https://github.com/ValveSoftware/source-sdk-2013) at `39ed875`, `mp/src/public/steam` | The method table `steam_abi_generated.h` inside [ios/runtime.patch](ios/runtime.patch): interface versions, method names and declarations only | Source 1 SDK License |

The Steam message layouts were written against public schema references, which are documentation and not copied
code: [SteamDatabase/Protobufs](https://github.com/SteamDatabase/Protobufs) and
[node-steam-user](https://github.com/DoctorMcKay/node-steam-user) (MIT).

## In an app you build, but not in this repository

The game frameworks are produced on your own Mac by [bo2-mac](https://github.com/adrbn/bo2-mac)'s converter and
runtime. They are not distributed here. An app you build contains:

| Work | Role | Licence |
|---|---|---|
| [bo2-mac](https://github.com/adrbn/bo2-mac) | Converter passes and the Win32 / Direct3D 11 runtime | GPL-3.0 |
| [Remill](https://github.com/lifting-bits/remill) | Lifts x86 machine code to LLVM IR | Apache-2.0 |
| [LLVM](https://llvm.org/) | Compiles the lifted code | Apache-2.0 with LLVM exceptions |
| [HLSLcc](https://github.com/Unity-Technologies/HLSLcc) | Translates the game's shaders for Metal | MIT |
| [Unicorn](https://github.com/unicorn-engine/unicorn) | Runs the short x86 sequences that are not translated ahead of time | GPL-2.0 |
| [libvpx](https://chromium.googlesource.com/webm/libvpx) | Decodes the game's videos | BSD-3-Clause |

GPL-2.0 and GPL-3.0 code cannot be shipped together in one binary. A build for your own phone is not affected.
Do not distribute a built app: it also contains the game's code.

## Not included

- No game file, game executable, game script or translated game code.
- No code from the Plutonium project. The private-server transport speaks the LAN-mode handshake of a server the
  player runs.
- No Steam client code. Sign-in and tickets use Steam's public authentication service and the player's own account.

Call of Duty and Black Ops are trademarks of Activision Publishing, Inc. Steam is a trademark of Valve Corporation.
iPhone and iOS are trademarks of Apple Inc. This project is not affiliated with, endorsed by or sponsored by any of
them.
