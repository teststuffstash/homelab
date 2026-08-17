# Monitoring stack: kube-prometheus-stack (Prometheus + Grafana + Alertmanager +
# operator). Design goals (see docs/office-plants/README.md "Monitoring"):
#   * SINGLE scrape source — Prometheus scrapes only Home Assistant's /api/prometheus,
#     never the ESP devices directly. Devices already push to HA over their native API,
#     so this adds zero WiFi traffic and avoids double-scraping.
#   * Declarative/boot-from-git, same as the rest of tofu/.
#
# Storage: Prometheus TSDB on Longhorn (replicated, not node-pinned). Grafana keeps no state
# (dashboards + datasource provisioned as code), Alertmanager uses ephemeral storage.
locals {
  # These three survive only because the outputs below print them. The TSDB size and the
  # Alertmanager→Home Assistant webhook moved with the chart (FU-136) and were deleted here rather
  # than left behind: a value with two homes is a drift bug waiting for whoever edits the wrong one.
  grafana_lb_ip      = "192.168.40.11" # BGP-advertised VIP, like ha_lb_ip (.10)
  prometheus_lb_ip   = "192.168.40.13" # (.12 is unifi) — fronted by HAProxy TLS
  alertmanager_lb_ip = "192.168.40.14"
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    # Talos enforces PodSecurity `baseline` cluster-wide; node-exporter (hostNetwork/
    # hostPath/hostPort) needs `privileged`, so opt this namespace up.
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
      "pod-security.kubernetes.io/audit"   = "privileged"
    }
  }
}

# HA long-lived access token for /api/prometheus. Value from TF_VAR_ha_prometheus_token
# (never committed). Mounted into Prometheus at /etc/prometheus/secrets/ha-token/token.
resource "kubernetes_secret" "ha_token" {
  metadata {
    name      = "ha-token"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = { token = var.ha_prometheus_token }
  type = "Opaque"
}

# Grafana admin credentials as a k8s Secret the chart REFERENCES, rather than a value rendered into
# it (FU-136). This is the preparatory half of the ArgoCD lever: `argocd/platform/` is a public repo,
# so the release cannot move while its values carry a live password. tofu keeps owning the secret
# after it stops owning the release — same shape as `ha_token` above, and the natural next target
# for the ESO/Infisical migration (`minimize-tofu` direction).
# Key names are the grafana subchart's defaults (admin-user / admin-password).
resource "kubernetes_secret" "grafana_admin" {
  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "admin-user"     = "admin"
    "admin-password" = var.grafana_admin_password
  }
  type = "Opaque"
}

# kube-prometheus-stack MOVED to ArgoCD on 2026-08-04 (FU-136, the ArgoCD lever):
#   argocd/platform/kube-prometheus-stack.yaml + argocd/platform/values/kube-prometheus-stack.yaml
# The chart, every alert rule and the Alertmanager routes that used to live in this file are there
# now — a rule change is an ordinary GitOps PR, not a tofu apply. What stays here is what tofu still
# owns: the namespace, the Secrets the chart REFERENCES (ha-token, grafana-admin), the dashboard
# ConfigMaps the Grafana sidecar picks up, and the sleep-db-reader claim.

# Office-plants Grafana dashboard, provisioned as code. The Grafana sidecar loads any
# ConfigMap labelled grafana_dashboard=1.
resource "kubernetes_config_map" "plants_dashboard" {
  metadata {
    name      = "grafana-dashboard-office-plants"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { grafana_dashboard = "1" }
  }
  data = { "office-plants.json" = file("${path.module}/dashboards/office-plants.json") }
}

# Power / smart-plug Grafana dashboard, provisioned as code (same sidecar mechanism).
resource "kubernetes_config_map" "power_dashboard" {
  metadata {
    name      = "grafana-dashboard-power"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { grafana_dashboard = "1" }
  }
  data = { "power.json" = file("${path.module}/dashboards/power.json") }
}

# Sleep Overview dashboard — MOVED to GitOps (FU-025). The dashboard BODY now lives in the sleep-iac
# repo (sleep-tracking/sleep-overview.json → a grafana_dashboard-labelled ConfigMap via kustomize
# configMapGenerator, in the sleep-tracking namespace) so a fix is a PR ArgoCD syncs, not a tofu
# apply. The Grafana sidecar discovers it by label across ALL namespaces. What STAYS platform-owned
# here: the frser SQLite datasource (uid "sleep-data" — the dashboard's stable contract), the
# sleep-sqlite-sync sidecar, and the sleep-db-reader ExternalSecret (Grafana-deployment infra).

