#!/usr/bin/env bash
# stats.sh — Summarise agent-run telemetry (#1102)
#
# Reads the JSONL record written by lib/agent-metrics.sh (#1101) for each
# finished agent session and renders a per-role summary table (or JSON).
#
#   stats_main [--since <N>d|<N>h] [--role <role>] [--task <ref>] [--json]
#
# Reads ${DISINTO_LOG_DIR:-/tmp}/metrics/agent-runs.jsonl. Malformed lines
# (e.g. a torn final line from a concurrent writer) are skipped and counted,
# never fatal. A missing or empty metrics file prints a short message and
# returns 0.
#
# Delivery vs termination (#1167): a run with a non-success outcome that
# still pushed work (delivered: true) is counted in a separate `partial`
# column, not in the outcome columns, so a delivered timeout is not read as
# a bare failure. delivered absent (pre-#1167 records) is treated as null
# and the run stays in its outcome column, unchanged.
#
# Tests: tests/lib-stats.bats

set -euo pipefail

# stats_metrics_file — path of the agent-runs JSONL file.
stats_metrics_file() {
  printf '%s/metrics/agent-runs.jsonl\n' "${DISINTO_LOG_DIR:-/tmp}"
}

# stats_epoch_to_iso <epoch> — epoch seconds → UTC ISO 8601 (second precision).
#
# Pure awk: busybox date (CI runs on alpine) cannot parse @epoch or relative
# offsets, but `date -u +%s` is portable, so we compute the cutoff epoch with
# date and convert here. Hinnant's civil-from-days algorithm.
stats_epoch_to_iso() {
  awk -v e="$1" 'BEGIN {
    d = int(e / 86400)
    rem = e - d * 86400
    # civil_from_days (Hinnant)
    z = d + 719468
    era = int((z >= 0 ? z : z - 146096) / 146097)
    doe = z - era * 146097
    yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
    y = yoe + era * 400
    doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
    mp = int((5 * doy + 2) / 153)
    dd = doy - int((153 * mp + 2) / 5) + 1
    mm = mp + (mp < 10 ? 3 : -9)
    if (mm <= 2) y = y + 1
    printf "%04d-%02d-%02dT%02d:%02d:%02dZ\n", y, mm, dd, int(rem / 3600), int(rem % 3600 / 60), rem % 60
  }'
}

# _stats_fmt_duration <ms> — null → "-", else 45s / 12m / 1h05m / 1d02h.
_stats_fmt_duration() {
  local v="$1"
  if [ -z "$v" ] || [ "$v" = "null" ]; then
    printf -- '-'
    return 0
  fi
  awk -v ms="$v" 'BEGIN {
    s = int(ms / 1000)
    d = int(s / 86400); s -= d * 86400
    h = int(s / 3600);  s -= h * 3600
    m = int(s / 60);    s -= m * 60
    if (d > 0)      printf "%dd%02dh", d, h
    else if (h > 0) printf "%dh%02dm", h, m
    else if (m > 0) printf "%dm", m
    else            printf "%ds", s
  }'
}

# _stats_fmt_tokens <n> — null → "-", else 1.2M / 350K / 900.
_stats_fmt_tokens() {
  local v="$1"
  if [ -z "$v" ] || [ "$v" = "null" ]; then
    printf -- '-'
    return 0
  fi
  awk -v n="$v" 'BEGIN {
    if (n >= 1e6)      printf "%.1fM", n / 1e6
    else if (n >= 1e3) printf "%.0fK", n / 1e3
    else               printf "%.0f", n
  }'
}

