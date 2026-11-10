"""Build and sign a personal all-mode IPA on a Mac with Xcode and XcodeGen.

The output volume needs space for the unpacked game, signed app and final ZIP.
"""
import argparse
from ipaddress import IPv4Address
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
from zipfile import ZipFile, ZIP_DEFLATED

MODES = ("sps", "mps", "zms")


def command(*args):
    subprocess.run([str(a) for a in args],check=True)


def package(root, game_zip, out, team, work, bundle_id, receipt, library_origin, lan_root, private_server):
    root, out, work = root.resolve(), out.resolve(), work.resolve()
    src = Path(__file__).resolve().parent
    # Require all three linked game binaries and generated memory sections before packaging.
    mode_dirs = {mode: (lan_root if lan_root and mode in ("mps", "zms") else root/"device") / mode for mode in MODES}
    for mode, mode_dir in mode_dirs.items():
        binary = mode_dir/(mode+".framework")/mode
        sections = root/"conversion/boot_cache"/mode/"pe_sections.bin"
        if not sections.is_file() or not binary.is_file():
            raise RuntimeError(f"Missing full {mode} framework or PE sections")
        exports = subprocess.check_output(["xcrun","nm","-gUj",str(binary)],text=True).splitlines()
        if not {"_bo2_ios_start","_bo2_ios_create_surface"} <= set(exports):
            raise ValueError(f"Incomplete {mode} runtime")
        if lan_root and mode in ("mps", "zms"):
            if not {"_bo2_pluto_start", "_bo2_cmd_queue", "_ios_game_event"} <= set(exports):
                raise ValueError(f"Missing private server entry points in {mode}")
            if not (mode_dir/"pluto_pe_sections.bin").is_file():
                raise ValueError(f"Missing private server sections for {mode}")
    settings=dict(PRODUCT_BUNDLE_IDENTIFIER=bundle_id,
                  DEVELOPMENT_TEAM=team,CODE_SIGN_STYLE="Automatic",GENERATE_INFOPLIST_FILE="YES",
                  INFOPLIST_KEY_UILaunchScreen_Generation="YES",INFOPLIST_KEY_UIRequiresFullScreen="YES",
                  INFOPLIST_KEY_UISupportedInterfaceOrientations="UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
                  CURRENT_PROJECT_VERSION="1",MARKETING_VERSION="0.1",IPHONEOS_DEPLOYMENT_TARGET="16.0",
                  SWIFT_VERSION="5.0")
    project=dict(name="BlackOpsII",targets={"BlackOpsII":dict(type="application",platform="iOS",
                 sources=["FullGame.m","SteamServices",dict(path="SteamAuth",excludes=["COPYING","LICENSE-EXCEPTION.md","docs","UPSTREAM.md"])],
                 dependencies=[{"sdk":"AuthenticationServices.framework"}],settings={"base":settings})})
    out.parent.mkdir(parents=True,exist_ok=True)
    work.mkdir(parents=True,exist_ok=True)
    with ZipFile(game_zip) as game, tempfile.TemporaryDirectory(dir=work) as folder:
        stage=Path(folder)
        names=set(game.namelist())
        required={"t6sp.exe","t6mp.exe","t6zm.exe"}
        if not required<=names or not any(n.startswith("zone/all/") for n in names):
            raise ValueError("Game archive is missing required mode or zone files")
        for name in names:
            if "\\" in name or Path(name).is_absolute() or ".." in Path(name).parts:
                raise ValueError("Unsafe archive path")
        total=sum(f.file_size for f in game.infolist())
        if shutil.disk_usage(work).free < total+2*1024**3:
            raise RuntimeError("Insufficient space to stage the complete game on the selected volume")
        shutil.copyfile(src/"FullGame.m",stage/"FullGame.m")
        shutil.copyfile(src/"SteamInstaller.h",stage/"SteamInstaller.h")
        shutil.copyfile(src/"SteamSignInBridge.h",stage/"SteamSignInBridge.h")
        shutil.copytree(src/"SteamAuth",stage/"SteamAuth")
        shutil.copytree(src/"SteamServices",stage/"SteamServices")
        spec=stage/"project.json"
        spec.write_text(json.dumps(project))
        command("xcodegen","generate","--spec",spec)
        command("xcodebuild","-project",stage/"BlackOpsII.xcodeproj","-scheme","BlackOpsII",
                "-configuration","Release","-destination","generic/platform=iOS","-allowProvisioningUpdates",
                "-derivedDataPath",stage/"Derived","build")
        app=stage/"Payload/BlackOpsII.app"
        app.parent.mkdir()
        shutil.move(str(stage/"Derived/Build/Products/Release-iphoneos/BlackOpsII.app"),app)
        # Use the exact identity/profile selected by Xcode, including personal-team signing.
        details=subprocess.run(["codesign","-dvvv",str(app)],capture_output=True,text=True,check=True).stderr
        identity=next(line.partition("=")[2] for line in details.splitlines() if line.startswith("Authority=Apple Development:"))
        ent=stage/"entitlements.plist"
        ent.write_bytes(subprocess.check_output(["codesign","-d","--entitlements",":-",str(app)],stderr=subprocess.DEVNULL))
        plistlib.loads(ent.read_bytes())
        info_path=app/"Info.plist"
        info=plistlib.loads(info_path.read_bytes())
        info["NSLocalNetworkUsageDescription"] = "Connect to a private game server on your local network."
        if private_server:
            info["BO2PrivateServer"] = str(private_server)
        if library_origin:
            info["GameLibraryOrigin"] = library_origin
        info.setdefault("CFBundleURLTypes",[]).append(dict(CFBundleURLName="Steam library callback",
                                                         CFBundleURLSchemes=["bo2library"]))
        info_path.write_bytes(plistlib.dumps(info))
        notices=app/"SteamAuthNotices"
        notices.mkdir()
        for name in ("COPYING","LICENSE-EXCEPTION.md","UPSTREAM.md"):
            shutil.copyfile(src/"SteamAuth"/name,notices/name)
        shutil.copyfile(receipt, app/"SteamOwnership.plist")
        frameworks=app/"Frameworks"
        frameworks.mkdir(exist_ok=True)
        for mode in MODES:
            lib=frameworks/(mode+".framework")
            shutil.copytree(mode_dirs[mode]/lib.name,lib)
            command("codesign","--force","--sign",identity,lib)
            dest=app/"Modes"/mode
            dest.mkdir(parents=True)
            shutil.copyfile(root/"conversion/boot_cache"/mode/"pe_sections.bin",dest/"pe_sections.bin")
            if lan_root and mode in ("mps", "zms"):
                shutil.copyfile(mode_dirs[mode]/"pluto_pe_sections.bin",dest/"pluto_pe_sections.bin")
        shaders = root/"BO2Shaders.metallib"
        if shaders.is_file():
            shutil.copyfile(shaders, app/shaders.name)
        game.extractall(app/"Game")
        command("codesign","--force","--sign",identity,"--entitlements",ent,app)
        command("codesign","--verify","--deep","--strict",app)
        with tempfile.NamedTemporaryFile(dir=out.parent,delete=False) as f:
            tmp=Path(f.name)
        try:
            with ZipFile(tmp,"w",compression=ZIP_DEFLATED,compresslevel=1,allowZip64=True) as ipa:
                for file in sorted(app.rglob("*")):
                    if file.is_file():
                        ipa.write(file,file.relative_to(stage))
            with ZipFile(tmp) as ipa:
                bad=ipa.testzip()
                if bad: raise ValueError("IPA readback failed for "+bad)
            os.replace(tmp,out)
        finally:
            tmp.unlink(missing_ok=True)


if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__)
    for name in ("root","game_zip","output","work"):
        p.add_argument(name,type=Path)
    p.add_argument("--team",required=True)
    p.add_argument("--bundle-id", required=True, help="Your registered app bundle identifier")
    p.add_argument("--receipt", required=True, type=Path, help="Your private Steam ownership plist")
    p.add_argument("--library-origin", help="HTTPS origin of your private installation service")
    p.add_argument("--lan-root", type=Path, help="Prebuilt LAN frameworks and sections in mps/ and zms/")
    p.add_argument("--private-server", type=IPv4Address, help="Private IPv4 gateway preset for the Join menu and USB fallback")
    a=p.parse_args()
    package(a.root,a.game_zip,a.output,a.team,a.work,a.bundle_id,a.receipt,a.library_origin,a.lan_root,a.private_server)
