#!/bin/zsh
set -euo pipefail

task_root=${0:A:h:h}
task_pj="$task_root/vendor/pjproject"
task_output="$task_root/build/headless/macos-arm64"
task_prefix=/opt/homebrew
task_expected=5a457451fa2712ba18e12b01738e8ff3af2b26fd
task_tag=2.17
task_repository=https://github.com/pjsip/pjproject.git
task_patch="$task_root/patches/pjproject-2.17-jio.patch"

if [[ $(uname -m) != arm64 ]]; then
  print -u2 "This macOS build currently targets Apple silicon."
  exit 2
fi

for task_formula in opencore-amr vo-amrwbenc pkgconf openssl@3; do
  if ! brew list --versions "$task_formula" >/dev/null 2>&1; then
    brew install "$task_formula"
  fi
done

if [[ ! -d "$task_pj/.git" ]]; then
  git clone --branch "$task_tag" --depth 1 "$task_repository" "$task_pj"
  git -C "$task_pj" checkout --detach "$task_expected"
  git -C "$task_pj" apply "$task_patch"
fi

if [[ $(git -C "$task_pj" rev-parse HEAD) != "$task_expected" ]]; then
  print -u2 "Unexpected pjproject revision; refusing an unreviewed build."
  exit 3
fi
if ! git -C "$task_pj" apply --reverse --check "$task_patch"; then
  print -u2 "The required reviewed Jio interoperability patches are missing or changed."
  exit 4
fi

cp "$task_root/engine/jiojoin_engine.c" "$task_pj/pjsip-apps/src/samples/jiojoin_engine.c"
cp "$task_root/engine/jiojoin_platform.h" "$task_pj/pjsip-apps/src/samples/jiojoin_platform.h"
cp "$task_root/engine/jiojoin_protocol.h" "$task_pj/pjsip-apps/src/samples/jiojoin_protocol.h"

cd "$task_pj"
if [[ -f build.mak ]]; then make clean; fi
./configure --disable-video \
  --disable-gsm-codec \
  --disable-g7221-codec \
  --disable-speex-codec \
  --disable-speex-aec \
  --disable-ilbc-codec \
  --disable-opus \
  --with-opencore-amr="$task_prefix" \
  --with-opencore-amrwbenc="$task_prefix" \
  --with-ssl="$task_prefix/opt/openssl@3"
make dep
make
make -C pjsip-apps/build samples

task_engine=$(find "$task_pj/pjsip-apps/bin/samples" -type f -name jiojoin_engine -perm +111 | head -1)
mkdir -p "$task_output"
cp "$task_engine" "$task_output/jiojoin-engine"
"$task_root/Scripts/test-engine-protocol.sh" "$task_output/jiojoin-engine"
print "$task_output/jiojoin-engine"
