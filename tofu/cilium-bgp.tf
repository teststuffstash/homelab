# Cilium BGP: advertise LoadBalancer service IPs to OPNsense (FRR), giving services
# real routable VIPs on the LAN instead of NodePort. Pairs with the OPNsense side
# (os-frr, managed as code — see ansible/).
#
# Control knobs.
locals {
  cluster_asn  = 64513
  opnsense_asn = 64512
  opnsense_ip  = "192.168.2.1"
  lb_pool_cidr = "192.168.40.0/24" # dedicated subnet so LAN clients route via OPNsense (L3), not ARP (L2)
}

# Pool the LoadBalancer IPs are allocated from.
resource "kubernetes_manifest" "lb_pool" {
  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumLoadBalancerIPPool"
    metadata   = { name = "lb-pool" }
    spec = {
      blocks = [{ cidr = local.lb_pool_cidr }]
    }
  }
  depends_on = [helm_release.cilium]
}

# Which services get advertised over BGP: ONLY those labelled bgp=advertise.
# (Explicit opt-in — nothing leaks to the router unless you label it.)
resource "kubernetes_manifest" "bgp_advertisement" {
  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumBGPAdvertisement"
    metadata = {
      name   = "lb-services"
      labels = { advertise = "bgp" }
    }
    spec = {
      advertisements = [{
        advertisementType = "Service"
        service           = { addresses = ["LoadBalancerIP"] }
        selector = {
          matchLabels = { bgp = "advertise" }
        }
      }]
    }
  }
  depends_on = [helm_release.cilium]
}

# Per-peer config: IPv4 unicast, attach the advertisement set above.
resource "kubernetes_manifest" "bgp_peer_config" {
  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumBGPPeerConfig"
    metadata   = { name = "opnsense" }
    spec = {
      families = [{
        afi            = "ipv4"
        safi           = "unicast"
        advertisements = { matchLabels = { advertise = "bgp" } }
      }]
    }
  }
  depends_on = [helm_release.cilium]
}

# Cluster BGP instance peering with OPNsense.
resource "kubernetes_manifest" "bgp_cluster_config" {
  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumBGPClusterConfig"
    metadata   = { name = "cilium-bgp" }
    spec = {
      nodeSelector = { matchLabels = {} } # all nodes peer
      bgpInstances = [{
        name     = "instance-${local.cluster_asn}"
        localASN = local.cluster_asn
        peers = [{
          name          = "opnsense"
          peerASN       = local.opnsense_asn
          peerAddress   = local.opnsense_ip
          peerConfigRef = { name = "opnsense" }
        }]
      }]
    }
  }
  depends_on = [kubernetes_manifest.bgp_peer_config]
}
