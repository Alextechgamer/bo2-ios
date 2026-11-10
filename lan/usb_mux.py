"""Send one property-list request to the local macOS usbmuxd socket."""
import plistlib
import socket
import struct


HEADER = struct.Struct("<IIII")


def read_exact(conn, size):
    data = bytearray()
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            raise ConnectionError("usbmuxd closed an incomplete response")
        data.extend(chunk)
    return bytes(data)


def mux(command):
    """Return the open connection and response; a successful Connect becomes a stream."""
    payload = plistlib.dumps(command)
    version, plist_message, tag = 1, 8, 1
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        conn.connect("/var/run/usbmuxd")
        conn.sendall(HEADER.pack(HEADER.size + len(payload), version, plist_message, tag) + payload)
        size, protocol, kind, reply_tag = HEADER.unpack(read_exact(conn, HEADER.size))
        if (protocol, kind, reply_tag) != (version, plist_message, tag) or not HEADER.size < size <= 4 * 1024**2:
            raise ValueError("Invalid usbmuxd response header")
        reply = plistlib.loads(read_exact(conn, size - HEADER.size))
        if not isinstance(reply, dict):
            raise ValueError("Invalid usbmuxd response payload")
    except BaseException:
        conn.close()
        raise
    return conn, reply
