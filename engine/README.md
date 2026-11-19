# KnowLake engine

The Swift application starts a Python worker for individual library requests. The worker accepts one JSON request on standard input and returns progress and a result through newline-delimited JSON. The public build includes WeChat and local Markdown sources. The Swift application handles Codex generation and the engine archives its outputs.

```sh
uv run --directory engine --no-sync pytest -q
```

## WeChat browser support

The default installation reads articles over HTTP. To enable browser rendering, prepare the optional Camoufox runtime:

```sh
KNOWLAKE_WECHAT_BROWSER=1 bash scripts/setup.sh
cd engine
.venv/bin/python -m camoufox fetch
```

The application can also use a separately installed browser once the optional Python integration is installed. Configure its executable path in Settings. Pages that require manual verification are reported as acquisition failures.

## Library and configuration

SQLite, source snapshots and artifacts live in the selected library. The default library is `~/.KnowLake`. KnowLake creates application configuration at `~/.KnowLake/config.json` at runtime and keeps it outside library backups.
