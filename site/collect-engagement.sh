#!/usr/bin/env bash
# =============================================================================
# collect-engagement.sh — Parse Caddy access logs into engagement evidence
#
# Reads Caddy's structured JSON access log, extracts visitor engagement data
# for the last 24 hours, and writes a dated JSON report to evidence/engagement/.
#
# The planner consumes these reports to close the build→ship→learn loop:
# an addressable (disinto.ai) becomes observable when engagement data flows back.
#
# Usage:
#   bash site/collect-engagement.sh
#
# Cron: 55 23 * * * cd /home/debian/dark-factory && bash site/collect-engagement.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"

LOGFILE="${FACTORY_ROOT}/site/collect-engagement.log"
log() {
  printf '[%s] collect-engagement: %s\n' \
    "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >> "$LOGFILE"
}

# ── Configuration ────────────────────────────────────────────────────────────

# Caddy structured access log (JSON lines)
CADDY_LOG="${CADDY_ACCESS_LOG:-/var/log/caddy/access.log}"

# Evidence output directory (committed to git)
EVIDENCE_DIR="${FACTORY_ROOT}/evidence/engagement"

# Report date — defaults to today
REPORT_DATE=$(date -u +%Y-%m-%d)

# Cutoff: only process entries from the last 24 hours
CUTOFF_TS=$(date -u -d '24 hours ago' +%s 2>/dev/null \
  || date -u -v-24H +%s 2>/dev/null \
  || echo 0)

# ── Preflight checks ────────────────────────────────────────────────────────

if [ ! -f "$CADDY_LOG" ]; then
  log "ERROR: Caddy access log not found at ${CADDY_LOG}"
  echo "ERROR: Caddy access log not found at ${CADDY_LOG}" >&2
  echo "Set CADDY_ACCESS_LOG to the correct path." >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  log "ERROR: jq is required but not installed"
  exit 1
fi

mkdir -p "$EVIDENCE_DIR"

# ── Parse access log ────────────────────────────────────────────────────────

log "Parsing ${CADDY_LOG} for entries since $(date -u -d "@${CUTOFF_TS}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "${CUTOFF_TS}")"

