#!/bin/bash
# tvlink in a Lima VM on a Mac, no Pi needed. Makes the VM once (tests/vm.yaml, tests/vm-setup.sh), then runs
# tests/vm-test.sh, which reinstalls from this checkout first. See docs/testing.md.
# Usage: tests/vm.sh    Look round: limactl shell tvlink    Start over: limactl delete -f tvlink
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 cpwillis (https://github.com/seslhq/tvlink)
set -euo pipefail
cd "$(dirname "$0")/.."
command -v limactl >/dev/null || { echo "Install Lima first: brew install lima" >&2; exit 1; }
if ! limactl list -q | grep -qx tvlink; then
  limactl start --name=tvlink --mount="$PWD" --tty=false tests/vm.yaml
  limactl shell --workdir "$PWD" tvlink sudo tests/vm-setup.sh
  limactl restart tvlink # a first install starts the kiosk at the next boot, as on a Pi
elif [ "$(limactl list -f '{{.Status}}' tvlink)" != Running ]; then
  limactl start tvlink
fi
limactl shell --workdir "$PWD" tvlink sudo tests/vm-test.sh
