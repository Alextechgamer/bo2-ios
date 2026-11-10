"""Bridge two private T6 UDP ports over a Windows-initiated Tailscale connection."""
import argparse
from contextlib import ExitStack
from ipaddress import IPv4Address, IPv4Interface, IPv4Network
import select
import socket
import struct
import time

PORTS = (24985, 24988)
TUNNEL_PORT = 29489
TAILNET = IPv4Network("100.64.0.0/10")
LAN = tuple(map(IPv4Network, ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")))
HEADER = struct.Struct("!IHH")  # peer ID, game port, datagram length


def bridge(conn, listeners, network):
    conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    conn.settimeout(4)
    pending = bytearray()
    by_id = {}
    by_peer = {}
    upstreams = {}
    sequence = 0
    last_ping = last_rx = time.monotonic()
    print("Tunnel connected", flush=True)

    def send(channel, port, packet):
        conn.sendall(HEADER.pack(channel, port, len(packet)) + packet)

    def close_peer(channel):
        peer, port, _ = by_id.pop(channel)
        if listeners:
            del by_peer[(peer, port)]
        else:
            del upstreams[peer]
            peer.close()

    try:
        while True:
            now = time.monotonic()
            for channel, (_, _, stamp) in list(by_id.items()):
                if now - stamp > 90:
                    close_peer(channel)
            if now - last_rx > 45:
                raise TimeoutError("No tunnel traffic or keepalive")
            if now - last_ping > 10:
                send(0, 0, b"")
                last_ping = now
            reads = [conn, *listeners.values(), *upstreams]
            for src in select.select(reads, [], [], 1)[0]:
                if src is conn:
                    block = conn.recv(65536)
                    if not block:
                        return
                    last_rx = now
                    pending.extend(block)
                    while len(pending) >= HEADER.size:
                        channel, port, size = HEADER.unpack_from(pending)
                        if len(pending) < HEADER.size + size:
                            break
                        packet = bytes(pending[HEADER.size:HEADER.size + size])
                        del pending[:HEADER.size + size]
                        if channel == port == size == 0:
                            continue
                        if port not in PORTS or not channel or size > 65507:
                            raise ValueError("Invalid tunnel frame")
                        if channel not in by_id:
                            if listeners or len(by_id) >= 64:
                                continue
                            peer = socket.socket(type=socket.SOCK_DGRAM)
                            peer.connect(("127.0.0.1", port))
                            upstreams[peer] = channel
                            by_id[channel] = (peer, port, now)
                        peer, expected_port, _ = by_id[channel]
                        if port != expected_port:
                            raise ValueError("Mismatched game port")
                        by_id[channel] = (peer, port, now)
                        try:
                            if listeners:
                                listeners[port].sendto(packet, peer)
                            else:
                                peer.send(packet)
                        except (ConnectionRefusedError, ConnectionResetError):
                            pass
                elif listeners:
                    packet, peer = src.recvfrom(65535)
                    if IPv4Address(peer[0]) not in network:
                        continue
                    port = src.getsockname()[1]
                    channel = by_peer.get((peer, port))
                    if channel is None:
                        if len(by_peer) >= 64:
                            continue
                        sequence += 1
                        channel = by_peer[(peer, port)] = sequence
                    by_id[channel] = (peer, port, now)
                    send(channel, port, packet)
                else:
                    channel = upstreams[src]
                    _, port, _ = by_id[channel]
                    try:
                        packet = src.recv(65535)
                    except (ConnectionRefusedError, ConnectionResetError):
                        continue
                    by_id[channel] = (src, port, now)
                    send(channel, port, packet)
    finally:
        for upstream in upstreams:
            upstream.close()


def gateway(lan, listen, allow):
    with ExitStack() as stack:
        listeners = {}
        for port in PORTS:
            udp = stack.enter_context(socket.socket(type=socket.SOCK_DGRAM))
            udp.bind((str(lan.ip), port))
            listeners[port] = udp
        tcp = stack.enter_context(socket.socket())
        tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        tcp.bind((str(listen), TUNNEL_PORT))
        tcp.listen(2)
        print("Listening for LAN game traffic on ports", PORTS, flush=True)
        while True:
            conn, peer = tcp.accept()
            with conn:
                if peer[0] == str(allow):
                    try:
                        bridge(conn, listeners, lan.network)
                    except (OSError, ValueError) as error:
                        print("Tunnel disconnected:", error, flush=True)


def forward(address):
    while True:
        try:
            with socket.create_connection((str(address), TUNNEL_PORT), 5) as conn:
                bridge(conn, {}, None)
        except (OSError, ValueError) as error:
            print("Retrying tunnel:", error, flush=True)
        time.sleep(3)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    mac = modes.add_parser("gateway")
    mac.add_argument("lan", type=IPv4Interface, help="Wi-Fi IPv4 address/prefix")
    mac.add_argument("listen", type=IPv4Address, help="Local Tailscale address")
    mac.add_argument("allow", type=IPv4Address, help="Windows Tailscale peer")
    win = modes.add_parser("forward")
    win.add_argument("gateway", type=IPv4Address, help="Mac Tailscale address")
    args = parser.parse_args()
    if args.mode == "gateway":
        if not any(args.lan.network.subnet_of(net) for net in LAN):
            parser.error("An RFC1918 Wi-Fi subnet is required")
        if args.listen not in TAILNET or args.allow not in TAILNET:
            parser.error("Both TCP endpoints must use Tailscale addresses")
        gateway(args.lan, args.listen, args.allow)
    else:
        if args.gateway not in TAILNET:
            parser.error("A Tailscale gateway is required")
        forward(args.gateway)
