# Forgejo Actions runner (act_runner) — self-hosted CI. SLSA Build L2 / Phase-1 (docs/slsa.md):
# a hosted (not-a-laptop) build engine; cosign-signed provenance + SBOM come next. Placement is
# UNCONSTRAINED since 2026-09-20 (see the pod spec) — an idle fallback runner does not need a
# tier. A DinD sidecar gives job containers a Docker daemon (Talos has no host Docker socket);
# that needs a privileged pod, so the namespace is opted up to PodSecurity=privileged (same as
# monitoring).
#
# ROLLS WITH NO DOWNTIME since 2026-09-28 (ADR-140 as amended): two replicas, RollingUpdate with
# zero unavailable, and a PodDisruptionBudget of one — so an image bump Renovate lands on this
# Deployment (the docker:dind tag, homelab#2037's class) is a roll the management box may apply
# unattended, and a node drain never empties the runner pool. Each pod self-registers under its
# own name (`k8s-<pod>`), so two replicas are two runners in Forgejo, not a double registration.
#
# ⚠ Two-phase bootstrap (Actions must be ENABLED — tofu/forgejo.tf — and applied first):
#   1. Forgejo Actions are on in argocd/platform/forgejo.yaml (gitea.config.actions.ENABLED)
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
# ⚠ field_manager MUST be distinct: every kubernetes_labels resource defaults to manager
# "Terraform", and same-manager SSA applies prune each other's keys on a shared node — this
# resource silently deleted longhorn_bulk_zone's topology.kubernetes.io/zone off wk-metal-01
# (found 2026-07-14; a day of bulk-tier anti-affinity blindness).
# ⚠ wk-metal-01 LEFT this set 2026-09-16: it carries the garage-2 zone, and the storage ledger's
# zone-node envelope says no rides there. This resource force-applies the label the ARC scale sets
# AND the Forgejo runner below both select on, so leaving the node here would have re-asserted it on
# the next apply and put docker-in-docker CI back on the zone — the same ride class the kata removal
# evicts (review finding on PR#1729; the management-sentinel plan listed this resource as `update`).
# New members belong on the `arc` flag in machines/machines.yaml, not here — this set is the legacy
# home and should shrink to nothing as nodes move over.
# ⚠ EMPTY since 2026-09-20 — it did. wk-metal-02 was the last member and leaves the ride pool ahead
# of its control-plane reinstall (ADR-133 as amended, docs/controlplane-ha.md §CP5); wk-metal-03 now
# carries the pool on the `arc` flag instead. Destroying this resource REMOVES the label from
# wk-metal-02, which is the point: ARC runners and the Forgejo runner below (node_selector on the
# same label) stop scheduling there before the node is reset to maintenance. Kept at zero rather
# than deleted so the next node to need the legacy path finds the explanation, not an empty file.
resource "kubernetes_labels" "ephemeral_tier" {
  for_each    = toset([])
  api_version = "v1"
  kind        = "Node"
  metadata { name = each.value }
  labels        = { "homelab.io/ephemeral" = "true" }
  field_manager = "tofu-ephemeral-tier"
  force         = true # take ownership of the key from the old "Terraform" manager once
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
    # Two replicas + zero-unavailable rollout + the PDB below = the shape a STATELESS platform
    # Deployment must have before its image bumps may arm (ADR-140 as amended, 2026-09-28). The
    # old `replicas = 1` + `Recreate` pair meant every image bump was a runner outage — the reason
    # #2037 (docker:27-dind → 29-dind) sat on the human lane. Registration is per pod (emptyDir,
    # name = pod hostname), so a surge pod registers as a NEW runner; the one it replaces goes
    # offline in Forgejo's list — stale offline records are a later API sweep, not a correctness
    # problem (Forgejo schedules only on online runners).
    replicas = 2
    selector { match_labels = { app = "forgejo-runner" } }
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = "0"
        max_surge       = "1"
      }
    }
    template {
      metadata { labels = { app = "forgejo-runner" } }
      spec {
        # --- placement: ANYWHERE (operator, 2026-09-20) ---
        # It used to pin to the ephemeral laptop tier, from the SLSA reading that a build engine
        # belongs on disposable hardware. That reason has expired from both ends: the tier's label
        # is now a per-node `arc` flag that just moved off wk-metal-02 for its control-plane
        # reinstall (#1814), and Forgejo itself is the GitHub-outage FALLBACK, not a live read path
        # — one mostly-idle runner, not a pool. So no node_selector: it lands wherever the
        # scheduler has room.
        # The toleration STAYS, and that is what makes "anywhere" true: without it the tainted ride
        # nodes — a good chunk of the fleet — would be the one place it could not go.
        toleration {
          key      = "homelab.io/ephemeral"
          operator = "Exists"
        }
        # Two replicas on two nodes when the scheduler can (soft): the PDB serializes a graceful
        # drain either way, this only keeps an unplanned single-node failure from taking the
        # whole pool — a preference, never a constraint (a one-node-left cluster still schedules).
        affinity {
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                topology_key = "kubernetes.io/hostname"
                label_selector { match_labels = { app = "forgejo-runner" } }
              }
            }
          }
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
          # FU-082: requests are deliberately small — CI builds spike unpredictably and a TIGHT
          # memory limit would OOM job containers mid-build.
          # The limit above them is new (2026-09-20) and is a BLAST-RADIUS CAP, not a sizing
          # statement: the old "requests only" posture was justified by this pod owning a
          # dedicated ephemeral node, and unpinning it (see the pod spec) removed exactly that
          # isolation — an unbounded privileged DinD sidecar can now land beside real services.
          # 4Gi is chosen to be far above any build this fallback runner has ever done and far
          # below what would hurt the smallest node it can land on (8 GiB). A build that
          # legitimately needs more should RAISE this deliberately, which is the point of having
          # a number at all.
          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { memory = "4Gi" }
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
                --name "k8s-$(hostname)" \
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
          # Ready = REGISTERED, not merely running (review finding on PR#2078): a probe-less
          # container counts Ready the moment it starts, so the roll's `max_unavailable 0` and the
          # PDB's `min_available 1` would both have gated on dind's health while the runner was
          # still waiting for dind / registering. `.runner` is what `forgejo-runner register`
          # writes just before the script execs the daemon — the real "this pod can take a job"
          # signal this Deployment has.
          readiness_probe {
            exec { command = ["test", "-f", "/data/.runner"] }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
          resources { # FU-082: the daemon itself is light (~50Mi); requests-only, no throttle cap.
            requests = { cpu = "50m", memory = "128Mi" }
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
  # forgejo itself is an ArgoCD Application since 2026-08-04 (FU-136), so there is no tofu resource
  # left to depend on. The runner registers against a live Forgejo; if it starts first it retries.
}

# "May I lose a runner now?" lives with the service (ADR-140): a drain may take one pod, never
# both. With `replicas = 2` and `min_available = 1` a single-node maintenance window
# (scripts/node-maintenance.sh) evicts one runner and waits for its replacement to be Ready
# before the second could go; a budget already at 0 makes the drain refuse up front. The box
# applies this address unattended (policy/mgmt/plan-input.yaml `apply_addresses.main`).
resource "kubernetes_pod_disruption_budget_v1" "forgejo_runner" {
  metadata {
    name      = "forgejo-runner"
    namespace = kubernetes_namespace.forgejo_runner.metadata[0].name
  }
  spec {
    min_available = "1"
    selector { match_labels = { app = "forgejo-runner" } }
  }
}

output "forgejo_runner" {
  value = "act_runner ×2 in ns forgejo-runner, unpinned (any schedulable node), RollingUpdate + PDB minAvailable 1; verify: Forgejo → Admin → Actions → Runners"
}
