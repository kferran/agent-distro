# lib/turnpolicy.sh — the machine-checkable half of the coordinator's turn /
# speech policy (Nick Fury P4). The full contract is prose, in
# scripts/cerebro/policy/turn-policy.md; this lib owns the ONE clause that has a
# real chokepoint today: the enumerated escalation whitelist.
#
# The point of enumerating: escalating is not a judgement call. A coordinator
# that decides case-by-case whether something is "worth surfacing" drifts — in
# both directions (chatty on no-change polls, silent on a real gate). So the
# reasons are a closed list, every escalation carries one, and cb_escalate
# refuses anything else.
#
# THE LIST IS MIRRORED IN policy/turn-policy.md (fenced `escalation-codes`
# block). tests/turnpolicy.bats asserts they are byte-identical — edit both or
# the suite fails.
cb_escalation_codes() {
  cat <<'EOF'
decision
blocked-exhausted
needs-relaunch
merge-ready
intake-ambiguous
unrecognized
EOF
}
# cb_escalation_allowed CODE — 0 iff CODE is an enumerated escalation reason.
# Whole-line literal match: a substring or a regex must not sneak past.
cb_escalation_allowed() {
  [ -n "${1:-}" ] || return 1
  cb_escalation_codes | grep -qxF -- "$1"
}
