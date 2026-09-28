# A checkout stand-in with the two shapes the review on PR#2082 named: forgejo-runner.tf declares
# ONE Deployment ("forgejo-runner") whose containers are `dind` / `runner` and whose volumes are
# `docker-storage` / `runner-data`; unifi.tf declares TWO Deployments ("mongo", then "unifi") plus a
# Service named "unifi". Only a Deployment resource's OWN metadata name may couple.
T="$(mktemp -d)"; mkdir -p "$T/tofu"
cat > "$T/tofu/forgejo-runner.tf" <<'TF'
resource "kubernetes_namespace" "forgejo_runner" {
  metadata { name = "forgejo-runner" }
}
resource "kubernetes_deployment" "forgejo_runner" {
  metadata {
    name      = "forgejo-runner"
    namespace = kubernetes_namespace.forgejo_runner.metadata[0].name
  }
  spec {
    template {
      metadata { labels = { app = "forgejo-runner" } }
      spec {
        container {
          name  = "dind"
          image = "docker:27-dind"
        }
        container {
          name  = "runner"
          image = "code.forgejo.org/forgejo/runner:6.3.1"
        }
        volume {
          name = "docker-storage"
          empty_dir {}
        }
      }
    }
  }
}
TF
cat > "$T/tofu/unifi.tf" <<'TF'
resource "kubernetes_deployment" "mongo" {
  metadata {
    name      = "mongo"
    namespace = "unifi"
  }
  spec {
    template {
      spec {
        container {
          name  = "mongo"
          image = "mongo:7"
        }
      }
    }
  }
}
resource "kubernetes_service" "unifi" {
  metadata { name = "unifi" }
}
resource "kubernetes_deployment" "unifi" {
  metadata {
    name      = "unifi"
    namespace = "unifi"
  }
  spec {
    template {
      spec {
        container {
          name  = "unifi"
          image = "lscr.io/linuxserver/unifi-network-application:9.0"
        }
      }
    }
  }
}
TF
cd "$T"
