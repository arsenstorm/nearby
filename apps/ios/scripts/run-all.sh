#!/usr/bin/env bash
# Install on the simulator and the phone — the usual pair for testing a call.
set -euo pipefail
cd "$(dirname "$0")"
./run-device.sh
exec ./run-sim.sh
