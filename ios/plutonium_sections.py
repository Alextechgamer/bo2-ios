"""Build a separate r5369 LAN data image for a translated retail T6 mode."""
import argparse
import os
from pathlib import Path
import struct
import tempfile


# Three entity field lists serialize the same 16-bit un1 member at offset 246.
# Addresses refer to the supported unpacked Steam executables, not the server PE.
FIELDS = {
    "mps": (0xc9d9e4, 0xc9c940, 0xc99534),
    "zms": (0xc9ba04, 0xc9a960, 0xc97554),
}


def converted(mode, source):
    data = bytearray(source)
    count, = struct.unpack_from("<I", data)
    offset = 4
    sections = []
    for _ in range(count):
        address, size = struct.unpack_from("<II", data, offset)
        offset += 8
        if offset + size > len(data):
            raise ValueError("Truncated guest section")
        sections.append((address, size, offset))
        offset += size
    if offset != len(data):
        raise ValueError("Unexpected guest section trailer")

    def locate(address, size):
        matches = [start + address - va for va, length, start in sections
                   if va <= address and address + size <= va + length]
        if len(matches) != 1:
            raise ValueError(f"Missing or ambiguous guest range at {address:#x}")
        return matches[0]

    for address in FIELDS[mode]:
        pos = locate(address, 20)
        name, member, width, bits, flags = struct.unpack_from("<5I", data, pos)
        string = locate(name, 4)
        if data[string:string+4] != b"un1\0" or (member,width,bits,flags) != (246,1,8,0):
            raise ValueError(f"Unexpected retail network field at {address:#x}")
        struct.pack_into("<II", data, pos+8, 2, 16)
    return data


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=FIELDS)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.source.resolve() == args.output.resolve():
        parser.error("Choose a separate output for the Plutonium image")
    result = converted(args.mode, args.source.read_bytes())
    with tempfile.NamedTemporaryFile(dir=args.output.parent, delete=False) as f:
        temp = Path(f.name)
        try:
            f.write(result)
            f.close()
            os.chmod(temp, 0o644)
            os.replace(temp, args.output)
        finally:
            temp.unlink(missing_ok=True)
