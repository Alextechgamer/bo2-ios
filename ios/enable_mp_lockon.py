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
    return module[:match.start()] + "declare i8 @bo2_local_lockon(i8)\n" + body + module[match.end():]


if __name__ == "__main__":
    Path(sys.argv[2]).write_text(enable_local_lockon(Path(sys.argv[1]).read_text()))
