<!--
Design of record for the host router. Source in the vault:
  99 Meta/specs/2026-08-17-cerebro-host-router-design.md
Vault copy stays authoritative until Phase 0 lands. Do not edit both.
-->

# Host router — deciding which workspace owns an item

Design for the one v2 component with nothing behind it. Everything else in
the build spec (docs/build-spec.md) assumes an item already knows where it belongs; this
says how it finds out.

Kyle, 2026-08-17, asking for it: a vault dedicated to Protective on the Life project and a vault
dedicated to the Annuity project, monitored simultaneously.

## What the router is for, and what it must not do

One Cerebro instance, one comms sweep, one commitment ledger, many workspaces. `queue.host` and
`runs.host` carry the workspace name; `events`, `commitments` and `entities` deliberately do not,
because a Gmail message and a promise to a colleague belong to the operator rather than to a
directory.

So the router runs at exactly one point: **when a work item is created, it assigns `queue.host`.**

It does **not** route findings. That is a separate decision with a different rule, and a router that
did both would be wrong — see §4.

## 1. A host is a predicate over two axes, not a Jira key

The mistake this design exists to prevent is treating "which vault" as a lookup on one field. Two
independent dimensions decide it:

| Axis | Values |
|---|---|
| **Platform / codebase** | **Ultron** (annuity) · **Ironman** (life) — *"separate codepaths, integrations, and submission flow"* (`03 Resources/glossary.md`) |
| **Partner / carrier** | EDJ · Protective · Banner Life · John Hancock · Lincoln · Nationwide · Pacific Life · Penn Mutual · Prudential · Lion Street/FFR/PPG |

Kyle's own example mixes them: *"Protective on the Life project"* is Ironman × Protective, and
*"the Annuity project"* is Ultron × all partners. A host definition is therefore a predicate:

```toml
[hosts.annuity]
root     = "~/vaults/annuity"
platform = "ultron"                    # partner unconstrained

[hosts.protective-life]
root     = "~/vaults/protective-life"
platform = "ironman"
partner  = "protective"
```

Hosts must be **mutually exclusive** over the signal space. Two hosts matching one item is a config
error the router reports at load time, not a tie it breaks silently.

## 2. The `EDJ` trap, which is why this is a table and not an inference

`03 Resources/glossary.md`, verbatim:

> ⚠️ **The Jira project key `EDJ` is the LIFE platform, not annuity.** A ticket keyed `EDJ-####` is
> Life work (Ironman); annuity tickets are `EJA-####` (+ `ASD-####` for its service desk). So "EDJ"
> names the *client* whose annuity platform is Big Bet 1 **and** a Jira project that is Life — the two
> point in opposite directions. Confirmed by Kyle 2026-08-04 after `EDJ-3284` was surfaced to him as a
> go-live Sprint Blocker across four fleet ticks; it is Life, and was never his.

And the correction that kills the other tempting shortcut:

> ⚠️ **But Ironman is NOT one project's codebase — it serves carrier-specific boards too.** Ironman
> work routes by PARTNER/CARRIER, not to a single Ironman key … So "which Jira project does Ironman
> use" has no single answer and the question is malformed — ask which PARTNER the work is for.
> (Kyle, 2026-08-16.)

Two things follow. A router that pattern-matches "EDJ" to the annuity work Kyle cares most about gets
Life tickets, and that misroute has already been paid for once — four fleet ticks. And there is no
"Ironman project key" to route on, so platform has to be *derived* from the partner key rather than
read off the ticket.

## 3. The rules

### 3.1 Signals, strongest first

| Signal | Availability | Strength |
|---|---|---|
| Jira project key | every ticket-derived item | **decisive** — a closed vocabulary, no ambiguity once the table is right |
| Repo / branch | code items | **decisive** — `ultron` and `ironman` are different checkouts |
| Slack channel | channel-sourced items | strong, but channels drift and some are cross-platform |
| Email thread | mail-sourced items | weak — never decisive on its own |
| Operator capture | `operator:<uuid4>` items | none; Kyle names the host or it is `unrouted` |

### 3.2 The key table

`EJA` and `ASD` are Ultron. Everything else in the carrier space is Ironman, routed by partner.

| Key | Platform | Partner |
|---|---|---|
| `EJA` | ultron | — (annuity) |
| `ASD` | ultron | — (annuity service desk) |
| `EDJ` | **ironman** | edj |
| `PRO` | ironman | protective |
| `BL` | ironman | banner-life |
| `JH` | ironman | john-hancock |
| `LFG` | ironman | lincoln |
| `NW` | ironman | nationwide |
| `PL` | ironman | pacific-life |
| `PML` | ironman | penn-mutual |
| `PRU` | ironman | prudential |
| `MCP` | ironman | lion-street / ffr / ppg |
| `PA`, `PI` | ironman | *unconfirmed — see §6* |
| `SD` | **neither** | platform bucket, not a carrier (`profile.md`) — always `unrouted` unless a host claims it explicitly |

### 3.3 Properties

