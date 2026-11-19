#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
bash scripts/sync_engine.sh --no-dev
uv run --python 3.11 python scripts/package_app.py
