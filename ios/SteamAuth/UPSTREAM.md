# Steam authentication source

The Swift sign-in files were adapted from [kuscholar/iDeck](https://github.com/kuscholar/iDeck/tree/2ac39beff91251d36f3ad6331d3f8402b3c10e18/app/Madeira/SwiftSteam) at commit `2ac39beff91251d36f3ad6331d3f8402b3c10e18`.

Copyright 2026 Jfishin and 125hz, as identified in each source file. The iDeck-authored additions use GPL-3.0-or-later with the Madeira Converter Exception. See COPYING, LICENSE-EXCEPTION.md and the retained upstream provenance in docs/STEAM_SIGNIN.md. The upstream document describes iDeck's integration.

The BO2 adaptation adds a UIKit bridge, uses an app-specific Keychain service, replaces Madeira configuration and logging dependencies, supports the port's iOS 16 deployment target, checks cancellation at authentication network boundaries and updates existing Keychain sessions without deleting them first. The launcher exposes account sign-in and sign-out.

The original transport, protobuf, RSA and Steam Guard code retains its upstream notices. No account credentials, Steam executables or game data are included in these sources.

The same pinned revision supplies the CM WebSocket/session, license/PICS and metadata files under ../SteamServices/. Their per-file authorship and license notices are retained. The BO2 coordinator uses iOS 16-compatible state, shared refresh operations and account-generation invalidation. These files use the license and exception provided here.

The BO2 encrypted-ticket adapter follows the [CM request/response schema](https://github.com/SteamDatabase/Protobufs/blob/master/steam/steammessages_clientserver.proto) and [encrypted envelope schema](https://github.com/SteamDatabase/Protobufs/blob/master/steam/encrypted_app_ticket.proto). It preserves the full nested encoding, consistent with [node-steam-user's encrypted-ticket API](https://github.com/DoctorMcKay/node-steam-user/blob/master/components/appauth.js). Duplicate requests and the one-minute interval follow [Valve's RequestEncryptedAppTicket documentation](https://partner.steamgames.com/doc/api/ISteamUser#RequestEncryptedAppTicket). Ticket contents are never logged.

The same CM schema supplies played-game notifications. Their local state records an announcement, not game-service acceptance. The adaptation also corrects the imported CM control-message numbers to LogOnResponse 751, LogOff 706 and LoggedOff 757, checked against the [protocol message enum](https://github.com/DoctorMcKay/node-steam-user/blob/master/enums/EMsg.js). An explicit server logoff clears identity and pending work without an automatic reconnect.
