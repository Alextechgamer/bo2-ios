#!/bin/bash
# setup.sh <work-folder> [stage ...]
#
# Builds your own iPhone app from your own Steam copy of Black Ops II, on an Apple silicon Mac.
# Run it again after a stop: each stage skips what is already there.
#
# Before the first run:
#   1. Install bo2-mac's "Black Ops II.app" (https://github.com/adrbn/bo2-mac) and let it find your game.
#      This script uses the translation tools inside that app.
#   2. Put your three unpacked executables in ~/.bo2-native/steam/, as bo2-mac's README describes.
#   3. Install Xcode, then: brew install xcodegen cmake
#
# Stages, in order (default: all of them):
#   check     tools, disk space, executables
#   source    bo2-mac v0.2.0-test.4 plus ios/runtime.patch, into <work>/conversion
#   deps      libvpx and the no-JIT Unicorn, built for iOS (and Hksc, when PLUTO_LUA_ZIP is set)
#   convert   translate the three executables (long)
#   fold      compile the translation with its helpers folded in, at -O2 (long)
#   link      one framework per mode, with the network transports below
#   package   the IPA
#
# Settings, as environment variables:
#   BO2MAC_APP   default "/Applications/Black Ops II.app"
#   BO2_INPUTS   default ~/.bo2-native/steam
#   MODES        default "sps mps zms"
#   JOBS         parallel compiles, default 3
#   RECEIPT      your SteamOwnership.plist from ios/steam_receipt.py; without it every mode needs a Steam sign-in (package)
#   BUNDLE_ID    your bundle identifier, for example com.example.bo2        (package)
#   TEAM         your Apple team. Leave unset for an unsigned IPA to sign with SideStore or a signing service.
#   GAME_ZIP     a ZIP of your game folder to put inside the app. Without it the app starts with no game files.
#   LIBRARY_ORIGIN  HTTPS origin of your private library installer (docs/PRIVATE-SERVERS.md), for use without GAME_ZIP
#   ONLINE       1 (default) links the Steam network transport into Multiplayer and Zombies; 0 leaves it out
#   PRIVATE_SERVER  1 (default) links the LAN-mode server transport into Zombies, and into Multiplayer
#                when PLUTO_LUA_ZIP is set; 0 leaves it out
#   SERVER_IP    private IPv4 address to preset in the Join menu and the USB fallback
#   PLUTO_LUA_ZIP  your own capture of the nine r5369 Multiplayer interface scripts
set -eu -o pipefail
[ $# -ge 1 ] || { sed -n '2,38p' "$0"; exit 2; }
mkdir -p "$1"; ROOT=$(cd "$1" && pwd); shift
HERE=$(cd "$(dirname "$0")" && pwd)
STAGES=${*:-check source deps convert fold link package}
APP=${BO2MAC_APP:-/Applications/Black Ops II.app}
INPUTS=${BO2_INPUTS:-$HOME/.bo2-native/steam}
MODES=${MODES:-sps mps zms}
JOBS=${JOBS:-3}
UPSTREAM=218dc8040956c0ec033eed02fe39866b7967892a   # bo2-mac v0.2.0-test.4
VPX=v1.15.2
TCI=e3f075a62742913bb734a55a474aec65c9e5745e          # github.com/1rhino2/unicorn-tci
HKSC=afa5ace6b2d11891b094ca637ccc772b9ef4ea59         # github.com/Jake-NotTheMuss/hksc
ONLINE=${ONLINE:-1}
PRIVATE_SERVER=${PRIVATE_SERVER:-1}
# The link stage changes folder, so the scripts' path is made absolute here.
if [ -n "${PLUTO_LUA_ZIP:-}" ]; then
  [ -f "$PLUTO_LUA_ZIP" ] || { echo "setup: PLUTO_LUA_ZIP does not name a file" >&2; exit 1; }
  PLUTO_LUA_ZIP=$(cd "$(dirname "$PLUTO_LUA_ZIP")" && pwd)/$(basename "$PLUTO_LUA_ZIP")
  case $PLUTO_LUA_ZIP in *" "*) { echo "setup: PLUTO_LUA_ZIP must be a path without spaces" >&2; exit 1; };; esac
fi
# Multiplayer's private-server link compiles nine interface scripts that only a capture from your own server provides.
mp_private() { [ "$PRIVATE_SERVER" = 1 ] && [ -n "${PLUTO_LUA_ZIP:-}" ]; }
say() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "setup: $*" >&2; exit 1; }

