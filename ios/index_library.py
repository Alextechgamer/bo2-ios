"""Build the private installer index from a separately supplied game directory."""
import argparse
import hashlib
import json
from pathlib import Path


def write_index(directory, output):
    directory = directory.resolve(strict=True)
    if output.resolve().is_relative_to(directory):
        raise ValueError("Place the index outside the library directory")
    rows = []
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Library contains a symbolic link: {path}")
        if path.is_file():
            with path.open("rb") as stream:
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
            # Preserve the six-column layout consumed by the installer service.
            rows.append([path.relative_to(directory).as_posix(), None, path.stat().st_size, None, None, digest])
    output.write_text(json.dumps({"assets": rows}), encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    write_index(args.directory, args.output)
