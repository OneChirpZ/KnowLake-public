#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
extras=()
if [[ -f engine/knowlake_engine/private_modules.py ]]; then
    extras+=(--extra private-media --extra wechat-browser)
elif [[ "${KNOWLAKE_WECHAT_BROWSER:-0}" == 1 ]]; then
    extras+=(--extra wechat-browser)
fi
UV_PYTHON_PREFERENCE=only-managed uv sync --directory engine --locked ${extras[@]+"${extras[@]}"} "$@"