stage_check() {
  [ "$(uname -m)" = arm64 ] || die "an Apple silicon Mac is needed"
  for tool in git python3 xcodegen cmake make; do command -v $tool >/dev/null || die "$tool is not installed"; done
  xcrun --sdk iphoneos --show-sdk-path >/dev/null || die "Xcode with the iPhone SDK is not installed"
  [ -d "$APP/Contents/Resources/toolchain/llvm@17" ] || die "bo2-mac's tools were not found in $APP (set BO2MAC_APP)"
  for exe in t6sp t6mp t6zm; do
    [ -f "$INPUTS/$exe.exe.unpacked.exe" ] || die "$INPUTS/$exe.exe.unpacked.exe is missing"
  done
  tools=$(cat "$APP/Contents/Resources/version" 2>/dev/null || true)
  case $tools in *"${UPSTREAM:0:7}"*) ;; *) say "warning: bo2-mac's tools are '$tools'; this setup was tested with ${UPSTREAM:0:7}";; esac
  free=$(df -g "$ROOT" | awk 'NR==2 {print $4}')
  [ "$free" -ge "${MIN_FREE_GB:-30}" ] || die "$ROOT has $free GB free; 30 is asked for (MIN_FREE_GB overrides)"
  say "check passed"
}

stage_source() {
  ln -sfn "$APP/Contents/Resources/toolchain" "$ROOT/tc"
  ln -sfn "$HERE" "$ROOT/ios"
  if [ ! -f "$ROOT/conversion/.ios-patched" ]; then
    rm -rf "$ROOT/conversion"
    git clone -q https://github.com/adrbn/bo2-mac "$ROOT/conversion"
    git -C "$ROOT/conversion" -c advice.detachedHead=false checkout -q $UPSTREAM
    git -C "$ROOT/conversion" apply -p1 "$HERE/runtime.patch"
    touch "$ROOT/conversion/.ios-patched"
  fi
  if [ ! -f "$ROOT/conversion/.ios-frame-timing" ]; then
    git -C "$ROOT/conversion" apply -p1 "$HERE/frame-timing.patch"
    touch "$ROOT/conversion/.ios-frame-timing"
  fi
  if [ ! -f "$ROOT/conversion/.ios-controller-friction" ]; then
    git -C "$ROOT/conversion" apply -p1 "$HERE/controller-friction.patch"
    touch "$ROOT/conversion/.ios-controller-friction"
  fi
  say "source ready"
}

stage_deps() {
  mkdir -p "$ROOT/deps"; cd "$ROOT/deps"
  if [ ! -f vpx-ios/libvpx.a ]; then
    [ -d libvpx-src ] || git -c advice.detachedHead=false clone -q --depth 1 --branch $VPX https://github.com/webmproject/libvpx libvpx-src
    mkdir -p vpx-ios
    (cd vpx-ios && ../libvpx-src/configure --target=arm64-darwin-gcc --disable-examples --disable-tools \
        --disable-docs --disable-unit-tests --disable-vp8-encoder --disable-vp9-encoder >configure.log \
      && make -j"$JOBS" >build.log 2>&1) || die "libvpx did not build; see $ROOT/deps/vpx-ios/build.log"
  fi
  if [ ! -f tci-device/libunicorn.a ]; then
    if [ ! -d interpreter ]; then
      git clone -q https://github.com/1rhino2/unicorn-tci interpreter
      git -C interpreter -c advice.detachedHead=false checkout -q $TCI
    fi
    cmake -S interpreter/unicorn-engine-sys-tci -B tci-device -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 -DCMAKE_OSX_SYSROOT="$(xcrun --sdk iphoneos --show-sdk-path)" \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DUNICORN_ARCH=x86 -DUNICORN_INTERPRETER=ON \
      -DUNICORN_LEGACY_STATIC_ARCHIVE=ON -DUNICORN_BUILD_TESTS=OFF -DUNICORN_INSTALL=OFF >tci.log 2>&1 \
      && cmake --build tci-device -j"$JOBS" >>tci.log 2>&1 || die "Unicorn did not build; see $ROOT/deps/tci.log"
  fi
  if mp_private && [ ! -x hksc/src/hksc ]; then
    if [ ! -d hksc ]; then
      git clone -q https://github.com/Jake-NotTheMuss/hksc hksc
      git -C hksc -c advice.detachedHead=false checkout -q $HKSC
    fi
    (cd hksc && ./configure --game=t6 --multi-plat --release >configure.log 2>&1 && make -j"$JOBS" >build.log 2>&1) \
      || die "Hksc did not build; see $ROOT/deps/hksc/build.log"
  fi
  for lib in vpx-ios/libvpx.a tci-device/libunicorn.a; do
    xcrun lipo -archs "$lib" | grep -qx arm64 || die "$lib is not an arm64 library"
  done
  say "deps ready"
}

