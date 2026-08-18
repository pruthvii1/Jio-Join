#!/usr/bin/env bash
set -euo pipefail

task_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 -m unittest discover -s "$task_root/Tests/LinuxControllerTests" -p 'test_*.py' -v
python3 -m py_compile "$task_root/linux/jiojoin_controller.py"
python3 -m py_compile "$task_root/linux/jiojoin_desktop.py"
echo "linux_controller_tests=passed"
