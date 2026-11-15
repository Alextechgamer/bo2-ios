"""Instrument the controller lock-on routines in MP slice 46 and Zombies slice 41."""
import re
import sys
from pathlib import Path


def enable_local_lockon(module, mode="mps"):
    function, getter, write, address, target = {
        "mps": ("48e3c0", "754c40", 1477, 1475, 1476),
        "zms": ("48e5a0", "755e50", 1480, 1478, 1479),
    }[mode]
    match = re.search(rf"^define [^\n]*@sub_{function}\([^\n]*\n.*?^}}", module, re.M | re.S)
    if not match:
        raise ValueError("Missing MP controller lock-on function")
    body = match[0]
    anchor = "  %173 = load i8, ptr %AL, align 1"
    if body.count(anchor) != 1 or f"%145 = tail call ptr @sub_{getter}" not in body[:body.index(anchor)]:
        raise ValueError("Unsupported MP lock-on getter")
    body = body.replace(anchor, "  %stockLock = load i8, ptr %AL, align 1\n"
                        "  %173 = call i8 @bo2_local_lockon(i8 %stockLock)")
    range_store = "  store float %1371, ptr %XMM0, align 1"
    memory = 1454 if mode == "mps" else 1457
    target_store = f"  %{write} = tail call ptr @__remill_write_memory_32(ptr noundef %{memory}, i32 noundef %{address}, i32 noundef %{target})"
    if body.count(range_store) != 1 or body.count(target_store) != 1:
        raise ValueError("Unsupported MP target selector")
    body = body.replace(range_store, "  %localRange = call float @bo2_lock_range(float %1371)\n"
                        "  store float %localRange, ptr %XMM0, align 1")
    body = body.replace(target_store, f"  call void @bo2_selected_target(i32 %{target})\n" + target_store)
    declarations = ("declare i8 @bo2_local_lockon(i8)\ndeclare float @bo2_lock_range(float)\n"
                    "declare void @bo2_selected_target(i32)\n")
    return module[:match.start()] + declarations + body + module[match.end():]


if __name__ == "__main__":
    Path(sys.argv[2]).write_text(enable_local_lockon(Path(sys.argv[1]).read_text(), *sys.argv[3:]))
