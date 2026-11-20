---
Touches: agents/fixer/openrouter-operator/agentstack.yaml, docs/storage-ledger.md
Origin: teststuffstash/homelab#3563
Class: fix

---
## Deliverable
The `homelab` namespace's `longhorn-scratch` quota is 100Gi (five 20Gi `docker-lib` volumes) instead of 40Gi (two), and the storage ledger records it.

## Acceptance
1. In `agents/fixer/openrouter-operator/agentstack.yaml`, in the `- name: homelab` repo's `storage:` block, the line
   `scratch: "40Gi" # 20Gi × 2 concurrent gateway docker rides (fixer.dockerPaths)`
   reads
   `scratch: "100Gi" # 20Gi × 5: three live docker rides (the scan's REPO_MAX_WIP) + two finished pods inside the janitor's grace — the stacks' number (homelab#1321, homelab#3563)`
   No other `scratch:` line in the file changes (the two `scratch: "0"` lines stay).
2. In the comment above that block, the words `sized for two.` read `sized like the docker stacks (docs/storage-ledger.md).`
3. In `docs/storage-ledger.md`, the paragraph that ends `Headroom at the raise: 216 + 237 GiB free on the two bulk disks, scratch replica-1.` (lines 815–816, the sentence wraps) gains this sentence at its end:
   `The platform's own namespace followed in 2026-11: `homelab` 40Gi → 100Gi (homelab#3563) — its cap was sized for two rides while the scan lets three run, and a finished pod kept one of the two volumes for up to 2 h.`
4. In `docs/storage-ledger.md`, in the table row that starts `| **bulk scratch for 5 concurrent docker rides per stack** |`, the cell
   `100Gi × 3 stacks = 300Gi worst case, replica-1 on 453 GiB free`
   reads
   `100Gi × 4 namespaces (the three stacks + `homelab`, homelab#3563) = 400Gi worst case, replica-1 on the four bulk disks: 714 GiB available, 420 GiB of it above Longhorn's 25 % floor (read 2026-11-20)`
5. `grep -c 'scratch: "100Gi"' agents/fixer/openrouter-operator/agentstack.yaml` prints `1`, and `grep -c 'scratch: "40Gi"'` on the same file prints `0`.
6. The PR opens through `pr-open` with its gate green. The PR body says: `manifest-lint` skips the AgentStack kind, so the claim edit was checked by reading the diff (one value, one comment); and "lands through the ADR-110 seat read" (`agents/**` and `docs/**` are human-merged paths).

## Decision
Raise the `homelab` namespace's `longhorn-scratch` quota from 40Gi (two 20Gi volumes) to 100Gi (five): three live docker rides and two finished pods fit, where today a third live ride, or a ride queued behind one dead pod, sits Pending on quota. Decided at intake — the ride implements it and decides nothing. ⚖

The numbers the choice stood on (read 2026-11-20, nine days of Prometheus history unless said otherwise):
- `agents/coordinator-scan.sh:54` — `REPO_MAX_WIP` defaults to 3; the peak of non-terminal ride pods in the namespace was 3.
- Ride pods present at once (any phase): peak 4; 514 minutes with 3 or more, 164 minutes with 4 or more, none with 5.
- The quota's `used` stood at its 40Gi cap for 667 minutes. `KubePodNotReady` fired 370 minutes on five ride pods; the longest Pending was 173 minutes (`agent-homelab-issue-3303-r2`, 2026-11-16T22:10Z to 2026-11-17T01:02Z).
- The three dead pods of the two waves each held a volume 96 to 118 minutes after failing (the janitor keeps a Failed pod until 2 h after its start and 1 h after its agent container ended).
- Room: the four `bulk` disks have 977 GiB of schedulable headroom at Longhorn's 200 % over-provisioning (the smallest disk 137 GiB) and 420 GiB physically available above the 25 % floor; every namespace's scratch cap summed is 340Gi today and 400Gi after this change.
- Precedent: homelab#1321 (closed 2026-09-04) raised the three docker stacks from 60Gi to 100Gi for the same arithmetic; `docs/storage-ledger.md` records it.

Options not taken:
- **80Gi** — covers the observed peak of 4 pods, but that peak was measured while the cap held rides back; 100Gi is the number the stacks already run, one figure for every docker namespace. ⚖
- **60Gi** — three live rides and no finished pod: the 164 minutes with 4 pods present would still pend.
- **A shorter janitor grace** — with no grace at all, three live rides need 60Gi against a 40Gi cap; and the grace is what lets the dead-ride record read a Failed pod.
- **Fewer docker rides at once (a cap of two)** — new scan machinery, and it slows the island the quota serves.
- **Silencing the alert for quota-Pending pods** — it would blind the detector.

Unverified: nothing the edits depend on.

## Out of scope
- The janitor's grace (`agents/coordinator-scan.sh`) and `REPO_MAX_WIP` stay as they are.
- `SERVICES.md` (its Longhorn row still says "≤20Gi×3 per docker repo") is not edited here.
- No `kubectl` write: ArgoCD applies the claim after the merge. The live check after the merge is the seat's, not the ride's: `kubectl -n homelab get resourcequota agentstack-storage` shows `longhorn-scratch.storageclass.storage.k8s.io/requests.storage: 100Gi` under `hard`.
- The six responder proposals quoted in the original body (deleting single pods) are not acts of this issue.

