# Forgejo Actions runner (act_runner) — self-hosted CI. SLSA Build L2 / Phase-1 (docs/slsa.md):
# a hosted (not-a-laptop) build engine; cosign-signed provenance + SBOM come next. Runs on the
# ephemeral laptop tier (homelab.io/ephemeral) per the SLSA doc. A DinD sidecar gives job
# containers a Docker daemon (Talos has no host Docker socket); that needs a privileged pod, so
# the namespace is opted up to PodSecurity=privileged (same as monitoring).
#
# ⚠ Two-phase bootstrap (Actions must be ENABLED — tofu/forgejo.tf — and applied first):
#   1. devbox run -- tofu -chdir=tofu apply -target=helm_release.forgejo      # turn Actions on
#   2. TOKEN=$(devbox run -- kubectl --kubeconfig tofu/kubeconfig -n forgejo \
#        exec deploy/forgejo -- forgejo forgejo-cli actions generate-runner-token)
#      export TF_VAR_forgejo_runner_token="$TOKEN"                            # (or Admin → Actions → Runners)
#   3. devbox run -- tofu -chdir=tofu apply                                    # deploy the runner

variable "forgejo_runner_token" {
  description = "Forgejo runner registration token (out-of-repo; see bootstrap above). SOPS+age before public."
  type        = string
  sensitive   = true
}

locals {
  forgejo_runner_image = "code.forgejo.org/forgejo/runner:6.3.1"
  # Runner labels = what `runs-on:` matches. `docker` runs the job in a container via DinD;
  # `native` runs it directly in the runner image.
  forgejo_runner_labels = "docker:docker://node:22-bookworm,native:host"
}

# Label the ephemeral tier so workloads can SELECT it (the taint in metal.tf only repels others).
resource "kubernetes_labels" "ephemeral_tier" {
  for_each    = toset(["wk-metal-01", "wk-metal-02"])
  api_version = "v1"
  kind        = "Node"
  metadata { name = each.value }
  labels = { "homelab.io/ephemeral" = "true" }
}

resource "kubernetes_namespace" "forgejo_runner" {
  metadata {
    name   = "forgejo-runner"
    labels = { "pod-security.kubernetes.io/enforce" = "privileged" } # DinD needs privileged
  }
}

resource "kubernetes_secret" "forgejo_runner_registration" {
  metadata {
    name      = "registration"
    namespace = kubernetes_namespace.forgejo_runner.metadata[0].name
  }
  data = { token = var.forgejo_runner_token }
}

resource "kubernetes_deployment" "forgejo_runner" {
  metadata {
    name      = "forgejo-runner"
    namespace = kubernetes_namespace.forgejo_runner.metadata[0].name
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "forgejo-runner" } }
    strategy { type = "Recreate" } # single runner; don't double-register during rollout
    template {
      metadata { labels = { app = "forgejo-runner" } }
      spec {
        # --- pin to the ephemeral laptop tier (label above) + tolerate its taint ---
        node_selector = { "homelab.io/ephemeral" = "true" }
        toleration {
          key      = "homelab.io/ephemeral"
          operator = "Exists"
        }

        # --- DinD: the Docker daemon job containers run on. TLS off → tcp on localhost. ---
        container {
          name  = "dind"
          image = "docker:27-dind"
          security_context { privileged = true }
          env {
            name  = "DOCKER_TLS_CERTDIR"
            value = ""
          }
          args = ["--host=tcp://0.0.0.0:2375", "--tls=false"]
          volume_mount {
            name       = "docker-storage"
            mount_path = "/var/lib/docker"
          }
          readiness_probe {
            exec { command = ["docker", "info"] }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }

        # --- act_runner: register-if-needed, then run the daemon. ---
        container {
          name  = "runner"
          image = local.forgejo_runner_image
          env {
            name  = "DOCKER_HOST"
            value = "tcp://localhost:2375"
          }
          env {
            name = "RUNNER_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.forgejo_runner_registration.metadata[0].name
                key  = "token"
              }
            }
          }
          # Register once (writes .runner to the shared emptyDir), then run. No persistent
          # state on the ephemeral tier (no Longhorn there), so a restart re-registers — old
          # entries just show offline in Forgejo. Fine for Phase-1.
          command = ["/bin/sh", "-c"]
          args = [<<-EOT
            set -e
            cd /data
            # Wait for the dind sidecar's daemon — both containers start together, so without
            # this the runner reaches docker before dind is up, exits, and crash-loops (the 96
            # restarts we saw). The runner image has no `docker` CLI, so poll the daemon's HTTP
            # API _ping with wget (which it does have) instead.
            echo "waiting for dind at $DOCKER_HOST …"
            until wget -qO- http://localhost:2375/_ping >/dev/null 2>&1; do sleep 1; done
            echo "dind ready."
            if [ ! -f .runner ]; then
              forgejo-runner register --no-interactive \
                --instance http://forgejo-http.forgejo.svc.cluster.local:3000 \
                --token "$RUNNER_TOKEN" \
                --name "k8s-ephemeral-$(hostname)" \
                --labels "${local.forgejo_runner_labels}"
            fi
            exec forgejo-runner daemon
          EOT
          ]
          working_dir = "/data"
          volume_mount {
            name       = "runner-data"
            mount_path = "/data"
          }
        }

        volume {
          name = "docker-storage"
          empty_dir {}
        }
        volume {
          name = "runner-data"
          empty_dir {}
        }
      }
    }
  }
  depends_on = [helm_release.forgejo]
}

output "forgejo_runner" {
  value = "act_runner in ns forgejo-runner on the ephemeral tier; verify: Forgejo → Admin → Actions → Runners"
}
