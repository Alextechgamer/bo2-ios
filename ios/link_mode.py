"""Link a translated mode against the iOS runtime. Inputs are private build products.

--online adds the Steam network transport (Multiplayer and Zombies).
--private-server adds the LAN-mode server transport (Multiplayer and Zombies). Multiplayer also needs
--lua-zip, your own capture of the nine r5369 interface scripts, and --hksc, the Hksc compiler built for T6.
"""
from argparse import ArgumentParser
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import sys
import tempfile
import zipfile


RUNTIME = (
    "win32/win32_runtime.cpp", "win32/kernel32_impl.cpp", "win32/user32_impl.cpp",
    "win32/remaining_dlls_impl.cpp", "win32/bo2_replay.cpp", "win32/heap_code.cpp",
    "audio/coreaudio_out.cpp", "gfx/dxbc_to_msl.cpp", "video/vpx_native.cpp",
    "gfx/metal_backend.mm", "input/pad_gc.mm", "win32/x86_guest_vm.cpp",
    "win32/interp.cpp", "win32/exception_adapter.cpp", "win32/dw_local.cpp",
    "win32/skin_native.cpp"
)
FALLBACKS = {
    "sps": "47b080 47b4e0 47ba60 47c110",
    "mps": "59a120 459800 459ce0 45a150 47ab10 47af70 47b4f0 47bba0",
    "zms": "59b6c0 4584c0 47acf0 47b150 47b6d0 47bd80",
}


LUA_PACK = "bf8c192ce5d6a22ea1304c14c76faac3cd0db0c8551f09b2e7613ac5c414078d"
# Guest entries the private-server transport takes over: (Multiplayer, Zombies).
HOOKS = {
    "send": (0x77eeb0,0x77ff60), "receive": (0x77eb60,0x77fc10), "ui_dispatch": (0x9333a0,0x930360),
    "allocate": (0x54f700,0x5516b0), "audio_fill": (0x830d60,0x831d40), "gamestate_long": (0x6cd630,0x6ce640),
    "client_memory": (0x554df0,0x556dd0), "server_id": (0x558320,0x5592f0), "packet_event": (0x553800,0x5557a0),
    "lua_init": (0x938090,0x935060), "lua_read": (0x9386b0,None),
}


def prepare_mp_lua(archive, compiler, out):
    """Compile the Multiplayer interface scripts a LAN-mode server expects into one linked blob."""
    digest=hashlib.sha256()
    data=bytearray()
    entries=[]
    with zipfile.ZipFile(archive) as scripts:
        sources={name:scripts.read(name) for name in sorted(scripts.namelist())}
    for name,script in sources.items():
        digest.update(name.encode()+b"\0"+hashlib.sha256(script).digest())
    if digest.hexdigest()!=LUA_PACK:
        raise ValueError(f"{archive} does not match the nine verified r5369 scripts")
    with tempfile.TemporaryDirectory(dir=out) as tmp:
        for name,script in sources.items():
            source=Path(tmp)/name
            source.parent.mkdir(parents=True,exist_ok=True)
            source.write_bytes(script)
            subprocess.run([str(compiler),"-s","-mwindows","-m32","-o","chunk.luac",name],cwd=tmp,check=True)
            compiled=(Path(tmp)/"chunk.luac").read_bytes()
            if not compiled.startswith(b"\x1bLua\x51\x0d\x01\x04\x04\x04\x04"):
                raise ValueError(f"Incompatible T6 bytecode for {name}")
            entries.append(f"    {{{json.dumps(name)}, {len(data)}, {len(script)}, {len(compiled)}, 0}},")
            data.extend(script)
            data.extend(compiled)
    blob=out/"mp-lua.bin"
    blob.write_bytes(data)
    (out/"mp-lua.inc").write_text("\n".join(entries)+"\n")
    return ('.section __TEXT,__const\n.globl _bo2_mp_lua_bytes\n'
            f'_bo2_mp_lua_bytes:\n.incbin {json.dumps(str(blob))}\n')


