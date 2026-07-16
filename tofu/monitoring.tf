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
  prometheus_pv_size = "20Gi"
  grafana_lb_ip      = "192.168.40.11" # BGP-advertised VIP, like ha_lb_ip (.10)
  prometheus_lb_ip   = "192.168.40.13" # (.12 is unifi) — fronted by HAProxy TLS
  alertmanager_lb_ip = "192.168.40.14"
  # HA webhook Alertmanager posts to (HA reachable on its BGP VIP from the cluster).
  ha_alert_webhook = "http://${local.ha_lb_ip}:8123/api/webhook/prometheus-alerts"
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

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_version

  # Big chart; first install pulls several images.
  timeout = 900

  values = [yamlencode({
    # ---- Talos control-plane scrape tuning --------------------------------
    # No kube-proxy (Cilium kube-proxy-free; talos.tf cluster.proxy.disabled) → don't scrape it,
    # else KubeProxyDown fires forever. Scheduler + controller-manager metrics are exposed on the
    # node IP by talos.tf (bind-address 0.0.0.0); point the ServiceMonitors at the control-plane
    # IP(s). The chart scrapes https on :10259/:10257 with insecureSkipVerify by default.
    kubeProxy             = { enabled = false }
    kubeScheduler         = { endpoints = local.controlplane_ips }
    kubeControllerManager = { endpoints = local.controlplane_ips }

    # ---- Prometheus -------------------------------------------------------
    prometheus = {
      # BGP LoadBalancer VIP so OPNsense HAProxy can reach it for the TLS frontend
      # (prometheus.teststuff.net). See ansible/opnsense-haproxy.yml.
      service = {
        type        = "LoadBalancer"
        labels      = { bgp = "advertise" }
        annotations = { "lbipam.cilium.io/ips" = local.prometheus_lb_ip }
      }
      prometheusSpec = {
        replicas = 1
        # Scrape ServiceMonitors / PodMonitors / PrometheusRules cluster-wide, not just the chart's
        # own (the default selector only matches release=kube-prometheus-stack). Lets Cilium +
        # Longhorn (and future) monitors/rules be picked up without per-object label wrangling.
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        probeSelectorNilUsesHelmValues          = false
        ruleSelectorNilUsesHelmValues           = false
        # No point scraping faster than HA reports (devices report at 60s).
        scrapeInterval = "60s"
        retention      = "90d"
        retentionSize  = "18GB"
        # Defensive: ensure the data dir is owned by the Prometheus user (uid 1000/gid
        # 2000). Longhorn respects fsGroup so this is usually redundant, but it's cheap
        # insurance and re-runs on every pod/node rebuild.
        initContainers = [{
          name    = "chown-data"
          image   = "busybox:1.37"
          command = ["sh", "-c", "chown -R 1000:2000 /prometheus"]
          securityContext = {
            runAsUser    = 0
            runAsNonRoot = false
          }
          volumeMounts = [{
            name      = "prometheus-kube-prometheus-stack-prometheus-db"
            mountPath = "/prometheus"
          }]
        }]
        # Mount the HA token secret at /etc/prometheus/secrets/ha-token/token.
        secrets = [kubernetes_secret.ha_token.metadata[0].name]
        # The ONE extra scrape job: Home Assistant's Prometheus endpoint. (In-cluster exporters
        # — e.g. the GitHub poller, argocd/resources/github-exporter/ — ride ServiceMonitors
        # instead: applied by ArgoCD post-bootstrap, so no CRD-at-plan-time problem here.)
        additionalScrapeConfigs = [{
          job_name        = "home-assistant"
          scrape_interval = "60s"
          metrics_path    = "/api/prometheus"
          scheme          = "http"
          authorization = {
            type             = "Bearer"
            credentials_file = "/etc/prometheus/secrets/ha-token/token"
          }
          static_configs = [{ targets = ["${local.ha_lb_ip}:8123"] }]
        }]
        storageSpec = {
          volumeClaimTemplate = {
            spec = {
              storageClassName = "longhorn"
              accessModes      = ["ReadWriteOnce"]
              resources        = { requests = { storage = local.prometheus_pv_size } }
            }
          }
        }
      }
    }

    # ---- Grafana ----------------------------------------------------------
    grafana = {
      adminPassword = var.grafana_admin_password
      # Served behind OPNsense HAProxy at https://grafana.teststuff.net — tell Grafana its
      # public URL so redirects, share links, and absolute asset URLs are correct.
      "grafana.ini" = {
        server = { root_url = "https://grafana.teststuff.net" }
      }
      # Stateless: datasource (in-cluster Prometheus) and dashboards are provisioned as
      # code, so we don't need a PV.
      persistence = { enabled = false }
      # FU-082: requests-only (NO limits) — with no resources at all the pod is QoS BestEffort,
      # the first tier Talos's OOMController kills whole under node memory pressure (21 kill
      # cycles on wk-01 before this). Requests make it Burstable + scheduler-accounted; limits
      # deliberately omitted so a dashboard spike degrades instead of reintroducing OOM kills.
      resources = { requests = { cpu = "100m", memory = "256Mi" } }
      service = {
        type        = "LoadBalancer"
        labels      = { bgp = "advertise" } # opt in to BGP advertisement (see cilium-bgp.tf)
        annotations = { "lbipam.cilium.io/ips" = local.grafana_lb_ip }
        port        = 80
      }
      # Sidecar discovers dashboard ConfigMaps labelled grafana_dashboard across namespaces.
      sidecar = {
        dashboards = { enabled = true, searchNamespace = "ALL", label = "grafana_dashboard" }
        resources  = { requests = { cpu = "20m", memory = "64Mi" } } # both sc-* containers (FU-082)
      }

      # --- sleep-tracking dashboard (SQLite v1, ADR-045) ---------------------------------
      # The sleep-overview dashboard reads a SQLite store via the frser plugin. A sidecar
      # syncs sleep-db/sleep.sqlite from Garage into a shared emptyDir every 10 min; the
      # datasource (uid "sleep-notes", matched by the dashboard ConfigMap) reads it.
      plugins = ["frser-sqlite-datasource"]
      additionalDataSources = [{
        name      = "sleep-notes"
        uid       = "sleep-notes"
        type      = "frser-sqlite-datasource"
        access    = "proxy"
        isDefault = false
        editable  = false
        jsonData  = { path = "/data/sleep.sqlite" }
      }]
      extraEmptyDirMounts = [{ name = "sleep-data", mountPath = "/data" }]
      extraContainers     = <<-EOT
        - name: sleep-sqlite-sync
          image: amazon/aws-cli:2.17.0
          command: ["/bin/sh", "-c"]
          args:
            - |
              aws configure set default.s3.addressing_style path
              while true; do
                aws --endpoint-url "$S3_ENDPOINT" s3 cp "s3://sleep-db/sleep.sqlite" /data/sleep.sqlite || true
                sleep 600
              done
          env:
            - { name: S3_ENDPOINT, value: "https://s3.teststuff.net" }
            - { name: AWS_DEFAULT_REGION, value: "garage" }
            - name: AWS_ACCESS_KEY_ID
              valueFrom: { secretKeyRef: { name: sleep-db-reader, key: STORE_S3_ACCESS_KEY_ID } }
            - name: AWS_SECRET_ACCESS_KEY
              valueFrom: { secretKeyRef: { name: sleep-db-reader, key: STORE_S3_SECRET_KEY } }
          volumeMounts:
            - { name: sleep-data, mountPath: /data }
          resources:
            requests: { cpu: 10m, memory: 64Mi }
      EOT
    }

    # ---- Alertmanager → Home Assistant ------------------------------------
    # Ephemeral storage (silences/notification state are transient). Route everything to a
    # webhook receiver that posts to an HA webhook; an HA automation surfaces the alert.
    alertmanager = {
      # BGP LoadBalancer VIP for the TLS frontend (alertmanager.teststuff.net).
      service = {
        type        = "LoadBalancer"
        labels      = { bgp = "advertise" }
        annotations = { "lbipam.cilium.io/ips" = local.alertmanager_lb_ip }
      }
      config = {
        route = {
          receiver        = "ha-webhook"
          group_by        = ["alertname"]
          group_wait      = "30s"
          group_interval  = "5m"
          repeat_interval = "3h"
          # Swallow the chart's always-firing Watchdog heartbeat (else it spams HA).
          routes = [{
            receiver = "null"
            matchers = ["alertname = \"Watchdog\""]
          }]
        }
        # "null" must exist because the Watchdog route targets it; everything else → HA.
        receivers = [
          { name = "null" },
          {
            name = "ha-webhook"
            webhook_configs = [{
              url           = local.ha_alert_webhook
              send_resolved = true
            }]
          },
        ]
      }
    }

    # ---- Alerting rules (created by Helm, so no CRD-at-plan-time chicken/egg) ----
    additionalPrometheusRulesMap = {
      office-plants = {
        groups = [{
          name = "office-plants"
          rules = [
            {
              "alert"       = "HomeAssistantScrapeDown"
              "expr"        = "up{job=\"home-assistant\"} == 0"
              "for"         = "10m"
              "labels"      = { severity = "critical" }
              "annotations" = { summary = "Prometheus can't scrape Home Assistant", description = "No plant metrics for 10m — HA down or token invalid. Plants stop watering when HA is unreachable." }
            },
            {
              "alert"       = "DropletOffline"
              "expr"        = "homeassistant_binary_sensor_state{entity=\"binary_sensor.office_plants_irrigation_status\"} == 0"
              "for"         = "10m"
              "labels"      = { severity = "critical" }
              "annotations" = { summary = "Droplet irrigation controller offline", description = "The Droplet ({{ $labels.entity }}) has been disconnected for 10m — no watering and no soil readings." }
            },
            {
              # A capacitive sensor stuck at exactly 0% for hours is usually disconnected/failed
              # rather than truly bone-dry soil.
              "alert"       = "SoilSensorSuspectZero"
              "expr"        = "homeassistant_sensor_voltage_percent{entity=~\"sensor.office_plants_irrigation_soilm_sens_[1-4]\"} == 0"
              "for"         = "2h"
              "labels"      = { severity = "warning" }
              "annotations" = { summary = "Soil sensor stuck at 0%", description = "{{ $labels.friendly_name }} has read 0% for 2h — check the sensor wiring/calibration." }
            }
          ]
        }]
      }

      # Node reboots — the bare-metal Talos nodes (hp-01, thinkcentre, wk-metal-01/02) flapped a
      # staggered reboot wave on 2026-06-19 that took down CNPG replicas; node-exporter is already
      # scraped, so alert when any node's uptime is < 10m to catch + timestamp the next occurrence.
      node-health = {
        groups = [{
          name = "node-health"
          rules = [
            {
              "alert"       = "NodeRebooted"
              "expr"        = "(time() - node_boot_time_seconds) < 600"
              "for"         = "0m"
              "labels"      = { severity = "warning" }
              "annotations" = { summary = "Node {{ $labels.instance }} rebooted", description = "{{ $labels.instance }} booted {{ $value | humanizeDuration }} ago. Metal-node flapping is under investigation (2026-06-19) — note which node + time." }
            }
          ]
        }]
      }

      # Cilium BGP — the LoadBalancer-VIP lifeline. If peering with OPNsense drops, .40.0/24 VIPs
      # stop being advertised and every LAN-exposed service goes dark. (These metrics caught the
      # metal nodes never being in bgp_node_ips — 2026-06-11.)
      cilium-bgp = {
        groups = [{
          name = "cilium-bgp"
          rules = [
            {
              "alert"       = "CiliumBGPAllSessionsDown"
              "expr"        = "sum(cilium_bgp_control_plane_session_state == bool 1) == 0"
              "for"         = "5m"
              "labels"      = { severity = "critical" }
              "annotations" = { summary = "No Cilium BGP sessions established", description = "Not one node is peering with OPNsense — all LoadBalancer VIPs (192.168.40.0/24: HA, Grafana, Prometheus, UniFi, Forgejo, ...) are no longer advertised and are unreachable from the LAN." }
            },
            {
              "alert"       = "CiliumBGPNodeSessionDown"
              "expr"        = "cilium_bgp_control_plane_session_state != 1"
              "for"         = "15m"
              "labels"      = { severity = "warning" }
              "annotations" = { summary = "Cilium BGP session down on a node", description = "{{ $labels.instance }} is not peering with {{ $labels.neighbor }} for 15m (state != established) — it advertises no VIPs (reduced redundancy/ECMP). A new node must be added to bgp_node_ips in ansible/group_vars/opnsense.yml + run opnsense-bgp.yml." }
            }
          ]
        }]
      }

      cilium = {
        groups = [{
          name = "cilium"
          rules = [
            {
              "alert"       = "CiliumAgentScrapeDown"
              "expr"        = "up{job=\"cilium-agent\"} == 0"
              "for"         = "10m"
              "labels"      = { severity = "warning" }
              "annotations" = { summary = "Cilium agent unreachable", description = "Prometheus can't scrape the Cilium agent on {{ $labels.instance }} for 10m — the node's CNI may be down (the node will go NotReady)." }
            },
            {
              "alert"       = "CiliumUnreachableNodes"
              "expr"        = "cilium_unreachable_nodes > 0"
              "for"         = "10m"
              "labels"      = { severity = "warning" }
              "annotations" = { summary = "Cilium reports unreachable nodes", description = "A Cilium agent ({{ $labels.instance }}) can't reach {{ $value }} other node(s) in the mesh for 10m — cross-node pod networking is degraded." }
            }
          ]
        }]
      }

      longhorn = {
        groups = [{
          name = "longhorn"
          rules = [
            {
              "alert"       = "LonghornVolumeFaulted"
              "expr"        = "max by (volume) (longhorn_volume_robustness) == 3"
              "for"         = "5m"
              "labels"      = { severity = "critical" }
              "annotations" = { summary = "Longhorn volume faulted", description = "Volume {{ $labels.volume }} is faulted (no healthy replica) for 5m — data unavailable / at risk." }
            },
            {
              "alert"       = "LonghornVolumeDegraded"
              "expr"        = "max by (volume) (longhorn_volume_robustness) == 2"
              "for"         = "20m"
              "labels"      = { severity = "warning" }
              "annotations" = { summary = "Longhorn volume degraded", description = "Volume {{ $labels.volume }} has been degraded (a replica missing/rebuilding) for 20m — running below the desired replica count." }
            },
            {
              "alert"       = "LonghornNodeStorageLow"
              "expr"        = "(longhorn_node_storage_usage_bytes / longhorn_node_storage_capacity_bytes) > 0.85"
              "for"         = "30m"
              "labels"      = { severity = "warning" }
              "annotations" = { summary = "Longhorn node storage low", description = "{{ $labels.node }} Longhorn storage is over 85% used for 30m — volumes may fail to schedule or rebuild." }
            }
          ]
        }]
      }

      # CloudNativePG (forgejo-pg, infisical-pg). The 2026-06-19 metal flap stranded forgejo-pg-2 as
      # a replica that crash-looped on pg_rewind ("no common timeline ancestor") for 2.5 DAYS unnoticed
      # — these would have paged in minutes. The kube-state-metrics rules need no CNPG exporter (they
      # caught the readiness-500 case); the cnpg_* rules need the per-cluster PodMonitor
      # (spec.monitoring.enablePodMonitor, set on both Clusters). Add new CNPG namespaces to the
      # kube_pod_* selectors below.
      cnpg = {
        groups = [{
          name = "cnpg"
          rules = [
            {
              "alert"       = "CNPGInstanceNotReady"
              "expr"        = "kube_pod_container_status_ready{namespace=~\"forgejo|infisical\",container=\"postgres\"} == 0"
              "for"         = "10m"
              "labels"      = { severity = "warning" }
              "annotations" = { summary = "CloudNativePG instance {{ $labels.pod }} not ready", description = "Postgres instance {{ $labels.pod }} ({{ $labels.namespace }}) has been NotReady for 10m — the CNPG cluster is degraded (often a replica that can't rejoin and loops on pg_rewind; the primary may be serving alone). Recovery: delete the replica's PVC+pod so CNPG re-clones from the primary." }
            },
            {
              "alert"       = "CNPGInstanceCrashLooping"
              "expr"        = "increase(kube_pod_container_status_restarts_total{namespace=~\"forgejo|infisical\",container=\"postgres\"}[15m]) > 3"
              "for"         = "0m"
              "labels"      = { severity = "warning" }
              "annotations" = { summary = "CloudNativePG instance {{ $labels.pod }} crash-looping", description = "{{ $labels.pod }} ({{ $labels.namespace }}) restarted >3 times in 15m — likely a replica stuck on pg_rewind (no common timeline ancestor). Re-clone it: delete the replica's PVC + pod." }
            },
            {
              "alert"       = "CNPGReplicationLagHigh"
              "expr"        = "cnpg_pg_replication_lag > 300"
              "for"         = "5m"
              "labels"      = { severity = "warning" }
              "annotations" = { summary = "CloudNativePG replication lag high", description = "Streaming lag on {{ $labels.pod }} is {{ $value | humanizeDuration }} (>5m) for 5m — the standby is falling behind the primary." }
            },
            {
              "alert"       = "CNPGInstanceExporterDown"
              "expr"        = "cnpg_collector_up == 0"
              "for"         = "5m"
              "labels"      = { severity = "warning" }
              "annotations" = { summary = "CloudNativePG metrics collector down", description = "The CNPG collector on {{ $labels.pod }} can't reach Postgres for 5m — the instance is unhealthy or the exporter is failing." }
            }
          ]
        }]
      }
    }
  })]

  depends_on = [
    helm_release.cilium,   # CNI + BGP must exist for the Grafana LoadBalancer VIP
    helm_release.longhorn, # default StorageClass for the Prometheus TSDB PVC
    kubernetes_secret.ha_token,
  ]
}

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
# here: the frser SQLite datasource (uid "sleep-notes" — the dashboard's stable contract), the
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
