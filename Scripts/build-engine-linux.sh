#!/usr/bin/env bash
set -euo pipefail

task_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
task_pj="$task_root/vendor/pjproject"
task_arch=$(uname -m)
task_output="$task_root/build/headless/linux-$task_arch"
task_expected=5a457451fa2712ba18e12b01738e8ff3af2b26fd
task_tag=2.17
task_repository=https://github.com/pjsip/pjproject.git
task_patch="$task_root/patches/pjproject-2.17-jio.patch"

if [[ $(uname -s) != Linux ]]; then
  echo "build-engine-linux.sh must run on Linux." >&2
  exit 2
fi
for task_command in git make gcc g++ pkg-config; do
  command -v "$task_command" >/dev/null || {
    echo "Missing build command: $task_command" >&2
    exit 3
  }
done

if [[ ! -d "$task_pj/.git" ]]; then
  git clone --branch "$task_tag" --depth 1 "$task_repository" "$task_pj"
  git -C "$task_pj" checkout --detach "$task_expected"
  git -C "$task_pj" apply "$task_patch"
fi

if [[ $(git -C "$task_pj" rev-parse HEAD) != "$task_expected" ]]; then
  echo "Unexpected pjproject revision; refusing an unreviewed build." >&2
  exit 4
fi
if ! git -C "$task_pj" apply --reverse --check "$task_patch"; then
  echo "The required reviewed Jio interoperability patches are missing or changed." >&2
  exit 5
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
  --with-opencore-amr=/usr \
  --with-opencore-amrwbenc=/usr \
  --with-ssl=/usr
make dep
make -j"$(getconf _NPROCESSORS_ONLN)"
make -C pjsip-apps/build samples

task_engine=$(find "$task_pj/pjsip-apps/bin/samples" -type f -name jiojoin_engine -perm -111 | head -1)
mkdir -p "$task_output"
cp "$task_engine" "$task_output/jiojoin-engine"
"$task_root/Scripts/test-engine-protocol.sh" "$task_output/jiojoin-engine"
echo "$task_output/jiojoin-engine"
