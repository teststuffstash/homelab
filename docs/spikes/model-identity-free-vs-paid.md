# Model identity in the router — free vs paid, model vs family (2026-09-23)

**Status: investigation, no decision.** Opened when a one-line config fix turned out to sit on a
question nobody has answered: *what is a model, for routing purposes?* The operator's ruling on
the day was explicitly to **not** take the small change — "free vs paid and model vs family is a
bigger topic, there is a lot of deepseek-flash out there."

The fix that was taken instead is a single exact-id deny in the stack's own claim
(oracle-iac#970). Everything below is what that deny stepped around.

Owning doc for the rules this questions: [`../agents/model-routing.md`](../agents/model-routing.md)
(mechanism) and its archaeology [`model-routing-history.md`](model-routing-history.md) (§M1–§M14).
Tracker: FU-201 (c) for the strike half; the routing build itself is Goal homelab#1640.

## What happened

`agent-budget/sm` round 3 on oracle-fleet#712 and #713 was dispatched to
`deepseek/deepseek-v4-flash-20260731:free` and struck `repetition-loop` at 12:20Z — the class the
oracle seat measured on 2026-09-14 (loops occur only on the **non-`:exacto`** deepseek cell;
`:exacto` never looped in 10 missions). The stack asked the platform to drop the cell from a
chain. There was no chain to drop, and each layer that *should* have stopped it turned out to be
looking at a differently-spelled version of the same model.

## Findings

Each of these is a separate identity rule, and they do not agree with each other.

### 1. A `:free` dated variant inherits approval from its paid, undated family entry

`model_family()` (`router.py:846`) strips `:free`, context brackets, rail prefixes, and a trailing
date stamp — `_MODEL_FAMILY_SUFFIX_RE = -(\d{4}|\d{6,8})$` catches both `0731` and `20260731`. So:

```
deepseek/deepseek-v4-flash-20260731:free  →  deepseek/deepseek-v4-flash
deepseek/deepseek-v4-flash-0731           →  deepseek/deepseek-v4-flash
deepseek/deepseek-v4-flash:exacto         →  deepseek/deepseek-v4-flash
```

The `models` table is keyed by that output and holds exactly four deepseek keys, all undated:
`deepseek/deepseek-v4-flash` (cheap), `deepseek-v4-flash` (opencode-go, cheap),
`deepseek/deepseek-v4.1-flash` (cheap), `deepseek/deepseek-v4-pro` (large). **`0731` appears
nowhere in `model-classes.json`.**

`_model_entry()` therefore resolves the free dated variant through the paid undated entry and
returns non-`None` — the model counts as approved ("the rotation universe's exclusion" never
fires) — while `_model_tier()` floors it to `"free"` purely because the id ends `:free`. One id,
approved as the paid model, priced as the free one. The table's own docstring acknowledges the
seam: *"a per-variant grade … is not expressible in the table and must be resolved by the
reader."*

**The question:** is a free variant the same model as its paid parent? Quality evidently differs
(that is the whole 2026-09-14 measurement), so treating them as one identity for approval and as
two for price is the shape that let this through.

### 2. Two date spellings for one model, and a deny only matches one

Upstream carries the **model id** form (`…-0731`) and the **permaslug** form (`…-20260731`). This
is already recorded in [`../agents/model-routing.md`](../agents/model-routing.md) §the
effective-pricing endpoint — *"takes the DATED permaslug … the wrong form returns an EMPTY
payload, not an error."*

`_denied()` (`router.py:941`) matches `model in deny or model_family(model) in deny`. The platform
claim's existing `modelDeny: [deepseek/deepseek-v4-flash-0731]` therefore does **not** block
`deepseek/deepseek-v4-flash-20260731:free`: the literal differs, and the family
(`deepseek/deepseek-v4-flash`) is not the deny entry either. The deny reads as protective and is
inert. In the pricing endpoint the wrong spelling returns an empty payload; here it returns
silence.

**The question:** should a deny be spelled in ids at all, when the id a candidate arrives under is
chosen upstream and can change without notice?

### 3. The family axis is too coarse to express "this variant, not that one"

Because `model_family()` collapses `:free`, `:exacto` and every date stamp onto one key, a
family-shaped deny cannot say "deny the free cell, keep `:exacto`" — the very distinction the
2026-09-14 measurement established. The only expressible form is an exact id, which is finding 2's
problem. The two axes the router has (exact id, family) do not include the one the evidence
produced (**variant**).

### 4. `agent-budget/sm` has no tier constraint at all

`label_map` today:

| label | policy | free reachable? |
|---|---|---|
| `agent-budget/xs` | `prefer_free: true` | yes — preferred |
| `agent-budget/sm` | `{}` | **yes — no constraint** |
| `agent-budget/md` | `tier_floor: cheap` | no (`_TIER_ORDER` free=0 < cheap=1) |
| `agent-budget/lg` | `tier_floor: large`, `never_free: true` | no |

That empty `sm` row is the proximate reason a free cell served a `sm` build.

**Measured, not assumed** (spiked and reverted, 2026-09-23): setting `never_free: true` on `xs`
and `sm` passes `devbox run router-self-test`. Adding it to `md` as well **fails** the gate — an
existing assertion pins the skip *reason* to `tier-floor:`, and `never_free` is checked first
(`router.py:1948` before `:1951`), so the reason string flips to `never-free:label_map`. `md` and
`lg` already exclude free, so only two rows would ever need it.

⚠ Note the enforcement is `m.endswith(":free")` — a **literal suffix**, not a price. A zero-priced
model served under a non-`:free` id passes `never_free` untouched. That is finding 1 again from
the other end: the router's notion of "free" is a string, not a fact about money.

### 5. Removing free *candidates* is not removing the free *rung*

`LADDER = ("free", "subscription", "paid")` is a code constant (`router.py:219`), not config. With
no eligible free candidates the shadow ladder still starts cells at the free rung and walks on —
the self-test log keeps printing `clean at free → start_tier=free`. Any "no more free tier"
intent has a config half and a code half, and they are not the same change.

The tier axis is also orthogonal to the **rail** axis: `anthropic-subscription` is a rail declared
in the `rails` block, `free` is a model tier. Removing free-tier candidates costs no stack its
subscription rail — worth stating because the two are easy to conflate.

## What would settle it

1. **Is a `:free` variant a distinct model for approval purposes?** If yes, the `models` table
   needs per-variant entries (or an explicit variant axis) and `_model_entry()` stops resolving
   through the family. If no, then quality evidence attached to a variant has nowhere to live —
   and the 2026-09-14 measurement is unrepresentable.
2. **Should exclusion be expressible on the variant axis** — something between exact id and
   family — so "deny free, keep `:exacto`" survives an upstream re-spelling?
3. **Should the router normalise the two date spellings** at ingest (permaslug ↔ model id), so a
   deny cannot miss by spelling? A lint over deny entries against the live rotation universe would
   catch the inert ones either way; today nothing does.
4. **Does `never_free` mean "not the `:free` id" or "not zero-priced"?** The price is already
   known to the router (`price` lambda, `router.py:3142`).
5. **Should `agent-budget/sm` carry a floor at all**, or is "cheapest that can do it" the point of
   the label?

## Not in scope here

The strike half is a different defect with its own home: `error_class=repetition-loop` is not in
the router's `strike_classes`, so the 12:20Z strike was never recorded, no cooldown formed, and the
same cell was re-picked `[free+half-open]` at 13:05:01Z. That is the **third** instance of
FU-201 (c)'s built-but-dead-in-production class (after `#1268` and the 2026-09-13 `no-output` one)
→ Goal homelab#1640 acceptances 1+3.
