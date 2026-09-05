# homelab#1308 — the docker-mode ride's env card. Set the DOCKER knob so render_env_card()
# takes the "Docker: YES" branch, which is where the new BuildKit-builder sentence lives
# (daemon.json's own registry-mirrors is Hub-only; a non-Hub FROM needs the docker-container
# builder pointed at $BUILDKITD_TOML — env var set in the DOCKER_ENV block, card text here).
DOCKER=1
