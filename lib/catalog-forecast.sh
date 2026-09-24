#!/usr/bin/env bash
# =============================================================================
# lib/catalog-forecast.sh — p_success from the ops catalog, not a flat prior
#
# §9.2: the proposer (emit_tape_proposal in dev/dev-poll.sh) should write
# p_success from the ops catalog's measured stats for its loop/class instead
# of a flat prior. catalog/calibration.md (the #1453 table, kept fresh by the
# gardener, #1454) holds one markdown row per (loop, class) group with `n`
# (number of sample pairs) and `actual` (share whose last outcome carries the
# loop's competence bit, an integer percent).
#
# Sourced (dev-poll.sh) and called as:
#   catalog_forecast LOOP CLASS
#   e.g. catalog_forecast dev backlog
#
# Contract (always rc 0 — the pick must never fail because of the catalog):
#   - Read ${CATALOG_FILE:-$OPS_REPO_ROOT/catalog/calibration.md} and match the
#     first data row whose loop and class equal the args (exact, trimmed). When
#     that row's `n` is an integer >= CATALOG_FORECAST_MIN_N (default 5) AND
#     its `actual` column is an integer percent, emit
#     {"p_success":<actual/100>,"est_cost":0,"est_dvision":<mean or 0>}
#     (p_success a JSON number in 0-1, the percent divided by 100; est_dvision
#     the row's `mean duration_s` when that cell is a number — `100`, `100.0`,
#     `6968.2` — else 0 — the field-8 `mean duration_s` column, read by index
#     not by position, since the table may have trailing columns) and set
#     CATALOG_FORECAST_METHOD=counts.
#   - Otherwise — missing/unreadable file, no row, `actual` of `-`, or `n` too
#     small — emit the flat prior
#     {"p_success":0.5,"est_cost":0,"est_dvision":0} and
#     CATALOG_FORECAST_METHOD=prior, so the #1453 calibration reader can tell a
#     prior from measured data. Never fail the pick.
#   - Uses `actual`, not `promised` (#1473 note: the table is now true; this
#     only copies it). est_dvision is the catalog's own `mean duration_s` (#1525);
#     est_cost stays 0 (the table has no cost column). The WAL is not consulted.
#     MIN_N=5 so a single merge never becomes doctrine.
#
# Environment:
#   CATALOG_FILE              path to the calibration table (default above)
#   OPS_REPO_ROOT             ops repo clone (default location of the table)
#   CATALOG_FORECAST_MIN_N    minimum `n` to trust a row (default 5)
# =============================================================================
set -euo pipefail

_prior_forecast() {
  printf '%s' '{"p_success":0.5,"est_cost":0,"est_dvision":0}'
}

# catalog_forecast LOOP CLASS
# Emits one JSON forecast line on stdout and sets CATALOG_FORECAST_METHOD to
# "counts" (measured row good enough) or "prior". Always rc 0.
catalog_forecast() {
  local loop="$1" class="$2"
  local min_n="${CATALOG_FORECAST_MIN_N:-5}"
  local catalog n actual mean actual_int p_success est_dvision forecast method row
  catalog="${CATALOG_FILE:-${OPS_REPO_ROOT:-}/catalog/calibration.md}"
  method="prior"
  forecast='{"p_success":0.5,"est_cost":0,"est_dvision":0}'

  [[ "$min_n" =~ ^[0-9]+$ ]] || min_n=5

  if [ -r "$catalog" ]; then
    # First data row matching (loop, class), exact after trimming.
    # calibration.sh layout (8 pipes, 9 fields with -F'|'):
    #   $2=loop $3=class $4=n $5=promised $6=actual $7=error $8=mean
    # The header (NR=1) and separator (NR=2) can't match a real (loop, class)
    # anyway; skip them explicitly. $8 (mean duration_s) is taken by index,
    # not by position — it is not guaranteed to be the last field.
    row="$(awk -F'|' -v loop="$loop" -v cls="$class" '
      NR <= 2 { next }
      {
        for (i = 2; i <= 8; i++) gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", $i)
        if ($2 == loop && $3 == cls) { print $4 "\t" $6 "\t" $8; exit }
      }
    ' "$catalog" 2>/dev/null)" || row=""
    if [ -n "$row" ]; then
      IFS=$'\t' read -r n actual mean <<<"$row"
      if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge "$min_n" ] \
         && [[ "$actual" =~ ^[0-9]+%$ ]]; then
        actual_int="${actual%\%}"
        p_success="$(awk -v a="$actual_int" 'BEGIN { printf "%.3g", a / 100 }')" \
          || p_success=""
        if [[ "$p_success" =~ ^[0-9]+(\.[0-9]+)?$ ]] &&
           [ -n "$p_success" ]; then
          # est_dvision: the row's `mean duration_s` (field 8) when that cell is
          # a number; otherwise it stays 0. est_cost is always 0 (no cost column).
          # Build with printf (both numbers are arguments, not part of the format).
          est_dvision=0
          [[ "$mean" =~ ^[0-9]+(\.[0-9]+)?$ ]] && est_dvision="$mean"
          forecast="$(printf '{"p_success":%s,"est_cost":0,"est_dvision":%s}' \
            "$p_success" "$est_dvision")" || forecast=""
          [ -n "$forecast" ] && method="counts"
        fi
      fi
    fi
  fi

  if [ "$method" = "counts" ]; then
    printf '%s\n' "$forecast"
  else
    printf '%s\n' "$forecast"
  fi
  # The caller reads CATALOG_FORECAST_METHOD after invoking us (it is not
  # consumed inside this file), so the variable is intentionally global.
  # shellcheck disable=SC2034  # consumed by the calling script
  export CATALOG_FORECAST_METHOD="$method"
  return 0
}
