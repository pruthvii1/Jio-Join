#!/usr/bin/env bash
set -euo pipefail

task_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
task_pj="$task_root/vendor/pjproject-windows"
task_output="$task_root/build/headless/windows-x86_64"
task_expected=5a457451fa2712ba18e12b01738e8ff3af2b26fd
task_patch="$task_root/patches/pjproject-2.17-jio.patch"

[[ "${MSYSTEM:-}" == MINGW64 ]] || { echo "Run from an MSYS2 MINGW64 shell." >&2; exit 2; }
[[ "$(uname -m)" == x86_64 ]] || { echo "Windows x86_64 is required." >&2; exit 2; }
for command in git make gcc g++ pkg-config; do command -v "$command" >/dev/null || { echo "Missing: $command" >&2; exit 3; }; done

if [[ ! -d "$task_pj/.git" ]]; then
  git -c core.autocrlf=false clone --branch 2.17 --depth 1 https://github.com/pjsip/pjproject.git "$task_pj"
  git -C "$task_pj" config core.autocrlf false
  git -C "$task_pj" checkout --detach "$task_expected"
  git -C "$task_pj" apply --ignore-space-change --ignore-whitespace "$task_patch"
fi
[[ $(git -C "$task_pj" rev-parse HEAD) == "$task_expected" ]] || { echo "Unexpected PJSIP revision." >&2; exit 4; }
git -C "$task_pj" apply --reverse --check --ignore-space-change --ignore-whitespace "$task_patch" || { echo "Reviewed Jio patch is missing or changed." >&2; exit 5; }

cp "$task_root/engine/jiojoin_engine.c" "$task_pj/pjsip-apps/src/samples/jiojoin_engine.c"
cp "$task_root/engine/jiojoin_platform.h" "$task_pj/pjsip-apps/src/samples/jiojoin_platform.h"
cp "$task_root/engine/jiojoin_protocol.h" "$task_pj/pjsip-apps/src/samples/jiojoin_protocol.h"
cd "$task_pj"
[[ ! -f build.mak ]] || make distclean
./configure --host=x86_64-w64-mingw32 --disable-video --disable-gsm-codec \
  --disable-g7221-codec --disable-speex-codec --disable-speex-aec \
  --disable-ilbc-codec --disable-opus --with-opencore-amr=/mingw64 \
  --with-opencore-amrwbenc=/mingw64 --with-ssl=/mingw64
make dep
make -j"${NUMBER_OF_PROCESSORS:-2}" lib
make -C pjsip-apps/build -f Samples.mak jiojoin_engine
engine=$(find pjsip-apps/bin/samples -type f -iname 'jiojoin_engine*.exe' | head -1)
[[ -n "$engine" ]] || { echo "Windows engine was not produced." >&2; exit 6; }
mkdir -p "$task_output"
cp "$engine" "$task_output/jiojoin-engine.exe"
for dll in libgcc_s_seh-1.dll libstdc++-6.dll libwinpthread-1.dll libssl-3-x64.dll libcrypto-3-x64.dll libopencore-amrnb-0.dll libopencore-amrwb-0.dll; do
  [[ ! -f "/mingw64/bin/$dll" ]] || cp "/mingw64/bin/$dll" "$task_output/"
done
"$task_output/jiojoin-engine.exe" --self-test
"$task_root/Scripts/test-engine-protocol.sh" "$task_output/jiojoin-engine.exe"
echo "$task_output/jiojoin-engine.exe"
