"""Convert the three retail Steam images using the Mac release's Remill toolchain.

Run on the Mac with a private writable copy of the bo2 release source tree.
The original executables and generated bitcode stay outside source control.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import sys
import time

MODES = (
    ("zms", "t6zm", 12533, "08e72c7fd4ceb9eb43104ab6a70231b928859e3081bae0afcd839417ff002f24"),
    ("mps", "t6mp", 12664, "036a53668b26aff9b43546392bb2b17c4f2da933f777145d86c75687fd4e6f26"),
    ("sps", "t6sp", 9211, "4a5e30c859422f866d6392f579372c1d8d2fe4e8d782ef56cbb0137f8a66b9d8"),
)


def verify(image, expected):
    data = image.read_bytes()
    pe, = struct.unpack_from("<I", data, 60)
    n, = struct.unpack_from("<H", data, pe+6)
    optional, = struct.unpack_from("<H", data, pe+20)
    digest = hashlib.sha256()
    for i in range(n):
        size, offset = struct.unpack_from("<II", data, pe+24+optional+40*i+16)
        if offset+size > len(data):
            raise ValueError(f"Truncated section in {image}")
        digest.update(data[offset:offset+size])
    if digest.hexdigest() != expected or b".bind" in data[:4096]:
        raise ValueError(f"Unsupported executable: {image}")
    print(image.name, digest.hexdigest(), flush=True)


def checked_run(command, folder, env, log):
    with log.open("a") as output:
        proc = subprocess.Popen(command, cwd=folder, env=env, stdout=output,
                                stderr=subprocess.STDOUT, start_new_session=True)
        try:
            while proc.poll() is None:
                if shutil.disk_usage(folder).free < 8 * 1024**3:
                    raise RuntimeError("Conversion paused to keep 8 GiB free. Move the private build to a larger volume and resume.")
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    pass
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
                proc.wait()
        if proc.returncode:
            raise RuntimeError(f"Exit {proc.returncode}: see {log}")


def device_object(path):
    """Reject truncated, simulator, or desktop objects when resuming."""
    if not path.is_file(): return False
    with path.open("rb") as f:
        header=f.read(32)
        if len(header)!=32:return False
        magic,cpu,_,kind,ncmds,cmdsize,_,_=struct.unpack("<8I",header)
        if (magic,cpu,kind)!=(0xfeedfacf,0x0100000c,1) or cmdsize>path.stat().st_size-32:return False
        commands=f.read(cmdsize)
    at=0
    for _ in range(ncmds):
        if at+8>len(commands):return False
        cmd,size=struct.unpack_from("<2I",commands,at)
        if size<8 or at+size>len(commands):return False
        if cmd==0x32 and size>=24:
            return struct.unpack_from("<I",commands,at+8)[0]==2
        at+=size
    return False


def codegen(src, mode, jobs, batches=True):
    work=src/"boot_cache"/mode
    units=[Path(p).resolve() for p in json.loads((work/"ios-units.json").read_text())]
    if not units or units[-1].name!="stubs.bc" or any(p.parent!=work or not p.is_file() for p in units):
        raise ValueError("Incomplete or unexpected bitcode manifest")
    def build(unit):
        out=unit.with_suffix(".ios.o")
        if device_object(out) and out.stat().st_mtime_ns>=unit.stat().st_mtime_ns:return
        tmp=out.with_name(out.name+".building")
        checked_run(["xcrun","--sdk","iphoneos","clang","-target","arm64-apple-ios16.0","-O1",
                     "-c",str(unit),"-o",str(tmp)],src,os.environ,work/"ios-codegen.log")
        if not device_object(tmp):raise ValueError("Invalid iOS object for "+unit.name)
        os.replace(tmp,out)
    # With --lift-only the batches are left for fold_modes.sh, which compiles them folded at -O2.
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        for n,_ in enumerate(pool.map(build,units[:-1] if batches else []),1):
            if n%25==0:print(f"{mode}: {n}/{len(units)} iPhone objects checked",flush=True)
    # The linker uses this last unit as its readiness signal.
    build(units[-1])


def convert(src, tc, inputs, selected, jobs, lift_only=False, built=None):
    # "built" is every mode this app will have; "selected" is what is still to convert in this run.
    built = set(built or [m[0] for m in MODES])
    if not set(selected) <= built:
        raise ValueError("A mode to convert is not among the modes being built")
    for mode, exe, _, expected in MODES:
        if mode in built:
            verify(inputs/(exe+".exe.unpacked.exe"), expected)
    boot = (src/"tools/boot.py").read_text()
    for _, exe, _, _ in MODES:
        name = exe+".exe.unpacked.exe"
        old = f'os.path.expanduser("~/.bo2-native/steam/{name}")'
        if old not in boot:
            raise ValueError("Unrecognized release boot driver")
        boot = boot.replace(old, repr(str(inputs/name)))
    marker = 'return _finish_build(args, workdir, None, bc_files, time.time())'
    if boot.count(marker) != 1:
        raise ValueError("Unrecognized release bitcode stage")
    boot = boot.replace(marker, '''assert len(batch_bcs) == (len(bc_files)+batch_size-1)//batch_size
        import json
        with open(os.path.join(workdir, "ios-units.json"), "w") as manifest:
            json.dump(batch_bcs + [stub_bc], manifest)
        ''' + marker)
    driver = src/"tools/boot_ios_private.py"
    driver.write_text(boot)
    base = dict(os.environ, BO2_TOOLCHAIN=str(tc), LLVM17=str(tc/"llvm@17"),
                PYTHONPATH=str(tc/"python"), REMILL_SEMANTICS_DIR=str(tc/"remill/build/lib/Arch/X86/Runtime"))
    for mode, exe, _, _ in MODES:
        if mode not in built:
            continue
        subprocess.run([sys.executable,"tools/ghidra_csv.py","remplir",str(inputs/(exe+".exe.unpacked.exe"))],
                       cwd=src, env=dict(base, BO2_TARGET=mode), check=True)
    tmp = src/"runtime/win32/snd_reverb_gen.ios.tmp"
    with tmp.open("w") as out:
        for mode,exe,start,end in (("mps","t6mp","83b1a0","83bdc4"),("zms","t6zm","83c170","83cd94"),
                                   ("sps","t6sp","806290","806eb4")):
            if mode in built:
                subprocess.run([sys.executable,"scripts/x86c.py",str(inputs/(exe+".exe.unpacked.exe")),start,end,
                                "bo2_snd_reverb_"+exe[2:],"SND-REV"],cwd=src,env=base,stdout=out,check=True)
            else:
                # The shared runtime names all three routines. One for a mode that is not built is never called.
                out.write(f'// {exe}.exe was not supplied; {mode} is not part of this build.\n'
                          f'extern "C" __attribute__((used)) void* bo2_snd_reverb_{exe[2:]}(State* s, uint32_t pc, void* mem) {{\n'
                          '    __builtin_trap();\n}\n')
                out.flush()
    tmp.replace(src/"runtime/win32/snd_reverb_gen.inc")
    for mode, _, count, _ in MODES:
        if mode not in selected:
            continue
        work = src/"boot_cache"/mode
        work.mkdir(parents=True, exist_ok=True)
        runway = work/"runway_vide.txt"
        runway.touch()
        env = dict(base, BO2_TARGET=mode, BOOT_STOP_AT_BC="1", BOOT_WORKDIR=str(work),
                   LIFT_PISTE_ENTIERE="1", LIFT_ROOTS_FILE=f"tools/lift_roots_{mode}.txt", LIFT_RUNWAY_FILE=str(runway))
        checked_run([sys.executable,"-u",str(driver),"-n",str(count),"-j","4","--build-only"],
                    src, env, work/"ios-lift.log")
        if not all((work/f).is_file() and (work/f).stat().st_size for f in ("ios-units.json","main.cpp","pe_sections.bin")):
            raise RuntimeError(f"Incomplete {mode} lift; see {work}/ios-lift.log")
        codegen(src,mode,jobs,not lift_only)


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    for arg in ("source","toolchain","inputs"):
        parser.add_argument(arg,type=Path)
    parser.add_argument("--modes",nargs="+",choices=[m[0] for m in MODES],
                        default=[m[0] for m in MODES],help="Stages to run when resuming a partial conversion")
    parser.add_argument("--built",nargs="+",choices=[m[0] for m in MODES],
                        help="Every mode the app will have; the executables of the others are not needed")
    parser.add_argument("--codegen-only",choices=[m[0] for m in MODES],
                        help="Resume native compilation after an already completed lift")
    parser.add_argument("--lift-only",action="store_true",
                        help="Stop after the lift and the stub object; compile the batches with fold_modes.sh")
    parser.add_argument("--jobs",type=int,choices=(1,2,3,4),default=2)
    a=parser.parse_args()
    if a.codegen_only:
        codegen(a.source.resolve(),a.codegen_only,a.jobs)
    else:
        convert(a.source.resolve(),a.toolchain.absolute(),a.inputs.resolve(),a.modes,a.jobs,a.lift_only,a.built)
