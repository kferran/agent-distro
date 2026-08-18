<!--
GENERATED FILE — DO NOT EDIT.

Source of truth:  99 Meta/specs/2026-08-17-cerebro-host-router-design.md
In:               the vault repo (porch-vault), origin/main
At commit:        83c3a1fa

Regenerate:       ./scripts/sync-specs.sh
Detect drift:     ./scripts/sync-specs.sh --check

Edits made here are lost on the next sync. Edit the vault copy.
-->

# Host router — deciding which workspace owns an item

Design for the one v2 component with nothing behind it. Everything else in
the build spec (docs/build-spec.md) assumes an item already knows where it belongs; this
says how it finds out.

> ## ⏸ Deferred — build one vault, keep the seams
>
> Kyle, 2026-08-17: *"Let's start with single vault while I am the single user on this system. As we
> grow and move into potentially allowing multiple users access this may need to split into multiple
> vaults."*
>
> **Nothing in this document gets built now.** With one vault there is one host, every item routes to
> it, and a router is a lookup that always returns the same answer. Building it would be machinery
> without a job.
>
> **What stays anyway, because it costs a line each and buys the option:**
> `queue.host` and `runs.host` (already in the build spec §5.3), and `queue.platform` from §1 below.
> With one vault every row carries the same `host` and a real `platform` — and `platform` earns its
> keep immediately, because it is what routes a finding to `03 Resources/ultron/` versus
> `03 Resources/ironman/` (§4). That distinction is live on day one even with a single vault.
>
> **The trigger is multiple users, not vault count** — which matters, because multi-user is a bigger
> change than multi-vault and hits different tables. See §7.
>
> ### And the cheaper answer may be that this is never built
>
> Kyle, 2026-08-17: *"Each vault could be separate claude instances with their own CLAUDE.md files and
> operating rules rather than attempting to have Cerebro handle multiple vaults simultaneously."*
>
> That is very likely right, and it splits the problem along a seam this document does not use.
> **There are two layers here and only one of them wants a router:**
>
> - **Operating rules — how an agent should behave in a given context.** Per-directory `CLAUDE.md`
>   already does this and always has: `03 Resources/CLAUDE.md`, `Meetings/CLAUDE.md`,
>   `02 Areas/development/CLAUDE.md`. An Ultron/annuity workspace and an Ironman/life workspace want
>   genuinely different conventions and vocabulary, and nothing in this spec addresses that — `host` and
>   `platform` say where data goes, not how to behave once you are there. Separate instances get it for
>   free.
> - **Operator surfaces — comms sweep, commitments, dispatch.** These stay single-instance regardless,
>   for the reason in §4.2: one Gmail, one Slack, one Jira, one person. N instances sweeping the same
>   mailbox extract the same promise N times and nudge N times, and no per-vault `CLAUDE.md` fixes that.
>
> So the likely end state is **separate instances for working context, one instance for the operator
> layer** — and a host router is only needed if the operator layer itself has to fan work out across
> workspaces. Do not unpark this document without first checking whether per-vault `CLAUDE.md` plus one
> comms instance already covers the case. It probably does.

Original framing, retained because the analysis holds whenever the split happens — Kyle, 2026-08-17:
a vault dedicated to Protective on the Life project and a vault dedicated to the Annuity project,
monitored simultaneously.

## What the router is for, and what it must not do

One Cerebro instance, one comms sweep, one commitment ledger, many workspaces. `queue.host` and
`runs.host` carry the workspace name; `events`, `commitments` and `entities` deliberately do not,
because a Gmail message and a promise to a colleague belong to the operator rather than to a
directory.

So the router runs at exactly one point: **when a work item is created, it assigns `queue.host`.**

It does **not** route findings. That is a separate decision with a different rule, and a router that
did both would be wrong — see §4.

## 1. Two kinds of vault, and one field each

An earlier draft of this section modelled a host as a predicate over platform × partner and required
hosts to be **mutually exclusive** — two hosts matching one item was a config error. Kyle's real
topology breaks that, and the break is instructive:

> ironman · Ultron · EDJ (life) · EDJ (annuities) · Nationwide (life, annuities) ·
> Pacific Life (life, annuities) · Lion Street · Nationwide Single Platform · etc.

Those overlap by construction. An EDJ annuities ticket is EDJ work **and** Ultron work. A Nationwide
Single Platform ticket is Nationwide work too. Under mutual exclusivity every one of those is a config
error, which means the constraint was wrong rather than the topology.

**The list contains two different kinds of thing, and separating them dissolves the overlap.**

| Kind | Examples | Holds | Answers |
|---|---|---|---|
| **Platform vault** | Ultron, Ironman | architecture, capabilities, how the codebase behaves — plus platform-infrastructure work | *how does the thing work?* |
| **Engagement vault** | EDJ (annuities), EDJ (life), Nationwide, Pacific Life, Lion Street | tickets, meetings, stakeholders, delivery status | *what do we owe this partner?* |

