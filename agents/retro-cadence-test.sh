#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 agents/retro-activity-test.py
python3 agents/retro-findings-test.py
python3 agents/retro-pipeline-test.py
