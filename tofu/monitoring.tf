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
  grafana_lb_ip        = "192.168.40.11" # BGP-advertised VIP, like ha_lb_ip (.10)
  prometheus_lb_ip     = "192.168.40.13" # (.12 is unifi) — fronted by HAProxy TLS
  alertmanager_lb_ip   = "192.168.40.14"
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
        # The ONE extra scrape job: Home Assistant's Prometheus endpoint.
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
      service = {
        type        = "LoadBalancer"
        labels      = { bgp = "advertise" } # opt in to BGP advertisement (see cilium-bgp.tf)
        annotations = { "lbipam.cilium.io/ips" = local.grafana_lb_ip }
        port        = 80
      }
      # Sidecar discovers dashboard ConfigMaps labelled grafana_dashboard across namespaces.
      sidecar = {
        dashboards = { enabled = true, searchNamespace = "ALL", label = "grafana_dashboard" }
      }
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
              "expr"        = "homeassistant_binary_sensor_state{entity=\"binary_sensor.droplettest_droplet_status\"} == 0"
              "for"         = "10m"
              "labels"      = { severity = "critical" }
              "annotations" = { summary = "Droplet irrigation controller offline", description = "The Droplet ({{ $labels.entity }}) has been disconnected for 10m — no watering and no soil readings." }
            },
            {
              # A capacitive sensor stuck at exactly 0% for hours is usually disconnected/failed
              # rather than truly bone-dry soil.
              "alert"       = "SoilSensorSuspectZero"
              "expr"        = "homeassistant_sensor_voltage_percent{entity=~\"sensor.droplettest_droplet_soilm_sens_[1-4]\"} == 0"
              "for"         = "2h"
              "labels"      = { severity = "warning" }
              "annotations" = { summary = "Soil sensor stuck at 0%", description = "{{ $labels.friendly_name }} has read 0% for 2h — check the sensor wiring/calibration." }
            }
          ]
        }]
      }
    }
  })]

  depends_on = [
    helm_release.cilium,  # CNI + BGP must exist for the Grafana LoadBalancer VIP
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
