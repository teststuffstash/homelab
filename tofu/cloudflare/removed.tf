# The ha.teststuff.net retrofit (FU-039 consumer #2, 2026-10-26): the ha PublicRoute claim
# (argocd/resources/ha-publicroute/) ADOPTED these two objects with import blocks in its Workspace,
# so this root FORGETS them — `destroy = false` drops them from state and never touches Cloudflare.
# (The tunnel, its config, the connector token Secret, the cloudflared Deployment and namespace are
# NOT listed: those are destroyed by this root's next apply — run only after the claim's own
# connector has registered, docs/cloudflare.md §Remote access.) Kept after the apply as the record;
# a no-op once the addresses are gone from state.
removed {
  from = cloudflare_dns_record.ha
  lifecycle {
    destroy = false
  }
}

removed {
  from = cloudflare_ruleset.mtls_enforce
  lifecycle {
    destroy = false
  }
}