# stats_main — parse options and render the summary (table or JSON).
#
#   --since <N>d|<N>h   window, default 7d
#   --role <role>       filter to one role
#   --task <ref>        print every record attributed to the task, one per line
#   --json              machine-readable single JSON object instead of a table
#   -h, --help          usage
stats_main() {
  local since="7" since_unit="d" role="" task="" json=0
  local cutoff cutoff_secs file

  while [ $# -gt 0 ]; do
    case "$1" in
      --since)
        [ $# -ge 2 ] || { echo "stats: --since needs a value" >&2; return 1; }
        since="$2"; shift 2
        ;;
      --role)
        [ $# -ge 2 ] || { echo "stats: --role needs a value" >&2; return 1; }
        role="$2"; shift 2
        ;;
      --task)
        [ $# -ge 2 ] || { echo "stats: --task needs a value" >&2; return 1; }
        task="$2"; shift 2
        ;;
      --json)
        json=1; shift
        ;;
      -h|--help)
        echo "usage: disinto stats [--since <N>d|<N>h] [--role <role>] [--task <ref>] [--json]"
        return 0
        ;;
      *)
        echo "stats: unknown option: $1" >&2
        return 1
        ;;
    esac
  done

  case "$since" in
    '' | *[!0-9]*[dh]*)
      echo "stats: --since must be <N>d or <N>h (got '${since}')" >&2
      return 1
      ;;
    *)
      # strip trailing unit
      case "$since" in
        *d) since_unit="d" ;;
        *h) since_unit="h" ;;
      esac
      since="${since%[dh]}"
      ;;
  esac
  case "$since" in
    '' | *[!0-9]*)
      echo "stats: --since must be <N>d or <N>h (got '${since}')" >&2
      return 1
      ;;
  esac

  file="$(stats_metrics_file)"
  if [ ! -s "$file" ]; then
    echo "no agent runs recorded yet"
    return 0
  fi

  # --task: print every record attributed to the ref, one per line.
  if [ -n "$task" ]; then
    local ref="${task#[#!]}"
    local out
    out=$(jq -R -c --arg ref "$ref" \
      'fromjson? | select(type == "object" and .task_ref == $ref)' \
      < "$file" 2>/dev/null) || out=""
    local n
    n=$(printf '%s' "$out" | grep -c '' || true)
    if [ "$n" -eq 0 ]; then
      echo "no runs recorded for task ${task}"
      return 0
    fi
    printf '%s\n' "$out"
    return 0
  fi

  # Count all lines (grep -c '' counts a torn final line lacking a newline)
  # and all parseable records; the difference is the malformed count.
  local total_lines valid_lines skipped
  total_lines=$(grep -c '' "$file" || true)
  valid_lines=$(jq -R -c 'fromjson? | select(type == "object")' < "$file" | grep -c '' || true)
  skipped=$(( total_lines - valid_lines ))
  [ "$skipped" -ge 0 ] || skipped=0

  # Cutoff: now - window, as ISO string for string comparison against ts.
  case "$since_unit" in
    d) cutoff_secs=$(( since * 86400 )) ;;
    h) cutoff_secs=$(( since * 3600 )) ;;
  esac
  cutoff="$(stats_epoch_to_iso $(( $(date -u +%s) - cutoff_secs )))"

  local agg
  agg=$(jq -R -s -c \
    --arg cutoff "$cutoff" \
    --arg role "$role" \
    '
    def median: sort | length as $n
      | if $n == 0 then null
        elif ($n % 2) == 1 then .[($n - 1) / 2]
        else (.[$n / 2 - 1] + .[$n / 2]) / 2
        end;
    def p90: sort | length as $n
      | if $n == 0 then null else .[(($n * 9 / 10) | ceil) - 1] end;
    def mean: if length == 0 then null else (add / length) end;
    def sumnull: (map(select(. != null)) | if length == 0 then 0 else add end);
    def agg:
      { runs: length,
        ok: (map(select(.outcome == "success")) | length),
        # .delivered is null on pre-#1167 records; null != true keeps those
        # runs in the outcome columns (never guessed retrospectively).
        timeout: (map(select(.outcome == "timeout" and .delivered != true)) | length),
        maxturns: (map(select(.outcome == "error_max_turns" and .delivered != true)) | length),
        other: (map(select(.outcome != "success" and .outcome != "timeout"
                           and .outcome != "error_max_turns"
                           and .delivered != true)) | length),
        # Non-success runs that pushed work — delivered despite the exit.
        partial: (map(select(.outcome != "success" and .delivered == true)) | length),
        excluded_no_duration: (map(select(.duration_ms == null)) | length),
        median_ms: (map(select(.duration_ms != null) | .duration_ms) | median),
        p90_ms: (map(select(.duration_ms != null) | .duration_ms) | p90),
        input_tokens: (map(.input_tokens) | sumnull),
        output_tokens: (map(.output_tokens) | sumnull),
        cost_usd: (map(.cost_usd) | sumnull),
        tps: (map(select(.output_tps != null) | .output_tps) | mean),
        compactions_per_run: (if length == 0 then null
            else (map(.compactions // 0) | add) / length end) };
    [ split("\n")[]
      | (try fromjson catch null)
      | select(type == "object")
      | select((.ts // "") >= $cutoff)
      | select($role == "" or .role == $role) ]
    | { records: length,
        roles: (group_by(.role // "unknown")
                | map({ role: (.[0].role // "unknown") } + agg)
                | sort_by([-.runs, .role])),
        totals: agg }
    ' < "$file") || {
    echo "stats: failed to parse ${file}" >&2
    return 1
  }

  if [ "$json" -eq 1 ]; then
    printf '%s\n' "$agg" | jq \
      --arg since "${since}${since_unit}" \
      --arg role "$role" \
      --argjson skipped "$skipped" \
      '{ window: $since,
         role: (if $role == "" then null else $role end),
         records: .records,
         skipped: $skipped,
         excluded_no_duration: .totals.excluded_no_duration,
         roles: .roles,
         totals: .totals }'
    return 0
  fi

  local title="Agent runs — last ${since}${since_unit}"
  if [ -n "$role" ]; then
    title="${title}, role ${role}"
  fi
  echo "${title} ($(jq -r '.records' <<<"$agg") sessions)"

  # other/partial appear only when non-zero, like before #1167: data without
  # a delivered field renders exactly as it did before.
  local tot_other tot_partial show_other=0 show_partial=0
  tot_other="$(jq -r '.totals.other' <<<"$agg")"
  tot_partial="$(jq -r '.totals.partial' <<<"$agg")"
  [ "$tot_other" != "0" ] && show_other=1
  [ "$tot_partial" != "0" ] && show_partial=1

  local fmt header
  fmt='%-10s %6s %5s %7s %8s'
  header=(role runs ok timeout maxturns)
  if [ "$show_other" -eq 1 ]; then fmt+=' %5s'; header+=(other); fi
  if [ "$show_partial" -eq 1 ]; then fmt+=' %8s'; header+=(partial); fi
  fmt+=' %8s %8s %15s %8s %6s %15s\n'
  header+=(median p90 'tokens in/out' '$' tps 'compactions/run')
  printf "$fmt" "${header[@]}"

  local r runs ok timeout_ maxturns other partial med p90 tin tout cost tps comp
  local medf p90f iof cf tf cpf row
  while IFS=$'\t' read -r r runs ok timeout_ maxturns other partial \
      med p90 tin tout cost tps comp; do
    medf="$(_stats_fmt_duration "$med")"
    p90f="$(_stats_fmt_duration "$p90")"
    iof="$(_stats_fmt_tokens "$tin") / $(_stats_fmt_tokens "$tout")"
    cf="$(awk -v c="$cost" 'BEGIN { printf "%.2f", c }')"
    tf="$(awk -v t="$tps" 'BEGIN { printf "%.1f", t }')"
    cpf="$(awk -v c="$comp" 'BEGIN { printf "%.1f", c }')"
    row=("$r" "$runs" "$ok" "$timeout_" "$maxturns")
    if [ "$show_other" -eq 1 ]; then row+=("$other"); fi
    if [ "$show_partial" -eq 1 ]; then row+=("$partial"); fi
    row+=("$medf" "$p90f" "$iof" "$cf" "$tf" "$cpf")
    printf "$fmt" "${row[@]}"
  done < <(jq -r '.roles[] |
      [.role, .runs, .ok, .timeout, .maxturns, .other, .partial,
       .median_ms, .p90_ms, .input_tokens, .output_tokens,
       .cost_usd, .tps, .compactions_per_run] | @tsv' <<<"$agg")

  # Totals row: no median/p90/tps (they are not meaningful across roles).
  local t_runs t_ok t_timeout t_maxturns t_other t_partial t_excl t_tin t_tout t_cost t_comp
  IFS=$'\t' read -r t_runs t_ok t_timeout t_maxturns t_other t_partial \
      t_excl t_tin t_tout t_cost t_comp \
    < <(jq -r '.totals |
      [.runs, .ok, .timeout, .maxturns, .other, .partial, .excluded_no_duration,
       .input_tokens, .output_tokens, .cost_usd, .compactions_per_run] | @tsv' \
      <<<"$agg")
  local t_iot t_costf t_compf
  t_iot="$(_stats_fmt_tokens "$t_tin") / $(_stats_fmt_tokens "$t_tout")"
  t_costf="$(awk -v c="$t_cost" 'BEGIN { printf "%.2f", c }')"
  t_compf="$(awk -v c="$t_comp" 'BEGIN { printf "%.1f", c }')"
  row=(totals "$t_runs" "$t_ok" "$t_timeout" "$t_maxturns")
  if [ "$show_other" -eq 1 ]; then row+=("$t_other"); fi
  if [ "$show_partial" -eq 1 ]; then row+=("$t_partial"); fi
  row+=("" "" "$t_iot" "$t_costf" "" "$t_compf")
  printf "$fmt" "${row[@]}"

  if [ "$t_partial" -gt 0 ]; then
    echo "* ${t_partial} run(s) exited non-success but had work pushed (delivered: true) — in partial, not in the outcome columns"
  fi
  if [ "$t_excl" -gt 0 ]; then
    echo "* ${t_excl} session(s) with no duration (killed mid-run) excluded from duration and tps stats"
  fi
  if [ "$skipped" -gt 0 ]; then
    echo "skipped ${skipped} malformed line(s) in $(stats_metrics_file)"
  fi
  return 0
}
