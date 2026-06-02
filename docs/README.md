# Homelab documentation

Service- and operations-level docs for the homelab. Infrastructure-as-code lives elsewhere
in the repo (`tofu/`, `ansible/`, `esphome/`, `homeassistant/`); these pages describe how the
running services fit together, how to operate them, and their risks.

## Services

| Service | Doc | Summary |
|---|---|---|
| Office plants (irrigation) | [office-plants/](office-plants/README.md) | PricelessToolkit Droplet (ESP32) auto-waters 4 plants; thresholds & per-plant run-times in Home Assistant |

## Conventions

- One directory per service under `docs/`, each with a `README.md` written from a service
  perspective (what's deployed, how to configure, how to maintain, dependencies, risks, next steps).
- Diagrams as **Mermaid** (renders on GitHub) — prefer C4 context/container levels.
- Images go in the service's `images/` subdir, compressed (~1280 px, target <300 KB).
