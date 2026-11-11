#!/bin/bash
# fold_modes.sh <root> <mode> [parallel=3] [only-slice]
#
# Rebuilds one mode's lifted objects for the iPhone with the memory, flag and compare helpers folded into
# the lifted code, at -O2. The plain conversion compiles each bitcode slice as lifted, at -O1, so every
# guest read, write and flag is an out-of-line call; on the phone those calls were about half of all samples.
#
#   <root>/conversion   the bo2-mac conversion tree (scripts/fold/*.py, tools/boot.py, boot_cache/<mode>)
#   <root>/tc           its prebuilt toolchain (llvm@17, python/capstone, remill)
#   <mode>              mps, sps or zms
#   FOLD_SRC            folder holding batch_N.bc, if not <root>/conversion/boot_cache/<mode>
#   FOLD_OUT            output folder, default <root>/fold/<mode>
#
# Writes batch_N.ios.o to the output folder and never touches boot_cache. Link them in place of
# boot_cache/<mode>/batch_N.ios.o; stubs, main.cpp and pe_sections.bin stay as they are. The filters are
# upstream's (conversion/scripts/fold_lift.sh), in upstream's order. With a slice number, only that slice
# is built: a dry run of the filters.
set -u -o pipefail
ROOT=$(cd "$1" && pwd); MODE=$2; PAR=${3:-3}; ONLY=${4:-}
case $MODE in mps|sps|zms) ;; *) echo "mode must be mps, sps or zms"; exit 2;; esac
cd "$ROOT/conversion"
export LC_ALL=C
TC=$ROOT/tc
# The filters import tools/boot.py, so they need the environment the lift ran with.
export BO2_TOOLCHAIN=$TC LLVM17=$TC/llvm@17 PYTHONPATH=$TC/python BO2_TARGET=$MODE
export REMILL_SEMANTICS_DIR=$TC/remill/build/lib/Arch/X86/Runtime
export L=$TC/llvm@17/bin W=${FOLD_SRC:-$PWD/boot_cache/$MODE} OUT=${FOLD_OUT:-$ROOT/fold/$MODE}
export FILTERS="python3 scripts/fold/stream_inline_wide.py | python3 scripts/fold/stream_fold.py | python3 scripts/fold/stream_inline_triv.py | python3 scripts/fold/stream_c27.py | python3 scripts/fold/stream_inline_writes.py | python3 scripts/fold/dedup_ll_globals.py | python3 scripts/fold/widen_guest_gep.py"
python3 -c "import capstone" 2>/dev/null || { echo "capstone not importable from $PYTHONPATH"; exit 1; }
mkdir -p "$OUT"
slice() {
  n="$1"; [ -s "$OUT/batch_$n.ios.o" ] && return
  rm -f "$OUT/batch_$n.FAILED"
  nice -n 10 bash -o pipefail -c "$L/llvm-dis -o - $W/batch_$n.bc | $FILTERS | $L/llvm-as -o $OUT/part_$n.bc" \
    2> "$OUT/part_$n.filters" || { echo filters > "$OUT/batch_$n.FAILED"; return; }
  # A filter that could not import the boot driver still exits 0 with every counter at zero.
  grep -q '\[fold\] [1-9]' "$OUT/part_$n.filters" || { echo "nothing folded" > "$OUT/batch_$n.FAILED"; return; }
  nice -n 10 xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -Wno-override-module -O2 -c -x ir \
    "$OUT/part_$n.bc" -o "$OUT/batch_$n.building" 2> "$OUT/part_$n.clang" || { echo clang > "$OUT/batch_$n.FAILED"; return; }
  mv "$OUT/batch_$n.building" "$OUT/batch_$n.ios.o"; rm -f "$OUT/part_$n.bc"
  echo "[$(date +%H:%M:%S)] slice $n done"
}
export -f slice
if [ -n "$ONLY" ]; then slice "$ONLY"; cat "$OUT/part_$ONLY.filters"; ls -la "$OUT" | tail -4; exit 0; fi
N=$(ls "$W"/batch_*.bc | wc -l | tr -d ' ')
echo "[$(date +%H:%M:%S)] $MODE: $N slices, $PAR parallel"
for n in $(seq 0 $((N - 1))); do echo "$(stat -f %z "$W/batch_$n.bc") $n"; done | sort -rn | cut -d' ' -f2 \
  | xargs -P "$PAR" -I{} bash -c 'slice {}'
DONE=$(ls "$OUT" | grep -c '^batch_[0-9]*\.ios\.o$'); BAD=$(ls "$OUT" | grep -c '\.FAILED$')
echo "[$(date +%H:%M:%S)] $MODE: objects $DONE of $N, failures $BAD"
[ "$DONE" = "$N" ] && [ "$BAD" = 0 ]
