"""Fingerprint the packaged runtimes without confusing Steam and build inputs."""
import hashlib
import json
import subprocess
from pathlib import Path

MODES = ((202970, "sps", "t6sp.exe"), (202990, "mps", "t6mp.exe"), (212910, "zms", "t6zm.exe"))


def sha256(path):
    with Path(path).open("rb") as source:
        digest = hashlib.sha256()
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
        return digest.hexdigest()


def generate(app, build_root):
    app, build_root = Path(app), Path(build_root)
    # This private record must come from the verified unpacking/build process.
    # Its absence is deliberately not inferred from file names or file presence.
    provenance_path = build_root / "runtime-provenance.json"
    provenance = json.loads(provenance_path.read_text()) if provenance_path.is_file() else {}
    entries = []
    for app_id, mode, executable in MODES:
        framework = app / "Frameworks" / (mode + ".framework") / mode
        sections = app / "Modes" / mode / "pe_sections.bin"
        original = build_root / "mac-game" / executable
        unpacked = build_root / "inputs" / (executable + ".unpacked.exe")
        original_hash = sha256(original) if original.is_file() else None
        unpacked_hash = sha256(unpacked) if unpacked.is_file() else None
        record = provenance.get(str(app_id), {})
        verified = (record.get("verified") is True and original_hash is not None and unpacked_hash is not None
                    and record.get("steamExecutableSHA256") == original_hash
                    and record.get("unpackedExecutableSHA256") == unpacked_hash
                    and record.get("executable") == executable)
        exports = subprocess.check_output(["xcrun", "nm", "-gUj", str(framework)], text=True).splitlines()
        entries.append(dict(appID=app_id, mode=mode, executable=executable,
                            steamExecutableSHA256=original_hash, unpackedExecutableSHA256=unpacked_hash,
                            frameworkSHA256=sha256(framework), sectionsSHA256=sha256(sections),
                            nativeProvider="_bo2_ios_set_steam_provider" in exports,
                            originalToUnpackedVerified=verified))
    return dict(version=1, entries=entries)


def write_catalog(app, build_root):
    data = generate(app, build_root)
    (Path(app) / "RuntimeCatalog.json").write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return data
