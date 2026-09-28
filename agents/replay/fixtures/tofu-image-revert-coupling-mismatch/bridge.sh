# A checkout stand-in: the candidate changed one tofu file, which declares the forgejo runner
# Deployment (metadata name "forgejo-runner") and nothing else.
T="$(mktemp -d)"; mkdir -p "$T/tofu"
printf 'resource "kubernetes_deployment" "forgejo_runner" {\n  metadata {\n    name      = "forgejo-runner"\n    namespace = "forgejo-runner"\n  }\n}\n' > "$T/tofu/forgejo-runner.tf"
cd "$T"
FILES='tofu/forgejo-runner.tf'