An item never needs to belong to two vaults. It needs **two fields**:

```sql
host      TEXT NOT NULL,   -- which ENGAGEMENT vault owns the work (single; a partition)
platform  TEXT NOT NULL,   -- which CODEBASE it touches (ultron|ironman|none)
```

An EDJ annuities ticket is `host = edj-annuities`, `platform = ultron`. It lands in the EDJ annuities
inbox; its findings distill into the Ultron knowledge tree. No overlap, no precedence rules, no
many-to-many join.

This also explains **Nationwide (life, annuities)** as a single vault covering both platforms: `host =
nationwide` with `platform` varying per item. Platform is a property of the work, not of the vault —
which is precisely why it is a separate column rather than part of the host predicate.

Platform vaults still hold items — `platform-hardening`, `ultron-e2e-coverage`, `ppfa-extractor-refactor`
are real projects today. Those are simply `host = ultron`, `platform = ultron`.

**Hosts remain mutually exclusive; the axis changed.** Exclusivity is required over *engagements*,
which genuinely do partition, rather than over the full signal space, which does not.

### 1.1 A partner is not one kind of thing

Kyle, 2026-08-17, on what `Nationwide Single Platform` is: *"an Ironman installation for Nationwide
directly rather than a distribution group like EDJ, Lion Street or FFR."*

That is a third axis, and it explains why `Nationwide` appears twice in the same list without either
entry being a mistake:

| Relationship | Who they are | Examples |
|---|---|---|
| **Distribution group** | distributes products from many carriers; Porch's platform serves the distributor | EDJ · Lion Street · FFR |
| **Direct installation** | the carrier runs the platform itself | Nationwide Single Platform |
| **Carrier as product source** | their products flow through someone else's distribution | Nationwide · Pacific Life · Protective, as they appear in an EDJ or Lion Street context |

So **Nationwide (life, annuities)** and **Nationwide Single Platform** are two different relationships
with the same company, not a duplicate. One is a carrier whose products flow through distributors; the
other is a direct Ironman installation.

🔴 **This breaks the key table in §3.2 and the fix is not obvious.** `NW` maps to "nationwide" — but
which one? A `NW` ticket could be Nationwide-as-carrier work inside a distributor engagement, or
Nationwide-Single-Platform installation work. The Jira key alone cannot tell them apart, which means
the "decisive" rating for project key in §3.1 is wrong for at least this partner and probably for any
carrier that is also a direct installation.

Whoever builds this needs a second signal for those cases — board, component, label, or a separate
project key if one exists. Until then those items are `unrouted` by rule rather than guessed at. This
is the single largest open problem in the routing design and it did not surface until Kyle described
what the vaults actually are.

### 1.2 When does something earn its own vault?

"etc." guarantees more of these, so the rule matters more than any individual ruling.

Proposed: **an engagement earns a vault when it has its own stakeholders and its own cadence.** Shared
stakeholders and shared cadence means a project folder inside an existing vault. That keeps the vault
count tied to how Kyle actually works rather than to how many names exist.

### 1.3 What platform vaults hold

Kyle, 2026-08-17: *"Both work and knowledge. Work should mostly come out of Jira, so I guess given
that this would mostly be knowledge."*

So `host = ultron` and `host = ironman` items exist but are the exception — `platform-hardening`,
`ultron-e2e-coverage`, `ppfa-extractor-refactor` are the shape. Ticket-derived work almost always
belongs to an engagement, because a Jira key names a partner board. Platform vaults are predominantly
knowledge stores that happen to carry a little infrastructure work.

Practical consequence for the router: **if an item's only signal is a partner Jira key, it never routes
to a platform vault.** Platform-vault items arrive from operator capture or from repo/branch signals on
platform-infrastructure branches, not from the key table.

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
| `NW` | ironman | nationwide — ⚠️ **ambiguous**, see §1.1: carrier-as-product-source or the direct Single Platform installation. Needs a second signal. |
| `PL` | ironman | pacific-life |
| `PML` | ironman | penn-mutual |
| `PRU` | ironman | prudential |
| `MCP` | ironman | lion-street / ffr / ppg |
| `EJSD` | ironman | edj — Edward Jones **Insurance** Service Desk, the Life-side counterpart to `ASD` |
| `PSD` | ironman | protective — Protective Service Desk |
| `PA` | **neither** | **Platform Architecture** — internal, not a carrier |
| `PI` | **neither** | **Porch Internal Initiatives** — internal, not a carrier |
| `SD` | **neither** | **Software Development** — internal, not a carrier |
| `ARCH` | ultron | **Annuity Architecture** — internal to the annuity platform |

