# memcap.sh — memory-aware spawn gate (T34). Ultron `vue-tsc --build` +
# dotnet contention has produced real exit-137 OOM kills, so intake never
# spawns into pressure: memcap_ok succeeds iff MemAvailable ≥
# CB_RAM_HEADROOM_MB (default 8192, §11 operator input) AND live code-agent
# count < CB_AGENT_CAP (default 6 since 2026-07-17; started at 3, the autofix
# concurrency precedent).
# /proc/meminfo mockable via CB_FREE_CMD.
# paths.sh is load-bearing here: it defaults CB_HOME. Without it, a consumer
# that sources only memcap.sh gets an empty CB_HOME, the task glob matches
# nothing, and the agent-cap check silently fails OPEN (counts zero agents).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/paths.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/classify.sh"
: "${CB_RAM_HEADROOM_MB:=8192}"
: "${CB_AGENT_CAP:=6}"   # raised 3→6 (Kyle 2026-07-17) for bug-push throughput; RAM-gated by memcap_ok. Override via env if needed.

memcap_ok() {
  local avail_kb avail_mb n=0 d s
  avail_kb="$(eval "${CB_FREE_CMD:-cat /proc/meminfo}" | awk '/^MemAvailable:/{print $2; exit}')"
  avail_mb=$(( ${avail_kb:-0} / 1024 ))
  if [ "$avail_mb" -lt "$CB_RAM_HEADROOM_MB" ]; then
    echo "memcap: ${avail_mb}MB available < ${CB_RAM_HEADROOM_MB}MB headroom — not spawning"
    return 1
  fi
  for d in "$CB_HOME"/tasks/*/; do
    [ -d "$d" ] || continue
    [ "$(_meta_field "${d%/}" kind)" = "code" ] || continue
    s="$(_meta_field "${d%/}" session)"; [ -n "$s" ] || s="$(basename "$d")"
    [ "$(cb_session_alive "$s")" = "alive" ] && n=$(( n + 1 ))
  done
  if [ "$n" -ge "$CB_AGENT_CAP" ]; then
    echo "memcap: at agent cap ($n/$CB_AGENT_CAP live code agents)"
    return 1
  fi
  return 0
}
