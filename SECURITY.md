# SECURITY.md

What Cerebro can read and write **today**. Every new capability extends the blast radius and must be
added here in the same change that adds it. If this file is out of date, the review that depends on it
is worthless.

## Current inventory

**Reads**

- Work Gmail
- Slack: mentions, DMs, and the operator's own messages
- Jira: mentions, assignments, comments

**Writes**

- The local store (`cerebro.db`), and only through `registrar`
- The local vault, and only inside machine-owned regions (`cerebro:begin` / `cerebro:end`)
- Slack DM to the operator, and only via `courier` draining `outbox`

**Stores verbatim model input and output**

- The `traces` table — full prompts and responses, 30-day TTL, pruned nightly.

  Worth being explicit about, because it is the least obvious exposure here. A scout trace contains
  exactly the untrusted prose the trust boundary exists to keep out of decisions, and a Gmail scout
  trace will contain compensation or performance content the first time such a thread is swept. The TTL
  delays that exposure; it does not scope it. If `traces` turns out to be only a debugging aid, make it
  opt-in per run rather than default-on.

**Does not**

- Send email
- Comment on Jira, or write to any ticket
- Message anyone but the operator

That last group is a significant safety property. Any change to it is a category change, not an
increment — outbound sends to third parties are a declared non-goal.

## Write-path rule

**Deny wins over allow.** Where an allowlist and a denylist disagree about a path, the denylist wins.

Never written, at any depth, by any component:

```
CLAUDE.md          (including every directory's own CLAUDE.md)
profile.md
personality.md
hot.md
board.md
People/**
Confidential/**
.claude/**
.git/**
scripts/**
```

A directory's `CLAUDE.md` is the conventions file that loads when an agent works there, so rewriting
one silently changes how every later agent behaves. This is not hypothetical: a root-only `CLAUDE.md`
match once left a nested one writable by a component whose allowlist covered its parent directory.

Enforcement is a `PreToolUse` hook, not documentation. Guidance in a markdown file is advisory; hooks
are enforced. A hook must fall through (non-zero, non-2 exit) for cases it has no opinion on — a hook
exiting 0 by accident allows a call the deny rules would have blocked.

## Egress

Default deny. Each scout reaches its single declared destination through a filtering forward proxy with
a per-scout domain allowlist. `registrar`, `scribe` and `doctor` get no proxy and no network at all;
`registrar` additionally fails its build if an HTTP client appears anywhere in its dependency tree.

Allowlist domains, not IPs — CDN addresses churn.

Slack sends must pass `unfurl_links: false, unfurl_media: false`. Link unfurling is a server-side fetch
performed by Slack on a URL that may have come from untrusted content, which makes it an exfiltration
channel.

## Data location and handling

The store holds corporate email, Slack and Jira content. It runs on Porch-provisioned infrastructure,
which makes this ordinary company data handling rather than a personal-device question.

It does sit outside employer retention and legal-hold tooling. That is a policy matter to carry
knowingly, not a technical gate — and it applies to what already exists in `~/vault` and `~/.cerebro`
as much as to anything this system adds.

## Reporting

Single operator, private repo. Anything found here goes straight to Kyle.
