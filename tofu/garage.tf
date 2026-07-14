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
# Chart is VENDORED at tofu/charts/garage (Garage v2.3.0 / chart 0.9.3) so apply doesn't depend
# on git.deuxfleurs.fr — see charts/garage/VENDORED.md. Kept strictly chart-shaped (homelab adds
# only the LoadBalancer Service as platform wiring) so an ArgoCD Application can later re-point at
# the same chart with no rewrite (ADR-003/004 GitOps migration).
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
# itself stays ClusterIP-only — never on the VIP. Injected via env (Garage reads GARAGE_ADMIN_TOKEN);
# this lands plaintext in the pod spec + tofu state, acceptable for the trial (move to a Secret +
# secretKeyRef if it graduates). Stashed to ~/.claude/homelab-garage/admin-token for app wrappers.
resource "random_password" "garage_admin_token" {
  length  = 32
  special = false # bearer token: keep it header-safe (alphanumeric)
}

resource "helm_release" "garage" {
  name      = "garage"
  namespace = kubernetes_namespace.garage.metadata[0].name
  chart     = "${path.module}/charts/garage" # vendored; version pinned by the files on disk
  timeout   = 600

  values = [yamlencode({
    garage = {
      replicationFactor = "1" # single node, no redundancy at the Garage layer
      consistencyMode   = "consistent"
      rpcSecret         = random_id.garage_rpc.hex
      s3 = {
        api = { region = "garage" } # S3 clients must use region "garage"
        # Static-website endpoint (3902): anonymous GET on website-enabled buckets — the one
        # Garage seam browsers can consume (the S3 API 403s anonymous reads). First consumer:
        # the oracle-specs spec site (oracle-fleet#16 / oracle-iac#5).
        web = { rootDomain = ".teststuff.net" } # bucket <b> → https://<b>.teststuff.net (3902)
      }
    }

    deployment = {
      kind         = "StatefulSet"
      replicaCount = 1
    }

    # meta (lmdb) + data on replicated Longhorn. RWO; the pod avoids the ephemeral/laptop nodes
    # (taint, ADR-044) by default, landing on a storage node. storageClass must be set explicitly
    # or the volumeClaimTemplates omit storageClassName.
    persistence = {
      enabled = true
      meta = { size = "1Gi", storageClass = "longhorn" }
      # data on the ADR-089 bulk tier (150Gi ≈ the advertised bulk ceiling; Garage takes the
      # whole grant — it IS the bulk consumer). Garage stays replication_factor=1; redundancy
      # comes from longhorn-bulk's 2 replicas (MX500 + wk-02). Migrated off 10Gi/longhorn
      # 2026-07-13 via the PV-rebind dance in docs/garage-bulk-migration.md (STS
      # volumeClaimTemplates are immutable — that doc is the recipe for any repeat).
      data = { size = "150Gi", storageClass = "longhorn-bulk" }
    }

    # Chart Service stays ClusterIP — that's what the in-cluster CronJob ingester talks to. The LAN
    # VIP is a separate resource below (the chart Service can't carry the bgp=advertise label).
    service = { type = "ClusterIP" }

    # Honour ADR-042 (Prometheus scrapes only Home Assistant) — no metrics Service/ServiceMonitor.
    monitoring = { metrics = { enabled = false } }

    # Sets [admin] admin_token (env override). Enables the HTTP admin API the app bucket-provisioning
    # uses. List form because the chart renders this straight into the pod's `env:`.
    environment = [{ name = "GARAGE_ADMIN_TOKEN", value = random_password.garage_admin_token.result }]
  })]
}

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
  depends_on = [helm_release.garage]
}

output "garage_s3_endpoint" {
  value = "https://s3.teststuff.net  (direct: http://${local.garage_lb_ip}:3900; region: garage)"
}

# Admin-API token apps consume to provision their own buckets (via port-forward to 3903).
output "garage_admin_token" {
  value     = random_password.garage_admin_token.result
  sensitive = true
}
