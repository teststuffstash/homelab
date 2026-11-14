"""The island's single GitHub CLI transport."""

import subprocess


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["gh", *args], capture_output=True, text=True, check=False)
