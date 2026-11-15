"""Enable the T6 lock-on check for physical-controller local practice (MP slice 46)."""
import re
import sys
from pathlib import Path


def enable_local_lockon(module):
    match = re.search(r"^define [^\n]*@sub_48e3c0\([^\n]*\n.*?^}", module, re.M | re.S)
    if not match:
        raise ValueError("Missing MP controller lock-on function")
    body = match[0]
    anchor = "  %173 = load i8, ptr %AL, align 1"
    if body.count(anchor) != 1 or "%145 = tail call ptr @sub_754c40" not in body[:body.index(anchor)]:
        raise ValueError("Unsupported MP lock-on getter")
    body = body.replace(anchor, "  %stockLock = load i8, ptr %AL, align 1\n"
                        "  %173 = call i8 @bo2_local_lockon(i8 %stockLock)")
    range_store = "  store float %1371, ptr %XMM0, align 1"
    target_store = "  %1477 = tail call ptr @__remill_write_memory_32(ptr noundef %1454, i32 noundef %1475, i32 noundef %1476)"
    if body.count(range_store) != 1 or body.count(target_store) != 1:
        raise ValueError("Unsupported MP target selector")
    body = body.replace(range_store, "  %localRange = call float @bo2_lock_range(float %1371)\n"
                        "  store float %localRange, ptr %XMM0, align 1")
    body = body.replace(target_store, "  call void @bo2_selected_target(i32 %1476)\n" + target_store)
    declarations = ("declare i8 @bo2_local_lockon(i8)\ndeclare float @bo2_lock_range(float)\n"
                    "declare void @bo2_selected_target(i32)\n")
    return module[:match.start()] + declarations + body + module[match.end():]


if __name__ == "__main__":
    Path(sys.argv[2]).write_text(enable_local_lockon(Path(sys.argv[1]).read_text()))
