"""The island's single GitHub CLI transport."""

import os
import subprocess


def run(*args: str, token: str | None = None) -> subprocess.CompletedProcess[str]:
    """`gh <args>`; `token` overrides GH_TOKEN for this one call (the label identity, UPDATER_LABEL_TOKEN)."""
    env = {**os.environ, "GH_TOKEN": token} if token else None
    return subprocess.run(["gh", *args], capture_output=True, text=True, check=False, env=env)
