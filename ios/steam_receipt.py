"""Capture the signed-in Mac Steam client's answers for a personal offline iOS build."""
import ctypes as c
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

MODES = [202970, 202990, 212910]


def probe(app):
    os.environ["SteamAppId"] = str(app)
    lib = c.CDLL(str(Path.home()/"Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/Frameworks/Steam Helper.app/Contents/MacOS/libsteam_api.dylib"))
    def fn(name, result, *args):
        f = getattr(lib, "SteamAPI_"+name)
        f.restype, f.argtypes = result, list(args)
        return f
    def interface(name, minimum):
        for version in range(minimum+20, minimum-1, -1):
            accessor = f"{name}_v{version:03}"
            if hasattr(lib, "SteamAPI_"+accessor):
                obj = fn(accessor,c.c_void_p)()
                if obj: return obj
        raise RuntimeError("Missing Steam interface "+name)
    error = c.create_string_buffer(1024)
    if fn("InitFlat",c.c_int,c.c_char_p)(error):
        raise RuntimeError(error.value.decode(errors="replace"))
    try:
        apps = interface("SteamApps",9)
        user = interface("SteamUser",23)
        steam_id = fn("ISteamUser_GetSteamID",c.c_uint64,c.c_void_p)(user)
        sub = fn("ISteamApps_BIsSubscribedApp",c.c_bool,c.c_void_p,c.c_uint32)
        dlc = fn("ISteamApps_BIsDlcInstalled",c.c_bool,c.c_void_p,c.c_uint32)
        if not steam_id or not sub(apps,app):
            raise RuntimeError(f"Steam did not confirm ownership of {app}")
        count = fn("ISteamApps_GetDLCCount",c.c_int,c.c_void_p)(apps)
        item = fn("ISteamApps_BGetDLCDataByIndex",c.c_bool,c.c_void_p,c.c_int,
                  c.POINTER(c.c_uint32),c.POINTER(c.c_bool),c.c_char_p,c.c_int)
        owned, installed = {app}, set()
        for i in range(count):
            addon, available, name = c.c_uint32(), c.c_bool(), c.create_string_buffer(512)
            if item(apps,i,c.byref(addon),c.byref(available),name,len(name)):
                if sub(apps,addon.value): owned.add(addon.value)
                if dlc(apps,addon.value): installed.add(addon.value)
        return dict(account=steam_id,owned=sorted(owned),installed=sorted(installed))
    finally:
        fn("Shutdown",None)()


if __name__ == "__main__":
    if sys.argv[1]=="--mode":
        print(json.dumps(probe(int(sys.argv[2]))))
    else:
        rows=[json.loads(subprocess.check_output([sys.executable,__file__,"--mode",str(i)],text=True).splitlines()[-1]) for i in MODES]
        if len({r["account"] for r in rows})!=1: raise ValueError("Steam account changed during export")
        receipt=dict(account=rows[0]["account"],
                     owned=sorted({i for row in rows for i in row["owned"]}),
                     installed=sorted({i for row in rows for i in row["installed"]}))
        Path(sys.argv[1]).write_bytes(plistlib.dumps(receipt,fmt=plistlib.FMT_BINARY))
        print("Steam confirmed ownership of Campaign, Multiplayer and Zombies.")