The last four route to a platform vault or to `unrouted`, never to a partner. Verified against live Jira
2026-08-17 (`getVisibleJiraProjects`, 36 projects): **`PA` is Platform Architecture and `PI` is Porch
Internal Initiatives.** Both were listed among the Life/carrier keys in `03 Resources/glossary.md`,
which would have routed internal platform work to a carrier engagement; the glossary is corrected.
`EJSD` and `PSD` were missing from the vault's key list entirely.

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

### 4.2 Operator-scoped surfaces must not fragment

The same argument that kept `host` off `events` and `commitments` applies to whole directories, and it
gets sharper as the vault count rises. `People/`, `Meetings/`, `Daily/`, `hot.md` and the commitment
ledger belong to **Kyle**, not to an engagement. A person who works across EDJ and Nationwide has one
file, not two. A 1:1 covering three partners is one meeting.

With two vaults this is a preference. With fifteen it is the difference between a system and a filing
problem — fragmenting `People/` across fifteen roots means no answer to "what do I owe this person"
exists anywhere.

So the vault count applies to **work and platform knowledge only**. Operator surfaces stay in one
place, which today is `~/vault`.

### 4.3 The cost that scales with vault count

Isolation that helps the machine hurts the human at N vaults. Every one of them is a git repo, a
`00 Inbox/`, and — the part that matters — **a place Kyle has to look**.

Two consequences worth designing for before the count grows rather than after:

- **The board must be cross-host by default**, grouped by host rather than one board per vault. One
  board answering "what needs me" across everything is the whole reason the single-instance
  architecture was chosen over N instances.
- **The daily note stays operator-scoped**, per §4.2 — one note aggregating across hosts, not fifteen.

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

1. ~~**`PA` and `PI` are unconfirmed.**~~ ✅ **Resolved 2026-08-17 against live Jira.** `PA` is Platform
   Architecture, `PI` is Porch Internal Initiatives — neither is a carrier. The glossary said otherwise
   and is corrected. Also found: `EJSD` and `PSD`, two Life-side service desks absent from the vault's
   key list, and `ARCH` (Annuity Architecture) on the Ultron side.

   Worth keeping as a method note rather than deleting: the vault's key list was wrong in three places
   and incomplete in three more, and one `getVisibleJiraProjects` call settled all six. **The key table
   is derivable from Jira and should be generated rather than hand-maintained** — a hand-written copy of
   an authoritative list is a copy that drifts, which is what happened here.
2. 🔴 **How does a `NW` item split between Nationwide-as-carrier and Nationwide Single Platform?**
   §1.1. The largest unsolved routing problem, and it generalises to any carrier that is also a direct
   installation. Needs a second signal — board, component, label — or those items stay `unrouted`.
3. **Does `SD` belong to a host at all?** It is the platform bucket rather than a carrier. Leaving it
   `unrouted` surfaces it every time, which is either correct or annoying depending on volume.
4. **When the split comes, is it driven by engagements or by users?** §7 argues they are different
   problems and that the user work dominates. Worth deciding deliberately rather than discovering it.

**Answered 2026-08-17 and recorded so they are not re-asked:** single vault to start, trigger is
multiple users (banner above) · `Nationwide Single Platform` is a direct Ironman installation, not a
distribution group (§1.1) · platform vaults hold both work and knowledge, in practice mostly knowledge
(§1.3).

## 7. Multi-user is a bigger change than multi-vault, and it hits the other tables

Kyle named multiple users as the trigger for splitting vaults. Worth separating the two, because they
are not the same problem and the vault split is the smaller half.

The build spec deliberately gives `host` to `queue` and `runs` only. `events`, `commitments` and
`entities` are **operator-scoped** — a Gmail message and a promise to a colleague belong to the person,
not to a directory. That reasoning is sound for one operator and is exactly what breaks with two.

| Table | Multi-vault | Multi-user |
|---|---|---|
| `queue`, `runs` | `host` — done | needs an owner, and a rule for who may claim |
| `events` | untouched | **whose mailbox?** Two users sweeping the same Slack channel produce the same event twice |
| `commitments` | untouched | **whose promise?** The nudge ladder targets a person; direction (`i_owe`) is meaningless without knowing who "I" is |
| `entities` | untouched | `is_self` is a single boolean today |
| `traces` | untouched | one user's prompts become readable by another |

So the tables that need no change for multi-vault are precisely the ones multi-user rewrites. The
sequencing follows: **splitting vaults first buys nothing toward multi-user**, and doing the user work
first makes the vault split mechanical. If the real goal is other people using this, the vault
question is downstream of it.

Two more that are not schema at all and are easy to miss: `Confidential/` is currently a
you-do-not-read-it convention enforced by prose and a four-entry deny list, which does not survive a
second reader; and `~/.cerebro/env` holds one set of credentials, so today every user would act as
Kyle against Jira and Slack.

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
