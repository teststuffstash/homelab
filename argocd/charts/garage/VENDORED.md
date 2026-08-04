# Vendored chart — Garage (Deuxfleurs)

This is the official Garage Helm chart, vendored into the repo so `tofu apply`
does not depend on git.deuxfleurs.fr being reachable (boot-from-git principle).

- Source: https://git.deuxfleurs.fr/Deuxfleurs/garage  `script/helm/garage`
- Tag:    v2.3.0
- Commit: 7b119c0b4fa58ab3cb6d5db435fe52d990f6a7aa
- Chart:  0.9.3  (appVersion Garage v2.3.0)

To update: re-clone the desired tag, copy `script/helm/garage/` over this dir,
bump the values in `tofu/garage.tf`, and update the tag/commit above.
