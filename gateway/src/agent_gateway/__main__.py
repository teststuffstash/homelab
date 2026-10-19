"""`python -m agent_gateway` — uvicorn on :8080."""

from __future__ import annotations

import os
import time

import uvicorn

from .app import create_app
from .codex import CodexBackend
from .config import Settings
from .logging import configure
from .native_oauth import NativeRefresh
from .sqlite_oauth import SqliteStore


def main() -> None:
    configure(os.environ.get("GATEWAY_LOG_LEVEL", "INFO"))
    settings = Settings.from_env()
    seed = os.environ.get("CODEX_SEED_FILE", "")
    backend = (CodexBackend(SqliteStore(settings.db_path, seed), NativeRefresh(time.time))
               if settings.upstreams.get("codex") and seed else None)
    app = create_app(settings, codex_backend=backend)
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("GATEWAY_PORT", "8080")), log_config=None, access_log=False)


if __name__ == "__main__":
    main()
