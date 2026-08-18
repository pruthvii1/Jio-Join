#!/usr/bin/env bash
set -euo pipefail

task_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
task_pj="$task_root/vendor/pjproject-windows"
task_output="$task_root/build/headless/windows-x86_64"
task_vo="$task_root/vendor/vo-amrwbenc-windows"
task_expected=5a457451fa2712ba18e12b01738e8ff3af2b26fd
task_patch="$task_root/patches/pjproject-2.17-jio.patch"
task_vo_url=https://downloads.sourceforge.net/project/opencore-amr/vo-amrwbenc/vo-amrwbenc-0.1.3.tar.gz
task_vo_sha=5652b391e0f0e296417b841b02987d3fd33e6c0af342c69542cbb016a71d9d4e

[[ "${MSYSTEM:-}" == MINGW64 ]] || { echo "Run from an MSYS2 MINGW64 shell." >&2; exit 2; }
[[ "$(uname -m)" == x86_64 ]] || { echo "Windows x86_64 is required." >&2; exit 2; }
for command in curl git make gcc g++ perl pkg-config sha256sum tar; do command -v "$command" >/dev/null || { echo "Missing: $command" >&2; exit 3; }; done

if [[ ! -f "$task_vo/configure" ]]; then
  task_vo_archive="$task_root/vendor/vo-amrwbenc-0.1.3.tar.gz"
  curl -L --fail --retry 3 "$task_vo_url" -o "$task_vo_archive"
  echo "$task_vo_sha  $task_vo_archive" | sha256sum --check
  mkdir -p "$task_vo"
  tar -xzf "$task_vo_archive" -C "$task_vo" --strip-components=1
fi
(
  cd "$task_vo"
  ./configure --host=x86_64-w64-mingw32 --prefix=/mingw64
  make -j"${NUMBER_OF_PROCESSORS:-2}"
  make install
)

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
# When MSYS is the build host, PJSIP includes the MinGW .exe suffix in the
# sample object's source basename. Strip it only for that generated object.
perl -pi -e 's/SAMPLE_OBJS=\$\@\.o/SAMPLE_OBJS=\$\(basename \$\@\).o/' "$task_pj/pjsip-apps/build/Samples.mak"
grep -F 'SAMPLE_OBJS=$(basename $@).o' "$task_pj/pjsip-apps/build/Samples.mak" >/dev/null
cd "$task_pj"
[[ ! -f build.mak ]] || make distclean
./configure --host=x86_64-w64-mingw32 --disable-video --disable-gsm-codec \
  --disable-g7221-codec --disable-speex-codec --disable-speex-aec \
  --disable-ilbc-codec --disable-opus --with-opencore-amr=/mingw64 \
  --with-opencore-amrwbenc=/mingw64 --with-ssl=/mingw64
make dep
make -j"${NUMBER_OF_PROCESSORS:-2}" lib
# MSYS2 is the build host, so PJSIP otherwise leaves HOST_EXE empty even though
# the configured MinGW target emits Windows executables.
make -C pjsip-apps/build -f Samples.mak HOST_EXE=.exe \
  BINDIR=../bin/samples/x86_64-w64-mingw32 jiojoin_engine.exe
engine=$(find pjsip-apps/bin/samples -type f -iname 'jiojoin_engine*.exe' | head -1)
[[ -n "$engine" ]] || { echo "Windows engine was not produced." >&2; exit 6; }
mkdir -p "$task_output"
cp "$engine" "$task_output/jiojoin-engine.exe"
for dll in libgcc_s_seh-1.dll libstdc++-6.dll libwinpthread-1.dll libssl-3-x64.dll libcrypto-3-x64.dll libopencore-amrnb-0.dll libopencore-amrwb-0.dll libvo-amrwbenc-0.dll; do
  [[ ! -f "/mingw64/bin/$dll" ]] || cp "/mingw64/bin/$dll" "$task_output/"
done
cp "$task_pj/COPYING" "$task_output/pjproject-COPYING"
cp "$task_vo/COPYING" "$task_output/vo-amrwbenc-COPYING"
cp "$task_vo/NOTICE" "$task_output/vo-amrwbenc-NOTICE"
"$task_output/jiojoin-engine.exe" --self-test
"$task_root/Scripts/test-engine-protocol.sh" "$task_output/jiojoin-engine.exe"
echo "$task_output/jiojoin-engine.exe"
