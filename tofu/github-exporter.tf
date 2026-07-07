# GitHub → Prometheus exporter: the ONE GitHub polling mechanism (workflow-run conclusions
# across all org repos + enhanced-billing usage). DIY poller from a ConfigMap on a stock
# python image — no off-the-shelf exporter polls both (see the script header for the survey);
# replaces GitHub's failure-notification emails via Alertmanager → Home Assistant.
#
# Scrape job + alert rules live with the rest in monitoring.tf (additionalScrapeConfigs /
# additionalPrometheusRulesMap — the CRD-free patterns that survive a from-scratch boot).
# Token: fine-grained PAT (org Administration:read + Actions:read/Metadata:read, all repos), minted
# per scripts/github-exporter-pat-bootstrap.sh → Infisical GITHUB_EXPORTER_TOKEN → ESO here.
# Until that secret exists the pod parks in CreateContainerConfigError — harmless.

locals {
  github_exporter_script = file("${path.module}/templates/github-exporter.py")
}

resource "kubernetes_config_map" "github_exporter_script" {
  metadata {
    name      = "github-exporter-script"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = { "github-exporter.py" = local.github_exporter_script }
}

# PAT from Infisical (source of truth) → k8s Secret. Same shape as sleep_db_reader below/in
# monitoring.tf; the ClusterSecretStore is the ArgoCD-managed "infisical".
resource "kubernetes_manifest" "github_exporter_token" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "github-exporter-token"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "infisical", kind = "ClusterSecretStore" }
      target          = { name = "github-exporter-token", creationPolicy = "Owner" }
      data = [
        { secretKey = "token", remoteRef = { key = "GITHUB_EXPORTER_TOKEN" } },
      ]
    }
  }
}

resource "kubernetes_deployment" "github_exporter" {
  metadata {
    name      = "github-exporter"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { app = "github-exporter" }
  }
  spec {
    replicas = 1
    selector {
      match_labels = { app = "github-exporter" }
    }
    template {
      metadata {
        labels = { app = "github-exporter" }
        # Roll the pod when the script changes (a ConfigMap edit alone doesn't restart pods).
        annotations = { "checksum/script" = sha256(local.github_exporter_script) }
      }
      spec {
        container {
          name    = "exporter"
          image   = "python:3.13-slim"
          command = ["python3", "/app/github-exporter.py"]

          env {
            name  = "GITHUB_ORG"
            value = "teststuffstash"
          }
          env {
            name = "GITHUB_TOKEN"
            value_from {
              secret_key_ref {
                name = "github-exporter-token"
                key  = "token"
              }
            }
          }

          port {
            name           = "http-metrics"
            container_port = 9504
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = 9504
            }
            initial_delay_seconds = 5
            period_seconds        = 30
          }

          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { memory = "128Mi" }
          }

          security_context {
            run_as_non_root            = true
            run_as_user                = 65534
            read_only_root_filesystem  = true
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "script"
            mount_path = "/app"
            read_only  = true
          }
        }
        volume {
          name = "script"
          config_map {
            name = kubernetes_config_map.github_exporter_script.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "github_exporter" {
  metadata {
    name      = "github-exporter"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { app = "github-exporter" }
  }
  spec {
    selector = { app = "github-exporter" }
    port {
      name        = "http-metrics"
      port        = 9504
      target_port = 9504
    }
  }
}
