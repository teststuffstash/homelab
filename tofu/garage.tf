# Garage — self-hosted S3-compatible object store (Deuxfleurs), ADR-031.
# MINIMAL single-node trial: replication_factor 1, one StatefulSet replica, lmdb meta + data
# on replicated Longhorn. The convergence point for the sleep-tracking pipeline (ADR-045) — two
# write-only buckets (sleep-band, sleep-snore) + a read-only ingester key, created out-of-band
# (see docs/garage.md; keys are out-of-repo tfvars now, SOPS+age before public — ADR-061).
#
# ACCESS MODEL = LAN-ONLY (decided 2026-06-14, see ADR-031): the in-cluster ingester uses the
# chart's ClusterIP Service directly; LAN writers (the bedside snore device, the phone on home
# WiFi, your laptop) reach it at https://s3.teststuff.net via OPNsense HAProxy -> the BGP VIP
# below. No Cloudflare tunnel, no public LoadBalancer. Admin (3903) + RPC (3901) stay internal.
#
# Chart is VENDORED at argocd/charts/garage (Garage v2.3.0 / chart 0.9.3) so apply doesn't depend
# on git.deuxfleurs.fr — see that dir's VENDORED.md. Kept strictly chart-shaped (homelab adds only
# the LoadBalancer Service as platform wiring), which is what makes the ArgoCD re-point a move
# rather than a rewrite (ADR-003/004 GitOps migration).
# Try it:  aws --endpoint-url https://s3.teststuff.net --region garage s3 ls   (after bootstrap)

locals {
  garage_lb_ip = "192.168.40.16" # BGP-advertised LoadBalancer VIP (.10-.15 taken through Forgejo)
}

resource "kubernetes_namespace" "garage" {
  metadata { name = "garage" }
}

# Stable RPC secret (32-byte hex). Pinned in state so `tofu apply` doesn't churn it on every
# upgrade (an empty garage.rpcSecret makes the chart regenerate one each render).
resource "random_id" "garage_rpc" {
  byte_length = 32
}

# Admin-API bearer token. This is the platform-provided SEAM that apps use to provision their own
# buckets/keys (app-owned model, ADR-031 amended): an app's tofu (jkossis/garage provider) talks to
# the admin API (3903) through a kubectl port-forward, authenticated with this token. The admin API
# itself stays ClusterIP-only — never on the VIP. Garage reads it from env GARAGE_ADMIN_TOKEN,
# delivered by secretKeyRef since 2026-08-04 (FU-136) — no longer plaintext in the pod spec,
# though it does still live in tofu state. Stashed to ~/.claude/homelab-garage/admin-token for app
# wrappers.
resource "random_password" "garage_admin_token" {
  length  = 32
  special = false # bearer token: keep it header-safe (alphanumeric)
}

# FU-136 secret gate — garage carries TWO secrets in its values, not one, and the second is easy to
# miss: `rpcSecret` comes from `random_id`, so a grep for `random_password` does not find it. Both
# become Secrets the chart REFERENCES so the release can move to the PUBLIC argocd/platform/.
#
# Names avoid the chart's own: it creates `garage-rpc-secret` itself when `existingRpcSecret` is
# unset, and reusing that name would race Helm's delete of the old against tofu's create of the new
# (the trap forgejo-admin sprang earlier today). VALUES are unchanged — the rpc secret is the
# cluster's identity and a new one would orphan the node from itself.
resource "kubernetes_secret" "garage_rpc" {
  metadata {
    name      = "garage-rpc"
    namespace = kubernetes_namespace.garage.metadata[0].name
  }
  data = { rpcSecret = random_id.garage_rpc.hex } # key name is the chart's contract
  type = "Opaque"
}

resource "kubernetes_secret" "garage_admin_token" {
  metadata {
    name      = "garage-admin-token"
    namespace = kubernetes_namespace.garage.metadata[0].name
  }
  data = { token = random_password.garage_admin_token.result }
  type = "Opaque"
}

# garage MOVED to ArgoCD on 2026-08-04 (FU-136, the ArgoCD lever's last release):
#   argocd/platform/garage.yaml, chart vendored at argocd/charts/garage.
# What stays here is what tofu still owns: the namespace, both Secrets the chart REFERENCES
# (garage-rpc, garage-admin-token) and the LAN VIP Service below — the VIP is platform wiring the
# chart cannot express (BGP keys off a label the chart's Service template doesn't expose).

# LAN VIP for the S3 API (3900) + the static-website endpoint (3902 — deliberately ON the VIP
# since 2026-07-14: HAProxy fronts it as https://<bucket>.teststuff.net for browser-served
# buckets, first oracle-specs). Separate from the chart Service because BGP advertisement
# keys off the `bgp=advertise` label (not an annotation), which the chart's service template
# doesn't expose. Admin (3903) / RPC (3901) stay off the VIP.
resource "kubernetes_service" "garage_s3_lb" {
  metadata {
    name      = "garage-s3"
    namespace = kubernetes_namespace.garage.metadata[0].name
    labels    = { bgp = "advertise" }
    annotations = {
      "lbipam.cilium.io/ips" = local.garage_lb_ip
    }
  }
  spec {
    type = "LoadBalancer"
    selector = {
      "app.kubernetes.io/name"     = "garage"
      "app.kubernetes.io/instance" = "garage"
    }
    port {
      name        = "s3-api"
      port        = 3900
      target_port = 3900
      protocol    = "TCP"
    }
    port {
      name        = "s3-web"
      port        = 3902
      target_port = 3902
      protocol    = "TCP"
    }
  }
  # The chart's Service is an ArgoCD Application since 2026-08-04 (FU-136), so there is no tofu
  # resource left to depend on. This VIP Service selects the chart's pods by label and is
  # independent of ordering — Cilium assigns the IP whenever the endpoints appear.
}

output "garage_s3_endpoint" {
  value = "https://s3.teststuff.net  (direct: http://${local.garage_lb_ip}:3900; region: garage)"
}

# Admin-API token apps consume to provision their own buckets (via port-forward to 3903).
output "garage_admin_token" {
  value     = random_password.garage_admin_token.result
  sensitive = true
}
