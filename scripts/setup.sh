#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/sync_engine.sh
npm --prefix web ci
npm --prefix web run build
swift build