def link(root, mode, vpx, unicorn, online=False, private_server=False, lua_zip=None, hksc=None):
    src = root/"conversion"
    tc = root/"tc"
    work = src/"boot_cache"/mode
    output = root/"device"/mode
    output.mkdir(parents=True, exist_ok=True)
    os.environ.update(BO2_TOOLCHAIN=str(tc), BO2_TARGET=mode, LLVM17=str(tc/"llvm@17"),
                      BOOT_WORKDIR=str(work), REMILL_SEMANTICS_DIR=str(tc/"remill/build/lib/Arch/X86/Runtime"))
    sys.path[:0] = [str(src/"tools"), str(tc/"python")]
    import boot_ios_private as boot
    sys.modules["boot"] = boot
    import lift_extra
    sdk = subprocess.check_output(["xcrun","--sdk","iphoneos","--show-sdk-path"],text=True).strip()
    clang = ["xcrun","clang++","-target","arm64-apple-ios16.0","-isysroot",sdk]
    def run(cmd):
        subprocess.run(cmd, check=True)
    def compile_file(path, flags=()):
        obj = output/(path.name+".o")
        options = ["-std=c++17"] if path.suffix != ".c" else []
        if path.suffix == ".mm": options.append("-fobjc-arc")
        includes = [tc/"remill/include",tc/"unicorn/include",tc/"libvpx/include",
                    src/"runtime/win32",src/"third_party/HLSLcc/include",root/"ios"]
        run(clang+options+list(flags)+["-DADDRESS_SIZE_BITS=32","-DBO2_NO_EXTRA_LIFTED","-DBO2_TARGET_"+mode.upper(),
            *["-I"+str(p) for p in includes],"-O1","-c",str(path),"-o",str(obj)])
        return obj

    extra = [] if mode=="sps" else ["win32/cull_native.cpp","win32/match_rules.cpp"]
    sources = [src/"runtime"/name for name in (*RUNTIME,*extra)]
    sources.append(root/"ios/SteamRuntimeProvider.mm")
    if online: sources.append(root/"ios/dw_online.cpp")
    # The Steam transport replaces the guest's Winsock imports when the launcher asks for it at startup.
    switches = {"remaining_dlls_impl.cpp": ["-DBO2_NATIVE_WINSOCK"], "dw_online.cpp": ["-DBO2_DW_ACCOUNT_SESSION"]}
    with ThreadPoolExecutor(2) as pool:
        runtime = list(pool.map(lambda path: compile_file(path, switches.get(path.name, ()) if online else ()),sources))
    bridge = compile_file(root/"ios/GameSurface.mm")
    entry = output/"guest-entry.cpp"
    generated = (work/"main.cpp").read_text()
    registration = re.compile(r'^\s*register_jump_target\((0x[0-9a-f]+), (sub_[0-9a-f]+)\);$', re.M)
    rows=registration.findall(generated)
    if not rows or len(rows)!=generated.count("register_jump_target(0x"):
        raise ValueError("Unrecognized generated registration table")
    first=registration.search(generated)
    # Xcode's compiler crashes optimizing tens of thousands of straight-line calls.
    # Preserve their order, including aliases, in a constant pointer table.
    table="\n    static const struct { uint32_t va; decltype(&"+rows[0][1]+") fn; } entries[] = {\n"
    table+="".join("        {"+va+", "+symbol+"},\n" for va,symbol in rows)
    table+="    };\n    for (const auto &e : entries) register_jump_target(e.va, e.fn);\n"
    generated=generated[:first.start()]+table+registration.sub("",generated[first.end():])
    entry.write_text('#define main bo2_guest_main\n'+generated+
        '\nextern "C" int bo2_ios_start(const char *sections) {\n'
        '    char name[] = "BO2";\n    char *args[] = {name, const_cast<char *>(sections), nullptr};\n'
        '    return bo2_guest_main(2, args);\n}\n')
    host = compile_file(entry)
    inputs = [Path(p).with_suffix(".ios.o") for p in json.loads((work/"ios-units.json").read_text())]
    if not all(p.is_file() for p in inputs):
        raise RuntimeError("The conversion has not finished producing iOS objects")
    nm = str(tc/"llvm@17/bin/llvm-nm")
    def defined(objects):
        text = subprocess.check_output([nm,"--defined-only","--extern-only","-j",*map(str,objects)],text=True)
        return set(re.findall(r"^_sub_[a-fA-F0-9]+(?:_impl\d*)?$", text, re.M))
    guest_symbols = defined(inputs)
    # Recreate the original bodies underneath upstream's optimized wrappers.
    lift_extra.WORKDIR = str(output/"native-fallbacks")
    fallbacks = FALLBACKS[mode].split()
    os.environ.update(BO2_INLINE_FLAGS="1", BO2_INLINE_TRIV="1", BO2_INLINE_READS="1", BO2_INLINE_WRITES="1")
    if len(lift_extra.lift(fallbacks)) != len(fallbacks):
        raise RuntimeError("Incomplete native fallback conversion")
    for va in fallbacks:
        bc = Path(lift_extra.WORKDIR)/f"func_{va}.bc.fixed"
        obj = output/f"fallback-{va}.o"
        run(clang+["-O2","-x","ir","-c",str(bc),"-o",str(obj)])
        renamed = output/f"fallback-{va}-impl.o"
        run([str(tc/"llvm@17/bin/llvm-objcopy"),"--redefine-sym",f"_sub_{va}=_sub_{va}_impl",str(obj),str(renamed)])
        inputs.append(renamed)
    overrides = {f"_sub_{n:x}" for n in boot.SHIM_DEFINED}
    for i,obj in enumerate(runtime):
        overlap = sorted((defined([obj]) & guest_symbols)-overrides)
        if overlap:
            local = obj.with_suffix(".localized.o")
            run(["xcrun","ld","-r","-arch","arm64","-platform_version","ios","16.0","26.0",
                 *[arg for sym in overlap for arg in ("-unexported_symbol",sym)],"-o",str(local),str(obj)])
            runtime[i] = local
    interpose = work/"t6sp_interpose_stubs.cpp"
    if interpose.exists(): runtime.append(compile_file(interpose))
    hlsl = src/"third_party/HLSLcc"
    names = re.search(r"set\(HLSLCC_SRC\s+(.*?)\)",(hlsl/"CMakeLists.txt").read_text(),re.S).group(1).split()
    def compile_hlsl(name):
        path=hlsl/name
        obj=output/(path.name+".o")
        compiler="clang" if path.suffix==".c" else "clang++"
        run(["xcrun",compiler,*clang[2:],*([] if path.suffix==".c" else ["-std=c++11"]),
            *["-I"+str(hlsl/inc) for inc in (".","include","src","src/cbstring","src/internal_includes")],
            "-O2","-c",str(path),"-o",str(obj)])
        return obj
    with ThreadPoolExecutor(2) as pool:
        shader_objects=list(pool.map(compile_hlsl,names))
    targets = {}
    transport = []
    sections = output/"pluto_pe_sections.bin"
    sections.unlink(missing_ok=True)
    if private_server:
        targets = {name: va[mode=="zms"] for name,va in HOOKS.items() if va[mode=="zms"] is not None}
        lua_asm = prepare_mp_lua(lua_zip,hksc,output) if mode=="mps" else ""
        shim = output/"lan.o"
        run(clang+["-std=c++17","-O2","-DADDRESS_SIZE_BITS=32","-DBO2_PLUTONIUM_ZOMBIES="+str(int(mode=="zms")),
            "-I"+str(tc/"remill/include"),"-I"+str(src/"runtime/win32"),"-I"+str(output),
            "-c",str(root/"ios/PlutoniumLAN.cpp"),"-o",str(shim)])
        # Room for each taken-over entry's first three instructions and a branch back.
        asm = output/"entry.S"
        asm.write_text(".text\n.p2align 2\n"+"".join(
            f".globl _pluto_original_{name}\n_pluto_original_{name}:\n.rept 6\n nop\n.endr\n" for name in targets)+lua_asm)
        trampoline = output/"entry.o"
        run(clang+["-c",str(asm),"-o",str(trampoline)])
        transport = [shim,trampoline]
    framework = output/(mode+".framework")
    framework.mkdir(exist_ok=True)
    binary=framework/mode
    cmd = clang+["-dynamiclib","-install_name",f"@rpath/{mode}.framework/{mode}","-o",str(binary),
        *map(str,[host,bridge,*inputs,*runtime,*shader_objects,*transport,vpx,unicorn]),
        "-lz","-lc++",*[a for f in ("Foundation","UIKit","Metal","QuartzCore","GameController",
        "AudioToolbox","CoreGraphics","ImageIO","CoreFoundation") for a in ("-framework",f)]]
    attempt=subprocess.run(cmd,capture_output=True,text=True)
    (output/"first-link.log").write_text(attempt.stderr)
    if attempt.returncode:
        # Upstream's second pass accounts for Campaign-only interposes referenced
        # by common shim code. As upstream does, abort loudly if one is ever called.
        missing=sorted(set(re.findall(r'^  "_(sub_[a-f0-9]{6}(?:_impl\d*)?)",',attempt.stderr,re.M)))
        if not missing or any("_"+name in guest_symbols for name in missing):
            raise RuntimeError(f"Unresolved native link; see {output}/first-link.log")
        diagnostics=output/"interpose-diagnostics.cpp"
        diagnostics.write_text('#include <cstdio>\n#include <cstdlib>\n'+''.join(
            'extern "C" void* '+name+'(void*,unsigned,void*) { '
            'std::fputs("[TARGET] '+name+' has no implementation for this mode\\n",stderr); std::abort(); }\n'
            for name in missing))
        run(cmd+[str(compile_file(diagnostics))])
    target = boot._T
    redirects = {target["longjmp"]: "_bo2_longjmp", **target["redirects"]}
    patched = subprocess.run([sys.executable, str(src/"tools/patch_redirect.py"), str(binary),
         *[f"_sub_{address:x}={symbol}" for address, symbol in redirects.items()]],
         check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).stdout
    print(patched, flush=True)
    if "patch_redirect: skipping" in patched:
        raise RuntimeError(f"{mode} link skipped one or more runtime redirects")
    if not any(line.startswith(f"patched _sub_{target['longjmp']:x} @") and "longjmp" in line for line in patched.splitlines()):
        raise RuntimeError(f"{mode} link omitted its longjmp redirect")
    if private_server:
        from patch_redirect import branch_thunk, symbol_addrs, text_mapping
        import plutonium_sections
        triples = [(f"_sub_{va:x}","_bo2_pluto_"+name,"_pluto_original_"+name) for name,va in targets.items()]
        addresses = symbol_addrs(str(binary),[n for t in triples for n in t])
        data = bytearray(binary.read_bytes())
        vm,file_offset = text_mapping(data)
        for entry_name,new,original in triples:
            at,to,tramp = (addresses[n] for n in (entry_name,new,original))
            off = file_offset+at-vm
            ops = struct.unpack_from("<3I",data,off)
            # Only a stack allocation and frame-register saves may be moved. Reject anything else.
            for op in ops:
                if not (op&0xffc003ff==0xd10003ff or op&0xff0003e0==0xa90003e0 or op&0xffc003e0==0x6d0003e0):
                    raise ValueError(f"Unsupported entry instruction {op:#x} in {entry_name}")
            toff = file_offset+tramp-vm
            if struct.unpack_from("<6I",data,toff)!=(0xd503201f,)*6:
                raise ValueError("Original entry was not reserved for relocation")
            struct.pack_into("<6I",data,toff,*ops,*branch_thunk(tramp+12,at+12))
            struct.pack_into("<3I",data,off,*branch_thunk(at,to))
        binary.write_bytes(data)
        sections.write_bytes(plutonium_sections.converted(mode,(work/"pe_sections.bin").read_bytes()))
    info=dict(CFBundleExecutable=mode,CFBundleIdentifier="org.bo2.full."+mode,
              CFBundleName=mode,CFBundlePackageType="FMWK",CFBundleVersion="1",
              CFBundleShortVersionString="1.0",MinimumOSVersion="16.0")
    (framework/"Info.plist").write_bytes(plistlib.dumps(info))


if __name__=="__main__":
    p=ArgumentParser(description=__doc__)
    p.add_argument("root",type=Path)
    p.add_argument("mode",choices=FALLBACKS)
    p.add_argument("--vpx",required=True,type=Path)
    p.add_argument("--unicorn",required=True,type=Path)
    p.add_argument("--online",action="store_true",help="add the Steam network transport")
    p.add_argument("--private-server",action="store_true",help="add the LAN-mode server transport")
    p.add_argument("--lua-zip",type=Path,help="your r5369 Multiplayer interface scripts (Multiplayer private server)")
    p.add_argument("--hksc",type=Path,help="the Hksc compiler built for T6 (Multiplayer private server)")
    a=p.parse_args()
    if a.mode=="sps" and (a.online or a.private_server): p.error("Campaign has no network transport")
    if a.private_server and a.mode=="mps" and not (a.lua_zip and a.hksc):
        p.error("a Multiplayer private-server link needs --lua-zip and --hksc")
    link(a.root.resolve(),a.mode,a.vpx.resolve(),a.unicorn.resolve(),a.online,a.private_server,
         a.lua_zip and a.lua_zip.resolve(),a.hksc and a.hksc.resolve())
