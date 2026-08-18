#!/usr/bin/env bash
set -euo pipefail

task_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
task_engine=${1:-}

if [[ -z "$task_engine" ]]; then
  task_engine=$(find "$task_root/vendor/pjproject/pjsip-apps/bin/samples" \
    -type f -name jiojoin_engine -perm -111 2>/dev/null | head -1)
fi
if [[ -z "$task_engine" || ! -x "$task_engine" ]]; then
  echo "A built jiojoin-engine path is required." >&2
  exit 2
fi

task_version=$("$task_engine" --version)
grep -Fq '"event":"hello"' <<<"$task_version"
grep -Fq '"protocol":1' <<<"$task_version"
grep -Fq '"engine_version":"0.8.0"' <<<"$task_version"

task_audio=$("$task_engine" --list-audio 2>/dev/null || true)
if [[ -n "$task_audio" ]]; then
  grep -Fq '"event":"audio-device-option"' <<<"$task_audio"
fi

task_idle=$(printf 'HELLO\nPING\nSTATUS\nNOT_A_COMMAND\nQUIT\n' | "$task_engine" 2>/dev/null)
grep -Fq '"event":"pong"' <<<"$task_idle"
grep -Fq '"event":"status"' <<<"$task_idle"
grep -Fq '"registered":false' <<<"$task_idle"
grep -Fq '"active_call":false' <<<"$task_idle"
grep -Fq '"message":"Unknown or unavailable command"' <<<"$task_idle"

if "$task_engine" --not-a-real-option >/dev/null 2>&1; then
  echo "Unknown command-line option unexpectedly succeeded." >&2
  exit 3
else
  task_status=$?
  [[ $task_status -eq 64 ]]
fi

echo "protocol_test=passed engine=$task_engine"