# A mode is converted once its lift wrote the unit list and the stub object.
converted() { [ -s "$ROOT/conversion/boot_cache/$1/ios-units.json" ] && [ -s "$ROOT/conversion/boot_cache/$1/stubs.ios.o" ]; }

stage_convert() {
  todo=""; for mode in $MODES; do converted "$mode" || todo="$todo $mode"; done
  if [ -n "$todo" ]; then
    say "converting$todo; progress is in $ROOT/conversion/boot_cache/<mode>/ios-lift.log"
    # shellcheck disable=SC2086
    python3 -u "$HERE/convert_modes.py" "$ROOT/conversion" "$ROOT/tc" "$INPUTS" --modes $todo --lift-only --jobs 2
  fi
  say "convert ready"
}

stage_fold() {
  for mode in $MODES; do
    converted "$mode" || die "$mode is not converted yet"
    # The folded objects go next to the unit list, where the link looks for them.
    FOLD_OUT="$ROOT/conversion/boot_cache/$mode" bash "$HERE/fold_modes.sh" "$ROOT" "$mode" "$JOBS" \
      || die "$mode: some slices did not compile; see the .FAILED files in $ROOT/conversion/boot_cache/$mode"
  done
  say "fold ready"
}

stage_link() {
  cd "$ROOT"
  ln -sfn "$HERE" "$ROOT/ios"
  for mode in $MODES; do
    options=""
    if [ "$mode" != sps ]; then
      [ "$ONLINE" = 1 ] && options="--online"
      if [ "$mode" = zms ] && [ "$PRIVATE_SERVER" = 1 ]; then options="$options --private-server"; fi
      if [ "$mode" = mps ] && mp_private; then
        [ -x deps/hksc/src/hksc ] || die "Hksc is not built; run the deps stage with PLUTO_LUA_ZIP set"
        options="$options --private-server --lua-zip $PLUTO_LUA_ZIP --hksc deps/hksc/src/hksc"
      fi
    fi
    # A framework is kept only if it was linked with the same transports.
    if [ -f "device/$mode/$mode.framework/Info.plist" ] && [ "$(cat "device/$mode/link-options" 2>/dev/null)" = "$options" ]; then continue; fi
    say "linking $mode${options:+ ($options)}"
    rm -f "device/$mode/$mode.framework/Info.plist" "device/$mode/link-options"
    # shellcheck disable=SC2086
    python3 -u "$HERE/link_mode.py" "$ROOT" "$mode" --vpx deps/vpx-ios/libvpx.a --unicorn deps/tci-device/libunicorn.a $options \
      >"link-$mode.log" 2>&1 || die "$mode did not link; see $ROOT/link-$mode.log"
    echo "$options" >"device/$mode/link-options"
  done
  if [ "$PRIVATE_SERVER" = 1 ] && ! mp_private; then
    case " $MODES " in *" mps "*) say "Multiplayer has no private-server transport: PLUTO_LUA_ZIP is not set";; esac
  fi
  say "link ready"
}

stage_package() {
  [ -n "${BUNDLE_ID:-}" ] || die "set BUNDLE_ID for the package stage"
  mkdir -p "$ROOT/out" "$ROOT/package-work"
  options=""
  [ -n "${TEAM:-}" ] && options="--team $TEAM" || options="--unsigned"
  [ -n "${GAME_ZIP:-}" ] || options="$options --shell-only"
  [ -z "${LIBRARY_ORIGIN:-}" ] || options="$options --library-origin $LIBRARY_ORIGIN"
  [ -z "${SERVER_IP:-}" ] || options="$options --private-server $SERVER_IP"
  [ -z "${RECEIPT:-}" ] || options="$options --receipt $RECEIPT"
  # shellcheck disable=SC2086
  python3 "$HERE/package_game.py" "$ROOT" "${GAME_ZIP:-none}" "$ROOT/out/BlackOpsII.ipa" "$ROOT/package-work" \
    --bundle-id "$BUNDLE_ID" $options
  say "IPA: $ROOT/out/BlackOpsII.ipa"
}

for stage in $STAGES; do
  case $stage in
    check|source|deps|convert|fold|link|package) "stage_$stage";;
    *) die "unknown stage: $stage";;
  esac
done
