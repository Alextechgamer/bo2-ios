"""Steam OpenID access to one private, previously exported BO2 game library."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlsplit
from urllib.request import Request, urlopen
from threading import Lock

STEAM = "https://steamcommunity.com/openid/login"
NS = "http://specs.openid.net/auth/2.0"
LOCK = Lock()
states, sessions = {}, {}


def scalar(query):
    if any(len(v) != 1 for v in query.values()):
        raise ValueError("duplicate parameter")
    return {k: v[0] for k, v in query.items()}


def prune():
    now = time.monotonic()
    for table in (states, sessions):
        for k, v in list(table.items()):
            if v[0] < now:
                del table[k]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # Keep callbacks, login state, and bearer credentials out of logs.

    def redirect(self, url):
        self.send_response(302)
        self.send_header("Location", url)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def body(self, data, mime="application/json"):
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        try:
            self.handle_get()
        except (ValueError, KeyError):
            self.send_error(400, "Invalid Steam sign-in request")
        except (BrokenPipeError, ConnectionResetError):
            pass
        except OSError:
            self.send_error(503, "Library or Steam unavailable")

    def handle_get(self):
        path = urlsplit(self.path)
        args = scalar(parse_qs(path.query))
        if path.path in ("/login", "/login-url"):
            challenge = args["challenge"]
            if not re.fullmatch("[0-9a-f]{64}", challenge):
                raise ValueError()
            state = secrets.token_urlsafe(32)
            with LOCK:
                prune()
                if len(states) >= 256:
                    return self.send_error(429)
                states[state] = (time.monotonic() + 600, challenge, False)
            select = NS + "/identifier_select"
            fields = {"ns": NS, "mode": "checkid_setup", "identity": select, "claimed_id": select,
                      "realm": ORIGIN + "/", "return_to": ORIGIN + "/callback?state=" + state}
            url = STEAM + "?" + urlencode({"openid."+k: v for k,v in fields.items()})
            if path.path == "/login-url":
                return self.body(json.dumps({"url":url}).encode())
            return self.redirect(url)
        if path.path == "/callback":
            state = args["state"]
            with LOCK:
                prune()
                entry = states.pop(state, None)
            if not entry or entry[2]:
                return self.send_error(403)
            claim = "https://steamcommunity.com/openid/id/" + str(OWNER)
            required = {"op_endpoint", "claimed_id", "identity", "return_to", "response_nonce", "assoc_handle"}
            if (args.get("openid.ns") != NS or args.get("openid.mode") != "id_res"
                    or args.get("openid.op_endpoint") != STEAM or args.get("openid.identity") != claim
                    or args.get("openid.claimed_id") != claim or args.get("openid.return_to") != ORIGIN + "/callback?state=" + state
                    or not required <= set(args.get("openid.signed","").split(","))):
                return self.send_error(403, "Sign in with the Steam account that owns this library")
            verify = {k:v for k,v in args.items() if k.startswith("openid.")}
            verify["openid.mode"] = "check_authentication"
            with urlopen(Request(STEAM, data=urlencode(verify).encode()), timeout=15) as reply:
                if b"is_valid:true" not in reply.read(4096).splitlines():
                    return self.send_error(403)
            with LOCK:
                states[state] = (time.monotonic()+120, entry[1], True)
            return self.redirect("bo2library://signed-in?code=" + state)
        with LOCK:
            prune()
            token = self.headers.get("Authorization", "").removeprefix("Bearer ")
            if not sessions.get(token):
                return self.send_error(401)
        if path.path == "/manifest":
            return self.body(MANIFEST)
        match = re.fullmatch(r"/files/(\d+)", path.path)
        if not match or int(match[1]) >= len(FILES):
            return self.send_error(404)
        name, size = FILES[int(match[1])]
        path = (GAME / name).resolve()
        if GAME not in path.parents or not path.is_file():
            return self.send_error(503, "This file is still being staged")
        with path.open("rb") as src:
            if os.fstat(src.fileno()).st_size != size:
                return self.send_error(503, "This file is still being staged")
            self.send_response(200)
            self.send_header("Content-Length", str(size))
            self.end_headers()
            shutil.copyfileobj(src, self.wfile, 262144)

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if self.path != "/session" or not 0 < length <= 1024:
                return self.send_error(400)
            args = json.loads(self.rfile.read(length))
            challenge = hashlib.sha256(args["verifier"].encode()).hexdigest()
            with LOCK:
                prune()
                entry = states.get(args["code"])
                if not entry or not entry[2] or not secrets.compare_digest(challenge, entry[1]):
                    return self.send_error(403)
                del states[args["code"]]
                token = secrets.token_urlsafe(48)
                sessions[token] = (time.monotonic()+21600,)
            self.body(json.dumps({"token":token}).encode())
        except (ValueError, KeyError, TypeError, AttributeError):
            self.send_error(400)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("root", type=Path)
    p.add_argument("origin")
    p.add_argument("--port", type=int, default=8080)
    args = p.parse_args()
    ORIGIN = args.origin.rstrip("/")
    if not re.fullmatch(r"https://[A-Za-z0-9.-]+\.ts\.net(?::\d+)?", ORIGIN):
        p.error("tailnet HTTPS origin required")
    GAME = (args.root/"steam-library").resolve(strict=True)
    receipt = plistlib.loads((args.root/"SteamOwnership.plist").read_bytes())
    OWNER = receipt["account"]
    if not {202970,202990,212910} <= set(receipt["owned"]):
        raise SystemExit("Exported library has no complete BO2 ownership receipt")
    rows = json.loads((args.root/"steam-index.json").read_text())["assets"]
    FILES = []
    manifest = []
    for name, _, size, _, _, digest in rows:
        asset = (GAME/name).resolve()
        if GAME not in asset.parents:
            raise SystemExit("library index mismatch")
        manifest.append(dict(name=name,size=size,sha256=digest,id=len(FILES)))
        FILES.append((name,size))
    MANIFEST = json.dumps(manifest).encode()
    print("Owner-restricted library ready:", len(FILES), "files.", flush=True)
    ThreadingHTTPServer(("localhost",args.port), Handler).serve_forever()
