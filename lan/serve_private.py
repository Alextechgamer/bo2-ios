"""Start an ordinary r5369 private game on a specified LAN interface."""
import argparse
from ipaddress import IPv4Address, IPv4Network
import os
from pathlib import Path
import subprocess


LAN = tuple(map(IPv4Network, ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("aftermath", "tranzit"))
    parser.add_argument("address", type=IPv4Address)
    parser.add_argument("--root", required=True, type=Path,
                        help="Private installation directory containing Plutonium/ and game/")
    args = parser.parse_args()
    if not (args.address.is_loopback or any(args.address in subnet for subnet in LAN)):
        parser.error("Choose a loopback or RFC1918 LAN interface address.")
    if os.name != "nt":
        parser.error("The dedicated server requires Windows.")
    root = args.root.resolve(strict=True)
    distro = root / "Plutonium"
    executable = distro / "bin/plutonium-bootstrapper-win32.exe"
    if not executable.is_file() or not (root/"game").is_dir():
        parser.error("Expected Plutonium/bin/plutonium-bootstrapper-win32.exe and game/ under --root.")
    mp = args.mode == "aftermath"
    options = (["+set", "g_gametype", "tdm", "+set", "sv_maxclients", "4", "+set", "g_logSync", "1",
                "+set", "sv_maprotation", "map mp_la", "+map_rotate"] if mp else
               ["+set", "ui_zm_gamemodegroup", "zclassic", "+set", "ui_gametype", "zclassic",
                "+set", "ui_zm_mapstartlocation", "transit", "+set", "g_gametype", "zclassic",
                "+map", "zm_transit"])
    argv = [str(executable), "t6mp" if mp else "t6zm",
            str(root / "game"), "-lan", "-dedicated", "+set", "net_ip", str(args.address),
            "+set", "net_port", "24985" if mp else "24988", *options]
    with (root / (args.mode + "-private-server.log")).open("wb") as log:
        proc = subprocess.Popen(argv, cwd=distro, env={**os.environ, "LOCALAPPDATA": str(root)},
                                creationflags=subprocess.CREATE_NO_WINDOW, stdout=log, stderr=subprocess.STDOUT)
    print(f"{args.mode} server PID {proc.pid}", flush=True)


if __name__ == "__main__":
    main()