# S3 read creds for the Grafana sleep.sqlite sync sidecar — mirrors the sleep-ingester's
# STORE_S3 key (rw on sleep-db) from Infisical via ESO into the monitoring namespace.
resource "kubernetes_manifest" "sleep_db_reader" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "sleep-db-reader"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "infisical", kind = "ClusterSecretStore" }
      target          = { name = "sleep-db-reader", creationPolicy = "Owner" }
      data = [
        { secretKey = "STORE_S3_ACCESS_KEY_ID", remoteRef = { key = "SLEEP_STORE_S3_ACCESS_KEY_ID" } },
        { secretKey = "STORE_S3_SECRET_KEY", remoteRef = { key = "SLEEP_STORE_S3_SECRET_KEY" } },
      ]
    }
  }
}

# Whole-cluster health overview (dotdc "Kubernetes / Views / Global", grafana.com 15757) —
# node up/down, cluster CPU/mem/disk/network, pod counts. Complements the chart's built-in
# k8s-resources-* dashboards. Uses the ${datasource} template var → resolves via the sidecar.
resource "kubernetes_config_map" "cluster_health_dashboard" {
  metadata {
    name      = "grafana-dashboard-cluster-health"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { grafana_dashboard = "1" }
  }
  data = { "cluster-health.json" = file("${path.module}/dashboards/cluster-health.json") }
}

# CloudNativePG dashboard (forgejo-pg, infisical-pg) — instances ready/NotReady, streaming replicas,
# replication lag, restarts, connections. The cnpg_* panels need spec.monitoring.enablePodMonitor on
# the Clusters; the kube_pod_* panels work regardless. Datasource uid "prometheus" (provisioned).
resource "kubernetes_config_map" "cnpg_dashboard" {
  metadata {
    name      = "grafana-dashboard-cnpg"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { grafana_dashboard = "1" }
  }
  data = { "cnpg.json" = file("${path.module}/dashboards/cnpg.json") }
}

# Agent-platform dashboards (FU-057, docs/agents/observability-and-retro.md §B1). Three views over
# the pushgateway agent_run_* series (worker cost/outcome), the OTLP claude_code_* series
# (coordinator/reviewer), kube-state-metrics (pods by role×phase) and github_pull_request_* (the
# stall detector): running-agents (what's active + the 2.5h-stall panel), model-health (the
# blacklist pivot: success/harness-death/$-per-successful-run per model) and cost ($/day vs the
# weekly ceiling). Datasource uid "prometheus" (provisioned); sidecar discovers the label.
resource "kubernetes_config_map" "agent_dashboards" {
  for_each = toset(["agent-running", "agent-model-health", "agent-cost"])
  metadata {
    name      = "grafana-dashboard-${each.key}"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { grafana_dashboard = "1" }
  }
  data = { "${each.key}.json" = file("${path.module}/dashboards/${each.key}.json") }
}

# Component dashboards (Cilium agent metrics 21431, Cilium/Hubble network 24056, Longhorn 16888) —
# community dashboards from grafana.com, with ${DS_PROMETHEUS} rewritten to the provisioned
# Prometheus datasource uid ("prometheus") so they render via the sidecar without an import step.
resource "kubernetes_config_map" "component_dashboards" {
  for_each = toset(["cilium-metrics", "cilium-network", "longhorn"])
  metadata {
    name      = "grafana-dashboard-${each.key}"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { grafana_dashboard = "1" }
  }
  data = { "${each.key}.json" = file("${path.module}/dashboards/${each.key}.json") }
}

output "grafana_url" {
  description = "Grafana UI. HTTPS via OPNsense HAProxy (ansible/opnsense-haproxy.yml); raw VIP also works. Login: admin / TF_VAR_grafana_admin_password."
  value       = "https://grafana.teststuff.net  (direct: http://${local.grafana_lb_ip})"
}

output "monitoring_urls" {
  description = "Prometheus / Alertmanager UIs (HTTPS via HAProxy; raw VIPs also work)."
  value = {
    prometheus   = "https://prometheus.teststuff.net  (direct: http://${local.prometheus_lb_ip}:9090)"
    alertmanager = "https://alertmanager.teststuff.net  (direct: http://${local.alertmanager_lb_ip}:9093)"
  }
}
