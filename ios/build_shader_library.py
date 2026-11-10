"""Precompile captured BO2 Metal shaders into an iPhone app resource."""
from argparse import ArgumentParser
from concurrent.futures import ThreadPoolExecutor
from hashlib import sha256
from pathlib import Path
import re
import subprocess
import tempfile


HEADER = "#include <metal_stdlib>\n#include <metal_texture>\nusing namespace metal;\n"


def compile_group(files, work):
    source = [HEADER]
    for path in files:
        text = path.read_text()
        if not re.fullmatch("[0-9a-f]{16}", path.stem) or not text.startswith(HEADER):
            raise ValueError(f"Unrecognized shader: {path}")
        body, count = re.subn(
            r"\b(fragment|vertex)\s+",
            rf'[[host_name("bo2_{path.stem}")]] \1 ',
            text[len(HEADER):], count=1,
        )
        if count != 1:
            raise ValueError(f"Missing shader entry: {path}")
        source.append(f"namespace bo2_{path.stem} {{\n{body}\n}}\n")
    code = "".join(source)
    metal = work / (sha256(code.encode()).hexdigest() + ".metal")
    metal.write_text(code)
    air = metal.with_suffix(".air")
    subprocess.run(["xcrun", "-sdk", "iphoneos", "metal", "-target", "air64-apple-ios16.0",
                    "-fpreserve-invariance", "-c", metal, "-o", air], check=True)
    return air


def build(sources, output):
    files = sorted(sources.glob("*.msl"))
    if not files:
        raise ValueError(f"No captured shaders in {sources}")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as tmp:
        work = Path(tmp)
        groups = [files[i:i + 20] for i in range(0, len(files), 20)]
        with ThreadPoolExecutor(3) as pool:
            objects = list(pool.map(lambda group: compile_group(group, work), groups))
        library = work / "BO2Shaders.metallib"
        subprocess.run(["xcrun", "-sdk", "iphoneos", "metallib", *objects, "-o", library], check=True)
        library.replace(output)


if __name__ == "__main__":
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("sources", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    build(args.sources, args.output)
