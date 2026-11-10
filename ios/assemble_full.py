"""Reassemble the Apple-sealed app on the data host and verify every game file."""
import argparse
import copy
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import tempfile
from zipfile import ZipFile, ZipInfo, ZIP_STORED

APP="Payload/BlackOpsII.app/"
MODES=("sps","mps","zms")


def assemble(shell_file, game_file, output):
    with ZipFile(shell_file) as shell, ZipFile(game_file) as game:
        seal=plistlib.loads(shell.read(APP+"_CodeSignature/CodeResources"))["files2"]
        assets={key[5:]:value for key,value in seal.items() if key.startswith("Game/")}
        names=game.namelist()
        if len(names)!=len(set(names)) or set(names)!=set(assets):
            raise ValueError("Game archive and Apple-sealed resource names disagree")
        required=[APP+"embedded.mobileprovision",APP+"BlackOpsII",APP+"SteamOwnership.plist"]
        for mode in MODES:
            required.extend([f"{APP}Frameworks/{mode}.framework/{mode}",f"{APP}Modes/{mode}/pe_sections.bin"])
        for name in required:
            if shell.getinfo(name).file_size==0:raise ValueError("Empty app resource "+name)
        if any(name.startswith(APP+"Game/") for name in shell.namelist()):
            raise ValueError("Unexpected Game entry in the shell archive")
        output.parent.mkdir(parents=True,exist_ok=True)
        wanted=sum(x.file_size for x in game.infolist())+shell_file.stat().st_size
        if shutil.disk_usage(output.parent).free < wanted+512*1024**2:
            raise RuntimeError("Insufficient space for full IPA")
        # Keep the in-progress archive outside the served downloads directory.
        with tempfile.NamedTemporaryFile(prefix=output.name+".",suffix=".partial",dir=output.parent.parent,delete=False) as f:
            temp=Path(f.name)
        try:
            with ZipFile(temp,"w",allowZip64=True) as ipa:
                for entry in shell.infolist():
                    # Store modes and Unix executable bits exactly as signed.
                    with shell.open(entry) as src, ipa.open(copy.copy(entry),"w") as dst:
                        shutil.copyfileobj(src,dst,1024**2)
                for entry in game.infolist():
                    info=ZipInfo(APP+"Game/"+entry.filename,entry.date_time)
                    info.compress_type=ZIP_STORED
                    info.create_system=3
                    info.external_attr=0o100644<<16
                    info.file_size=entry.file_size
                    digest=hashlib.sha256()
                    with game.open(entry) as src, ipa.open(info,"w") as dst:
                        while chunk:=src.read(1024**2):
                            digest.update(chunk)
                            dst.write(chunk)
                    if digest.digest()!=assets[entry.filename]["hash2"]:
                        raise ValueError("Apple signature did not match "+entry.filename)
            with ZipFile(temp) as ipa:
                bad=ipa.testzip()
                if bad:raise ValueError("Full archive read failed: "+bad)
            full_hash=hashlib.sha256()
            with temp.open("rb") as f:
                for chunk in iter(lambda:f.read(4*1024**2),b""):full_hash.update(chunk)
            os.replace(temp,output)
            print(f"{len(names)} game files verified. {output.stat().st_size} bytes. SHA-256 {full_hash.hexdigest()}",flush=True)
        finally:
            temp.unlink(missing_ok=True)

if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ("shell","game","out"):parser.add_argument(name,type=Path)
    args=parser.parse_args()
    assemble(args.shell,args.game,args.out)