1. **Ordered table, first match wins, no model call.** Routing is a lookup. A classifier that is right
   95% of the time silently loses one ticket in twenty into the wrong inbox, where the right one never
   sees it.
2. **Every decision records the rule that fired.** `queue` gets a `host_rule` column alongside `host`,
   so a misroute is diagnosable rather than mysterious.
3. **An explicit `unrouted` bucket.** No signal, conflicting signals, or an unknown key means the item
   lands unrouted and *surfaces*. It never gets a guess and it never gets dropped — the same rule
   `rejects` follows in the build spec (§I4), for the same reason: a silently misrouted item and a
   correctly routed one look identical from the outside.
4. **Re-routing is allowed and logged.** Kyle moving an item between hosts is a normal operation, not
   a correction to a bug. It rewrites `host`, keeps `slug`, and appends to the run log.

### 3.4 Where it runs

Inside `registrar ingest`, in the same transaction that inserts the `queue` row — before the row
exists, never as a later update. That keeps I1 intact (only registrar writes) and means there is no
window where a row exists without a host.

## 4. Knowledge routing is a different decision

**Correcting my own earlier recommendation.** I argued for one shared knowledge sink across all hosts.
Kyle's answer — *"knowledge share where applicable. Keep in mind Ultron and Ironman are very different
systems with significant architectural differences"* — is right and the blanket version was wrong. The
split is not by host; it is by **kind of knowledge**.

| Kind | Scope | Where it lands |
|---|---|---|
| Architecture, implementation, capability behaviour | **platform** | `03 Resources/ultron/` or `03 Resources/ironman/` |
| Domain and business — carrier relationships, product taxonomy, regulatory, partner org facts | **shared** | the common knowledge root |

The vault already gets the first row right: `03 Resources/ultron/` and `03 Resources/ironman/` are
parallel trees, each with its own `capabilities/`. And they both contain a
`capability-form-stamping.md` — the concept name collides while the codepath does not, which is
exactly why cross-writing them would be actively wrong rather than merely untidy.

### 4.1 🔴 A live defect in the knowledge sink

`02 Areas/platform/{carriers,case-flow,forms,ownership,products}/wiki.md` is named as though it covers
"the platform." Measured 2026-08-17: **zero Ironman mentions across all five**, against Ultron
mentions in four of them. It is de-facto Ultron-scoped and labelled as though it were universal.

Today that is harmless, because only Ultron work flows through it. The moment an Ironman item is
distilled, the distiller has an allowlisted root whose name invites the write and whose content is
another platform's — and the finding lands as though it were true of Ultron.

Fix before any Ironman host goes live, not after. Either scope the root (`02 Areas/platform/ultron/…`)
or make the sink platform-aware so an Ironman finding cannot resolve to it. Flagged here as the
follow-on it is; not fixed in this pass.

## 5. What this does not solve

Named so nobody reads the router as more than it is:

- **The scheduler.** systemd unit names are fixed strings (`cerebro.timer`, `cerebro-intake.timer`, and
  four more). Running per-host schedules needs template units — `cerebro@.service` with
  `EnvironmentFile=%h/.config/cerebro/%i.env`.
- **`projects.md`.** It ships inside the distro and carries host-specific rows (`checkout`,
  `worktree_root`). A plugin cache is read-only, so those rows need a host overlay.
- **Path resolution.** `CB_VAULT` is process-global, read at call time and concatenated. Per-host
  resolution means the item's `host` resolves to a root at use time — the separation design's
  variable-collapse step, carried one step further.

## 6. Open questions

1. **`PA` and `PI` are unconfirmed.** `03 Resources/glossary.md` lists them among Life/carrier keys
   without naming the partner. `profile.md` mentions `PA` in a sprint context. Confirm before they are
   in the table, or leave them `unrouted` — which is the safe default and costs only a surfaced item.
2. **Does Kyle want a Protective-only Life host, or one Life host across all carriers?** His example
   said Protective specifically. One host per carrier is a lot of vaults; one Ironman host with
   `partner` as an item attribute may be the better shape. This is the config question the design is
   deliberately agnostic about — both are expressible as predicates.
3. **Does `SD` belong to a host at all?** It is the platform bucket rather than a carrier. Leaving it
   `unrouted` surfaces it every time, which is either correct or annoying depending on volume.

## Provenance

Measured on vault `main`, 2026-08-17.

- `03 Resources/glossary.md` — the `EDJ` entry, quoted verbatim; the authority for the key space and
  for Kyle's 2026-08-16 correction that Ironman serves carrier boards beyond EDJ.
- `03 Resources/ultron/` and `03 Resources/ironman/` — parallel capability trees; both carry
  `capability-form-stamping.md`.
- `02 Areas/platform/*/wiki.md` — grepped for `ironman` / `life` / `ultron`; the zero-Ironman result
  in §4.1 is from that sweep.
- `profile.md` — `SD` as a platform bucket rather than a carrier.
- the build spec (docs/build-spec.md) §5.3 — the `host` column and why it stores a name.
