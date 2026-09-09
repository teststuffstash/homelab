# Vendored chart — Garage (Deuxfleurs)

This is the official Garage Helm chart, vendored into the repo so an ArgoCD sync
(`argocd/platform/garage.yaml`, since the 2026-08-04 FU-136 move off tofu) never
depends on git.deuxfleurs.fr being reachable (boot-from-git principle).

- Source: https://git.deuxfleurs.fr/Deuxfleurs/garage  `script/helm/garage`
- Tag:    v2.3.0
- Commit: 7b119c0b4fa58ab3cb6d5db435fe52d990f6a7aa
- Chart:  0.9.3  (appVersion Garage v2.3.0)

To update: re-clone the desired tag, copy `script/helm/garage/` over this dir,
bump the values in `argocd/platform/garage.yaml` (`helm.valuesObject`), and update the
tag/commit above.

## Local patches (re-apply after every update)

- `templates/workload.yaml` + `values.yaml`: `extraInitContainers` (rendered after `garage-init`).
  Carries the `meta-rotate` init container that seeds a zone's metadata from its own finished
  compacted snapshot — the rotation loop's mechanism (docs/garage.md §Metadata reclamation,
  `argocd/resources/garage-meta-rotation/`). Upstream's chart has `extraVolumes`/`extraVolumeMounts`
  but no init-container hook (2026-09-09).
- `templates/workload.yaml` + `values.yaml`: `minReadySeconds` on the StatefulSet (upstream has
  none). With `readinessProbe` on `/health` it is what keeps a rollout from cycling two quorum
  members inside the same minute (2026-09-09).
