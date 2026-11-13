---
id: EP-WIRE
use-cases: [UC-1]
schema: wire.schema.json
---
# GET /wire — what the gateway's vendors actually answered

The gateway parses every vendor answer into a normalised snapshot and used to drop the bytes. The
[wire record](../glossary.md#wire-record) keeps each vendor read's **latest** answer, per
[wire source](../glossary.md#wire-source), in the gateway's own store, so a wire shape is mined from a
recorded answer — never hand-copied, never invented. `GET /wire` and `GET /wire/<source>` are the
read-only door, like `/catalog/*`: they take no credential and return none.

## Interface — the machine half

**[`wire.schema.json`](wire.schema.json)** holds the index's shape, a record's provenance and the one
error code; the service **imports it**. A member's body is the stored bytes, not JSON of that schema.

| Requirement | Governs (schema) | Error codes | Status |
|---|---|---|---|
| [GW-WIRE-RECORD](#gw-wire-record) | `$defs.provenance` | — | v0 — declared probes and the account class's allowlist are the sibling rule (`GW-WIRE-PROBE`, not yet written) |
| [GW-WIRE-VIEW](#gw-wire-view) | `index_output`, `member_headers` | `wire-not-recorded` (404) | v0 |
| [GW-WIRE-QUARRY](#gw-wire-quarry) | — (a client of the two reads above) | — | v0 — `⚑ gap`, see the index |

## Flow overview

```mermaid
flowchart LR
  R["a vendor read\n(Go catalog · OpenRouter catalog · codex usage poll)"] --> W["the recorder\n(before the parser)"]
  W --> C{"class"}
  C -->|public: no credential, no account header| V["bytes kept verbatim"]
  C -->|account: anything else| S["structure kept,\nevery string → its length"]
  V --> T[("wire_records\nlatest per source")]
  S --> T
  R --> P["the parser (unchanged)"]
  T --> D["GET /wire · GET /wire/‹source›"]
  click W href "#gw-wire-record" "GW-WIRE-RECORD" _self
  D --> Q["wire-quarry.py\n(list · show · find · cut)"]
  Q --> F["a fixture + its provenance sidecar"]
  click D href "#gw-wire-view" "GW-WIRE-VIEW" _self
  click Q href "#gw-wire-quarry" "GW-WIRE-QUARRY" _self
```

## Requirement index

| Requirement | Section | Status |
|---|---|---|
| [GW-WIRE-RECORD](#gw-wire-record) | the recorder | v0 |
| [GW-WIRE-VIEW](#gw-wire-view) | the door | v0 |
| [GW-WIRE-QUARRY](#gw-wire-quarry) | the quarry tool | ⚑ gap (2026-11-13, PR #3303's PR → work: a provenance lint for fixtures, not yet filed): fixtures cut before the tool carry no provenance sidecar; no lint requires one |

## GW-WIRE-RECORD

Every vendor read the gateway makes registers a [wire source](../glossary.md#wire-source) and a class,
and hands its answer to the recorder before its parser reads it; the parser, the snapshots and the
views read exactly what they read before. The registered sources are `go-models-dev`, `go-console-config`
and `go-docs` (the Go catalog's three reads), `openrouter-endpoints`, `openrouter-mcp-rankings` and
`openrouter-mcp-benchmarks` (the OpenRouter catalog's reads — `openrouter-endpoints` is one read per
candidate model, so it keeps the last model's answer) and `codex-usage` (the usage poll).

A source is `public` when the read sent no credential and no account header: the answer's bytes are
kept verbatim. Every other read is `account`: the answer is sanitised structurally before it is
persisted — keys, numbers, booleans and nulls stay, every string becomes `{"len": n}` ⚖ (an unseen
payload can carry identity nobody listed, so a scrub of known values is rejected). The class is
decided by what the read sent, not by the caller's declaration: a read that carried a credential is
never `public`. Only the latest answer is kept, one row per source; a failed read (a non-200, an
unreachable vendor) leaves the last good answer in place and records the failure beside it ⚖. An
answer is bounded (`GATEWAY_WIRE_MAX_BYTES`, default 1048576): a `public` answer over the bound is
cut and marked `complete: false`; an `account` answer over it keeps no structure (a cut document has
none) and records `over-bound`. An answer that echoes a credential the gateway holds is withheld whole.
The record is in the SQLite store and survives a restart. A recorder fault never takes a read down.
The `sha256` is the answer's digest as the vendor sent it.

Unverified — expected to hold, no row yet: an `account` answer over the bound records `over-bound`;
a recorder fault never takes a read down; the parsers, snapshots and views are unchanged; the sources
`go-docs`, `openrouter-endpoints`, `openrouter-mcp-rankings` and `openrouter-mcp-benchmarks` record as
described.

**World: [policy-codex](../worlds/README.md#policy-worlds)** — every world's gateway starts from the Go
catalog's fakes; the codex usage fake answers the observed shape (synthetic values, dummy identity).

#### A read's answer is kept

Legend: `read` = the answer the fake gives at the stated time; `credential_sent` = the credential the
read carries; `source_class?` = the class the source is recorded under; `stored?` = the record's bytes; `sha256?` = the record's digest; `fetched_at?` =
the record's time.

| description | source | read | credential_sent | source_class? | stored? | sha256? | fetched_at? |
|---|---|---|---|---|---|---|---|
| a public read's bytes are kept verbatim | `go-models-dev` | `catalog-ok at T0` | none (no credential, no account header) | `public` | the fake's bytes, byte-identical | the bytes' sha256 | `T0` |
| a later answer replaces it | `go-models-dev` | `catalog-ok at T0, then catalog-trimmed at T0 + 21600 s` | none (no credential, no account header) | `public` | the later bytes | the later bytes' sha256 | `T0 + 21600 s` |
| a shape the parser refuses is still recorded ⚖ | `go-models-dev` | `catalog-malformed at T0` | none (no credential, no account header) | `public` | the malformed bytes | their sha256 | `T0` |
| an account read keeps its structure and no string value ⚖ | `codex-usage` | `the observed usage shape at T0` | the codex bearer and account header | `account` | every key, number and boolean; every string `{"len": n}` | the raw bytes' sha256 | `T0` |

#### A failed read, a bound, a restart

Legend: `max_bytes` = the recorder's bound; `last_ok?` = the kept answer's bytes; `last_error?` = the
failure recorded beside it; `complete?` = whether the kept answer is whole (a source with no kept
answer is whole).

| description | source | read | max_bytes | last_ok? | last_error? | complete? |
|---|---|---|---|---|---|---|
| a failed read keeps the last good answer and records the failure beside it ⚖ | `go-models-dev` | `catalog-ok at T0, then catalog-503 at T0 + 60 s` | `1048576` | T0's bytes | status 503 at the later time | `true` |
| an unreachable vendor records no bytes | `go-models-dev` | `catalog-down at T0` | `1048576` | none | unreachable | `true` |
| an answer over the bound is cut and says so ⚖ | `go-models-dev` | `catalog-ok at T0` | `600` | the first 600 bytes | none | `false` |
| a record survives a restart | `go-models-dev` | `catalog-ok at T0, restart at T0 + 3600 s` | `1048576` | T0's bytes | none | `true` |

#### The credential never lands in a record

Legend: `credential_sent` = the credential the read carries; `source_class?` = the class the source is
recorded under; `last_error?` = the failure the recorder notes beside the source (`status <n>` = a non-200
answer, of which no byte is kept; `withheld` = a 200 answer that echoed a credential the gateway holds, no part of it kept); `record_fields_with_key?` =
the number of the stored record's fields (body included) that contain the Go key;
`log_lines_with_key?` = the log lines that do.

| description | source | read | credential_sent | source_class? | last_error? | record_fields_with_key? | log_lines_with_key? |
|---|---|---|---|---|---|---|---|
| a vendor answer that echoes the key is withheld ⚖ | `go-console-config` | `config-401-echo` | `the Go key as a bearer` | `account` | `status 401` | `0` | `0` |
| a good answer that echoes the key is withheld whole ⚖ | `go-console-config` | `config-200-echo` | `the Go key as a bearer` | `account` | `withheld` | `0` | `0` |
| a read that carried a credential is never class public ⚖ | `go-console-config` | `config-ok` | `the Go key as a bearer` | `account` | `none` | `0` | `0` |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "GW-WIRE-RECORD.md"

</details>

## GW-WIRE-VIEW

`GET /wire` answers the index: for every source with a record, its provenance (class, url, status,
bytes, sha256, fetched_at, age_s, complete, and the last failure) and no body. `GET /wire/<source>` answers one
member: the stored bytes as the body, the provenance in `x-wire-source`, `x-wire-class`,
`x-wire-sha256`, `x-wire-fetched-at` and `x-wire-complete`. A source with no good answer is not an
empty answer: `404 wire-not-recorded`. The door asks for no credential ⚖ (like `/catalog/*`, it
is reachable by whoever reaches the gateway's port, so it may carry nothing a credential would
protect — which is what the `account` class's sanitising is for), and returns none: every
`account` body is structure and lengths.

Unverified — expected to hold, no row yet: an `account` body served through the door is its sanitised
structure; a source whose every read failed answers 404.

**World: [policy-codex](../worlds/README.md#policy-worlds)** — as GW-WIRE-RECORD.

#### The door

Legend: `recorded` = the answers on file at T0; `call` = the request made; `answer?` = the response's body (a JSON shape, or the stored bytes) and the headers it names.

| description | recorded | call | status? | answer? |
|---|---|---|---|---|
| the index lists every source with its provenance and no body | `go-models-dev and go-console-config at T0` | `GET /wire` | `200` | `sources` = one entry per source on file, each exactly source, class, url, status, bytes, sha256, fetched_at, age_s, complete, last_error, last_error_at; no body |
| one member is its stored bytes, the provenance in headers ⚖ | `go-models-dev at T0` | `GET /wire/go-models-dev` | `200` | body = the stored bytes; headers x-wire-source, x-wire-class, x-wire-sha256, x-wire-fetched-at, x-wire-complete |
| a source never read is not an empty answer | `nothing for go-docs` | `GET /wire/go-docs` | `404` | `wire-not-recorded` |
| the door asks for no credential ⚖ | `go-models-dev at T0` | `GET /wire/go-models-dev`, no token | `200` | body = the stored bytes, `x-wire-class` = `public` |
| the view's shape is the schema's | `go-models-dev at T0` | `GET /wire` | `200` | exactly the schema's required keys |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "GW-WIRE-VIEW.md"

</details>

## GW-WIRE-QUARRY

`gateway/scripts/wire-quarry.py` is the loop's hand on the door: a standard-library tool that reads
`GET /wire` and `GET /wire/<source>` and nothing else, so a fixture is mined from a recorded answer, never
hand-copied. It takes the door's base URL from `WIRE_DOOR_URL` (default: the cluster Service,
`http://agent-gateway.agent-egress.svc.cluster.local:8080`) and holds and sends no credential. `show <source>`
prints the stored bytes unchanged on stdout and one provenance line on stderr; `list` prints the index, one
line per source (name, class, status, age); `find --key <name>` prints each JSON member's source and the
path of every occurrence of that key; `cut <source> --path <a.b.c> --out <file>` writes that subtree of the
recorded answer (values and key order as recorded — no wrapper key ⚖) to `<file>` and a sidecar
`<file stem>.provenance.json` beside it (source, class, url, sha256 of the whole answer, fetched_at, path). A
key containing a dot (`deepseek-v4.1-flash`) is matched whole. Exit codes ⚖: `3` the door is silent, `4` the
source is not recorded, `5` the path is not in the answer or the member is not JSON, `6` the record is
truncated (`complete: false`). Whatever the exit, a failed `cut` writes no file: the door not answering is
never an empty or invented fixture. `devbox run wire-quarry -- <verb>` runs it from `gateway/`.

Unverified — expected to hold, no row yet: the tool sends no credential and imports the standard library
only; `--path` is JSON-only (the Go page, `go-docs`, is read with `show`); `cut` on an `account` source
cuts its sanitised structure.

**World: [policy-codex](../worlds/README.md#policy-worlds)** — the door holds `go-models-dev`, the
`catalog-ok` bytes at T0.

#### Reading the door

Legend: `door` = what the door holds (`unreachable` = nothing listens at its URL); `command` = the tool's
arguments; `exit?`, `stdout?`, `stderr?` = what the process returns.

| description | door | command | exit? | stdout? | stderr? |
|---|---|---|---|---|---|
| `show` prints one member verbatim and one provenance line | `go-models-dev at T0` | `show go-models-dev` | `0` | the stored bytes, byte-identical | `wire: source=go-models-dev class=public sha256=<…> fetched_at=T0` |
| `list` prints the index | `go-models-dev at T0` | `list` | `0` | one line per source: name, class, status, age | — |
| `find` names the sources that have a key, with its path ⚖ | `go-models-dev at T0` | `find --key cost` | `0` | `go-models-dev` and each JSON path ending in `cost` | — |
| a key no source has is an empty answer, not an error | `go-models-dev at T0` | `find --key nothing-has-this` | `0` | nothing | — |
| a door with no record lists nothing | `nothing recorded` | `list` | `0` | nothing | — |
| a source nobody recorded is an error, never an empty answer | `go-models-dev at T0` | `show codex-models` | `4` | nothing | `wire: codex-models not recorded` |
| a silent door is an error that names the door ⚖ | `unreachable` | `show go-models-dev` | `3` | nothing | `wire: door unreachable: <url>` |

#### Cutting a fixture

Legend: `door` and `command` as above (`<dir>` = a fresh directory); `fixture?` = the file the command
was told to write; `sidecar?` = the file beside it.

| description | door | command | exit? | fixture? | sidecar? |
|---|---|---|---|---|---|
| `cut` writes the fragment's values unchanged and a sidecar ⚖ | `go-models-dev at T0` | `cut go-models-dev --path opencode-go.models.deepseek-v4-pro --out <dir>/m.json` | `0` | that subtree, values and key order as recorded | `<dir>/m.provenance.json`: source, class, url, sha256 of the whole answer, fetched_at, path |
| a path the answer does not have writes nothing | `go-models-dev at T0` | `cut go-models-dev --path opencode-go.models.nope --out <dir>/m.json` | `5` | no file | no file |
| a truncated record is never cut | `go-models-dev, complete: false` | `cut go-models-dev --path opencode-go --out <dir>/m.json` | `6` | no file | no file |
| a silent door writes nothing | `unreachable` | `cut go-models-dev --path opencode-go --out <dir>/m.json` | `3` | no file | no file |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "GW-WIRE-QUARRY.md"

</details>
