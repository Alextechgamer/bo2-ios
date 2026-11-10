"""Serve the iOS Join fallback through usbmuxd and a configured private game gateway."""
import argparse
from contextlib import closing
from ipaddress import IPv4Address, IPv4Network
import plistlib
import re
import select
import socket
import struct
import time


REQUEST = re.compile(rb"(24985|24988) ([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})\n")
OOB = b"\xff" * 4
PRIVATE_NETWORKS = tuple(map(IPv4Network, ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")))


def usb_target(mux):
    conn, response = mux({"MessageType": "ListDevices"})
    with closing(conn):
        devices = [entry["DeviceID"] for entry in response["DeviceList"]
                   if entry["Properties"]["ConnectionType"] == "USB"]
    return devices[0] if len(devices) == 1 else None


def open_listener(mux, device, port):
    conn, status = mux({"MessageType": "Connect", "DeviceID": device,
                        "PortNumber": socket.htons(port)})
    if status.get("Number") == 0:
        conn.settimeout(2)
        return conn
    conn.close()
    return None


def request(control):
    data = bytearray()
    deadline = time.monotonic() + 2
    while len(data) < 43:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        control.settimeout(remaining)
        part = control.recv(43 - len(data))
        if not part:
            break
        data.extend(part)
        if b"\n" in data:
            break
    match = REQUEST.fullmatch(data)
    if not match:
        raise ValueError("Malformed fallback request")
    return int(match[1]), match[2]


def confirm(udp, nonce):
    udp.settimeout(.45)
    for _ in range(3):
        udp.send(OOB + b"getinfo " + nonce)
        try:
            packet = udp.recv(65535)
        except socket.timeout:
            continue
        fields = packet.split(b"\\")
        info = dict(zip(fields[1::2], fields[2::2]))
        if packet.startswith(OOB + b"infoResponse\n") and info.get(b"challenge") == nonce:
            return packet
    raise TimeoutError("No matching private gateway response")


def pump(game, udp):
    buffered = bytearray()
    while True:
        ready = select.select([game, udp], [], [], 90)[0]
        if not ready:
            return
        if game in ready:
            part = game.recv(65536)
            if not part:
                return
            buffered.extend(part)
            while len(buffered) >= 2:
                size, = struct.unpack_from("!H", buffered)
                if not 0 < size <= 65507:
                    raise ValueError("Malformed game frame")
                if len(buffered) < size + 2:
                    break
                udp.send(buffered[2:2 + size])
                del buffered[:2 + size]
        if udp in ready:
            reply = udp.recv(65535)
            if reply:
                game.sendall(struct.pack("!H", len(reply)) + reply)


SESSION_GRACE = 120  # seconds a verified session waits for the game stream to return


def verify(control, gateway):
    """Answer one Join query and return the gateway socket it was verified on."""
    udp = socket.socket(type=socket.SOCK_DGRAM)
    try:
        with control:
            port, nonce = request(control)
            udp.connect((str(gateway), port))
            control.sendall(confirm(udp, nonce))
    except BaseException:
        udp.close()
        raise
    return udp, port


def serve(mux, gateway):
    prior = None
    session = None  # [gateway socket, game port, deadline]

    def end_session(reason):
        nonlocal session
        if session:
            session[0].close()
            print("USB session ended:", reason, flush=True)
        session = None

    print("USB Join fallback polling for a single wired target", flush=True)
    while True:
        try:
            device = usb_target(mux)
            if (device is not None) != prior:
                prior = device is not None
                print("Wired target available" if prior else "Waiting for a single wired target", flush=True)
            control = open_listener(mux, device, 19469) if device is not None else None
            if control is not None:
                # A fresh Join query always replaces the previous session.
                end_session("new Join request")
                udp, port = verify(control, gateway)
                session = [udp, port, time.monotonic() + SESSION_GRACE]
                print("Verified gateway, awaiting game", port, flush=True)
            elif session and device is not None:
                # The same gateway socket is reused after a cable or stream drop,
                # so the server keeps seeing one client address.
                game = open_listener(mux, device, 19470)
                if game is not None:
                    with game:
                        print("USB game connected", session[1], flush=True)
                        try:
                            pump(game, session[0])
                        finally:
                            session[2] = time.monotonic() + SESSION_GRACE
                    print("USB game stream closed, waiting to reconnect", session[1], flush=True)
        except (ValueError, KeyError, struct.error, plistlib.InvalidFileException) as error:
            print("USB fallback:", error, flush=True)
            end_session("invalid data")
            time.sleep(.5)
        except OSError as error:
            print("USB fallback:", error, flush=True)
            time.sleep(.5)
        if session and time.monotonic() > session[2]:
            end_session("game did not reconnect")
        time.sleep(.15 if session else .2 if prior else 1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("gateway", type=IPv4Address)
    args = parser.parse_args()
    if not any(args.gateway in network for network in PRIVATE_NETWORKS):
        parser.error("Supply the private IPv4 address of the BO2 gateway")
    from usb_mux import mux
    socket.setdefaulttimeout(2)
    serve(mux, args.gateway)
