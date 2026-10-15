"""`python -m agent_gateway` — uvicorn on :8080."""

from __future__ import annotations

import os

import uvicorn

from .app import create_app
from .config import Settings
from .logging import configure


def main() -> None:
    configure(os.environ.get("GATEWAY_LOG_LEVEL", "INFO"))
    app = create_app(Settings.from_env())
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("GATEWAY_PORT", "8080")), log_config=None, access_log=False)


if __name__ == "__main__":
    main()
