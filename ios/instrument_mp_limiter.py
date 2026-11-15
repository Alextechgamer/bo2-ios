"""Instrument batch_0 LLVM IR from the supported MP conversion before folding."""
import re
import sys
from pathlib import Path


def instrument(module):
    match = re.search(r"^define [^\n]*@sub_6c5c80\([^\n]*\n.*?^}", module, re.M | re.S)
    if not match:
        raise ValueError("MP pacing function missing")
    body = match[0]

    def insert(anchor, extra):
        nonlocal body
        if body.count(anchor) != 1:
            raise ValueError(f"Unexpected MP conversion at {anchor}")
        body = body.replace(anchor, extra + "\n" + anchor)

    insert("  %149 = add", "  %diagUser = load i32, ptr %4, align 4")
    insert("  %173 = add", "  %diagMode = load i32, ptr %4, align 4")
    insert("  store i32 %NEXT_PC.1, ptr %PC", "  %diagCount = alloca i32\n  %diagTime = alloca i64\n  store i32 0, ptr %diagCount\n  store i64 0, ptr %diagTime")
    insert("  %739 = tail call ptr @sub_6db3e0", "  %diagStart = call i64 @bo2_pace_clock()")
    insert("  %740 = add", """  %diagEnd = call i64 @bo2_pace_clock()
  %diagDelta = sub i64 %diagEnd, %diagStart
  %diagPrevious = load i64, ptr %diagTime
  %diagTotal = add i64 %diagPrevious, %diagDelta
  store i64 %diagTotal, ptr %diagTime
  %diagOldCount = load i32, ptr %diagCount
  %diagNewCount = add i32 %diagOldCount, 1
  store i32 %diagNewCount, ptr %diagCount""")
    insert("  store i32 %NEXT_PC.6, ptr %PC", """  %diagWait = load i64, ptr %diagTime
  %diagCalls = load i32, ptr %diagCount
  call void @bo2_pace_report(i32 %diagUser, i32 %diagMode, i32 %293, i32 %diagCalls, i64 %diagWait)""")
    declarations = "declare i64 @bo2_pace_clock()\ndeclare void @bo2_pace_report(i32, i32, i32, i32, i64)\n"
    return module[:match.start()] + declarations + body + module[match.end():]


if __name__ == "__main__":
    Path(sys.argv[2]).write_text(instrument(Path(sys.argv[1]).read_text()))