# Extract relevant fields from Caddy JSON log lines.
# Caddy v2 structured log format:
#   ts (float epoch), request.uri, request.remote_ip, request.headers.Referer,
#   request.headers.User-Agent, status, size, duration
#
# Filter to last 24h, exclude assets/bots, produce a clean JSONL stream.
PARSED=$(jq -c --argjson cutoff "$CUTOFF_TS" '
  select(.ts >= $cutoff)
  | select(.request.uri != null)
  | {
      ts: .ts,
      ip: (.request.remote_ip // .request.remote_addr // "unknown"
           | split(":")[0]),
      uri: .request.uri,
      status: .status,
      size: .size,
      duration: .duration,
      referer: (.request.headers.Referer[0] // .request.headers.referer[0]
                // "direct"),
      ua: (.request.headers["User-Agent"][0]
           // .request.headers["user-agent"][0] // "unknown")
    }
' "$CADDY_LOG" 2>/dev/null || echo "")

if [ -z "$PARSED" ]; then
  log "No entries found in the last 24 hours"
  jq -nc \
    --arg date "$REPORT_DATE" \
    --arg source "$CADDY_LOG" \
    '{
      date: $date,
      source: $source,
      period_hours: 24,
      total_requests: 0,
      unique_visitors: 0,
      page_views: 0,
      top_pages: [],
      top_referrers: [],
      note: "no entries in period"
    }' > "${EVIDENCE_DIR}/${REPORT_DATE}.json"
  log "Empty report written to ${EVIDENCE_DIR}/${REPORT_DATE}.json"
  exit 0
fi

# ── Compute engagement metrics ──────────────────────────────────────────────

# Filter out static assets and known bots for page-view metrics
PAGES=$(printf '%s\n' "$PARSED" | jq -c '
  select(
    (.uri | test("\\.(css|js|png|jpg|jpeg|webp|ico|svg|woff2?|ttf|map)$") | not)
    and (.ua | test("bot|crawler|spider|slurp|Googlebot|Bingbot|YandexBot"; "i") | not)
    and (.status >= 200 and .status < 400)
  )
')

TOTAL_REQUESTS=$(printf '%s\n' "$PARSED" | wc -l | tr -d ' ')
PAGE_VIEWS=$(printf '%s\n' "$PAGES" | grep -c . || echo 0)
UNIQUE_VISITORS=$(printf '%s\n' "$PAGES" | jq -r '.ip' | sort -u | wc -l | tr -d ' ')

# Top pages by hit count
TOP_PAGES=$(printf '%s\n' "$PAGES" | jq -r '.uri' \
  | sort | uniq -c | sort -rn | head -10 \
  | awk '{printf "{\"path\":\"%s\",\"views\":%d}\n", $2, $1}' \
  | jq -sc '.')

# Top referrers (exclude direct/self)
TOP_REFERRERS=$(printf '%s\n' "$PAGES" | jq -r '.referer' \
  | grep -v '^direct$' \
  | grep -v '^-$' \
  | grep -v 'disinto\.ai' \
  | sort | uniq -c | sort -rn | head -10 \
  | awk '{printf "{\"source\":\"%s\",\"visits\":%d}\n", $2, $1}' \
  | jq -sc '.' 2>/dev/null || echo '[]')

# Unique visitors who came from external referrers
REFERRED_VISITORS=$(printf '%s\n' "$PAGES" | jq -r 'select(.referer != "direct" and .referer != "-" and (.referer | test("disinto\\.ai") | not)) | .ip' \
  | sort -u | wc -l | tr -d ' ')

# Response time stats (p50, p95, p99 in ms)
RESPONSE_TIMES=$(printf '%s\n' "$PAGES" | jq -r '.duration // 0' | sort -n)
RT_COUNT=$(printf '%s\n' "$RESPONSE_TIMES" | wc -l | tr -d ' ')
if [ "$RT_COUNT" -gt 0 ]; then
  P50_IDX=$(( (RT_COUNT * 50 + 99) / 100 ))
  P95_IDX=$(( (RT_COUNT * 95 + 99) / 100 ))
  P99_IDX=$(( (RT_COUNT * 99 + 99) / 100 ))
  P50=$(printf '%s\n' "$RESPONSE_TIMES" | sed -n "${P50_IDX}p")
  P95=$(printf '%s\n' "$RESPONSE_TIMES" | sed -n "${P95_IDX}p")
  P99=$(printf '%s\n' "$RESPONSE_TIMES" | sed -n "${P99_IDX}p")
else
  P50=0; P95=0; P99=0
fi

# ── Write evidence ──────────────────────────────────────────────────────────

OUTPUT="${EVIDENCE_DIR}/${REPORT_DATE}.json"

jq -nc \
  --arg date "$REPORT_DATE" \
  --arg source "$CADDY_LOG" \
  --argjson total_requests "$TOTAL_REQUESTS" \
  --argjson page_views "$PAGE_VIEWS" \
  --argjson unique_visitors "$UNIQUE_VISITORS" \
  --argjson referred_visitors "$REFERRED_VISITORS" \
  --argjson top_pages "$TOP_PAGES" \
  --argjson top_referrers "$TOP_REFERRERS" \
  --argjson p50 "${P50:-0}" \
  --argjson p95 "${P95:-0}" \
  --argjson p99 "${P99:-0}" \
  '{
    date: $date,
    source: $source,
    period_hours: 24,
    total_requests: $total_requests,
    page_views: $page_views,
    unique_visitors: $unique_visitors,
    referred_visitors: $referred_visitors,
    top_pages: $top_pages,
    top_referrers: $top_referrers,
    response_time: {
      p50_seconds: $p50,
      p95_seconds: $p95,
      p99_seconds: $p99
    }
  }' > "$OUTPUT"

log "Engagement report written to ${OUTPUT}: ${UNIQUE_VISITORS} visitors, ${PAGE_VIEWS} page views"
echo "Engagement report: ${UNIQUE_VISITORS} unique visitors, ${PAGE_VIEWS} page views → ${OUTPUT}"
