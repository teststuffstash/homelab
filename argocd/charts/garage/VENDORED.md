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
- `templates/workload.yaml`: the pod template carries `garage.teststuff.net/serve-s3: "true"`
  (2026-09-12). Half of the client-path exclusion below — **drop it and the exclusion silently
  stops working**, because removing the label from a pod would then match nothing.
- `templates/service.yaml`: the `garage` ClusterIP's selector ALSO matches
  `garage.teststuff.net/serve-s3: "true"` (2026-09-12), so one pod can be pulled out of the
  in-cluster S3 client path during a zone/metadata rebuild while staying a full peer. Deliberately
  NOT applied to `service-headless.yaml` (peer RPC) or the metrics Service in the same file — a
  drained pod must keep its replica role and its scrape. The LAN VIP half of this lives in
  `tofu/garage.tf` (`kubernetes_service.garage_s3_lb`), outside the chart. Recipe + the
  one-pod-out precheck: docs/garage.md §The build-out step 8.

## License

- Upstream license: **AGPL-3.0** — the repository's `LICENSE` at the pinned commit is the verbatim
  FSF text of the GNU Affero General Public License v3 (it names no copyright holder itself); the
  chart directory ships no license file of its own, no NOTICE, and `Chart.yaml` carries no license
  annotation (checked at commit 7b119c0b, 2026-10-25). Garage is developed by Deuxfleurs
  (https://git.deuxfleurs.fr/Deuxfleurs/garage); the crate's `src/garage/Cargo.toml` at that commit
  states `license = "AGPL-3.0"` and names Alex Auvolat as author.
- A copy of that license is vendored beside this file as
  [`LICENSE-garage-chart`](LICENSE-garage-chart) (unmodified upstream text; byte-identical to this
  repo's own `/LICENSE`).
- **This copy is MODIFIED** (AGPL-3.0 §5(a) notice): `templates/workload.yaml`,
  `templates/service.yaml` and `values.yaml` differ from upstream — each carries a header comment
  saying so, and the changes with their dates are enumerated in §Local patches above; the full
  change record is `git log -- argocd/charts/garage/`. Every other file is verbatim upstream.
- The containing repository is AGPL-3.0 as well (`/LICENSE`, README §License), so the derivative
  stays under the same license.
