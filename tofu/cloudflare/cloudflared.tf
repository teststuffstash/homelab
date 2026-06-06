# cloudflared connector, in-cluster. Outbound-only to the Cloudflare edge; no WAN port-forward.
# Token-based (remotely-managed tunnel) — cloudflared reads TUNNEL_TOKEN and pulls its config.
resource "kubernetes_namespace" "cloudflared" {
  metadata { name = "cloudflared" }
}

resource "kubernetes_secret" "tunnel_token" {
  metadata {
    name      = "cloudflared-token"
    namespace = kubernetes_namespace.cloudflared.metadata[0].name
  }
  type = "Opaque"
  data = {
    token = data.cloudflare_zero_trust_tunnel_cloudflared_token.homelab.token
  }
}

resource "kubernetes_deployment" "cloudflared" {
  metadata {
    name      = "cloudflared"
    namespace = kubernetes_namespace.cloudflared.metadata[0].name
    labels    = { app = "cloudflared" }
  }

  spec {
    replicas = var.cloudflared_replicas

    selector { match_labels = { app = "cloudflared" } }

    template {
      metadata { labels = { app = "cloudflared" } }

      spec {
        # Spread the replicas across nodes so a single node loss doesn't drop the tunnel.
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector { match_labels = { app = "cloudflared" } }
        }

        container {
          name  = "cloudflared"
          image = var.cloudflared_image
          args  = ["tunnel", "--no-autoupdate", "--metrics", "0.0.0.0:2000", "run"]

          env {
            name = "TUNNEL_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.tunnel_token.metadata[0].name
                key  = "token"
              }
            }
          }

          liveness_probe {
            http_get {
              path = "/ready"
              port = 2000
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            failure_threshold     = 3
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { memory = "128Mi" }
          }
        }
      }
    }
  }
}
