# launch specs — the contract, and how it is worked

The spec system for the [launch island](../README.md), in the gateway island's shape
([`gateway/specs/README.md`](../../../gateway/specs/README.md) is the template): **the reviewer
reviews the result, not the diff.** Every interface the launcher exposes has a contract page here
with a sibling `<name>.schema.json`; rows are decision tables of key examples. What the launcher
*is* lives one level up; this directory is only the contract, written from the redrawn interface
([context-and-autonomy.md §Interfaces are redrawn at the cut](../../../docs/spikes/context-and-autonomy.md#interfaces-are-redrawn-at-the-cut-operator-2026-10-05)):
the launcher asks the gateway one question and names no model. Where the code still answers that
question itself, the row is a `⚑ gap`, never the contract.

> **Contract for a fresh build** ([../README.md](../README.md)): these pages specify the component
> to be written under `islands/launch/`; the "code" a row cites is the OLD member it replaces, read as
> the behaviour to match. Line citations (`file:<n>`) are against the spike's base `c34535a5`
> (2026-11-07) and have drifted on master — the `REPLAY:` sentinels and fixture dirs are the stable
> anchors. Nothing live reads this directory.

## Rules — the pinned process, and what this island adds

The numbered rules live ONCE in allure-behavior-snippets (no version link yet).
