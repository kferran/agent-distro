# Cerebro systems registry — one row per system Cerebro can act on (deliver code, or only research).
# `checkout` = the canonical read-only checkout research reuses (no re-clone).

- project: ultron
  # ⚠️ NEVER push to main (Kyle 2026-08-02). Ultron changes land via a Bitbucket PR from a
  #    fe/<slug> branch; the merge is Kyle's. Push the FEATURE branch, never the base.
  workspace: porchsoftware              # git@bitbucket.org:porchsoftware/ultron.git
  repo: ultron
  base: main
  branch_prefix: fe/
  checkout: ~/code/worktrees/main
  delivery: bitbucket-pr
  conductor_specs_root: .ai/specs/
  pr_template: scripts/cerebro/templates/pr-ultron.md
  # reviewers: OMIT to get the repo's defaults — the adapter now FETCHES them and sends
  #   them explicitly (delivery/bitbucket.sh create_pr). ⚠️ Bitbucket applies repo default
  #   reviewers in the WEB UI ONLY; a REST create with `reviewers` omitted yields a PR with
  #   ZERO reviewers. This line previously claimed they "auto-assign (Kyle 2026-07-13)" —
  #   that was wrong, and it shipped every conductor PR unreviewable and undiscoverable
  #   (verified 2026-08-04: 15 defaults configured; #2651/#2624/#2652/#2649 all NONE).
  #   Add a reviewers: ["{uuid}"] row only to OVERRIDE the repo defaults.
  jira_key_prefix: EJA

- project: cerebro                       # v2 dev checkout of the distro. Cerebro improves ITSELF here; changes reach a running fleet only via a deliberate reinstall step.
  repo: vault
  base: main
  branch_prefix: cerebro/
  checkout: ~/code/agent-distro          # v2 dev checkout, NOT the live vault
  delivery: local-only
  worktree_root: ~/code/agent-distro-worktrees
  conductor_specs_root: .ai/specs/

- project: friday                        # git@bitbucket.org:porchsoftware/friday.git
  repo: friday
  checkout: ~/friday
  delivery: research-only

- project: ironman                       # git@bitbucket.org:porchsoftware/ironman.git — the monorepo (backend/ + frontend/ + warmachine/)
  workspace: porchsoftware               # ironman-backend / ironman-frontend = pre-2026-07-15 split repos (draining the tail); ironman-2022 = dead archive
  repo: ironman
  base: sprint-work                      # NOT main — Iron Man's default branch is sprint-work
  branch_prefix: cb/                     # TBD — no house convention observed; upgrade with delivery
  checkout: ~/code/worktrees/ironman     # read-only canonical checkout, branch sprint-work
  delivery: research-only                # upgrade to bitbucket-pr once PR conventions + reviewers are settled
  # jira_key_prefix: OMITTED — Iron Man spans many Jira projects (NW/PL/WW/EDJ/PA/BL…), not one (report Q4)

- project: porch-ai                       # git@bitbucket.org:porchsoftware/porch-ai.git — the skill chain (porch-skills / ultron:* skills)
  workspace: porchsoftware
  repo: porch-ai
  base: main                              # TRUNK (Kyle, 2026-08-02: "Porch-ai's trunk branch is main
                                          # however I am using my fe/main branch"). Briefly set to
                                          # fe/main on 2026-08-02 after inferring trunk from the
                                          # marketplace ref — wrong: fe/main is Kyle's PERSONAL branch,
                                          # and his local marketplace installs from it by choice.
                                          # Conductor work targets main; it reaches his cache when he
                                          # syncs fe/main. The two diverge (fe/main +5, main +3).
  branch_prefix: ai/                      # conductor branches: ai/<slug> (Kyle 2026-07-20 — adjust if a house convention exists)
  checkout: ~/code/porch-ai
  delivery: bitbucket-pr
  conductor_specs_root: .ai/specs/
  # reviewers: omitted — adapter fetches the repo defaults and sends them explicitly
  #   (mirrors ultron; see that row — REST does NOT auto-assign them)
  # no jira_key_prefix — skill-chain changes aren't tracked in a Jira project
