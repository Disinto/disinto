#!/usr/bin/env bash
# dsh-session.sh — reader that normalises a dsh session log (#1105)
#
# dsh headless writes only the last assistant text to stdout; the full record
# lands on disk as zstd-compressed JSONL:
#
#   $DSH_HOME/sessions/<cwd-slug>/<session-uuid>/session.jsonl.zstd
#
# dsh_session_normalise() decompresses that file and re-emits it in the shape
# the rest of disinto already consumes from Claude Code stream-json, so the
# result-marker / no-push logic in lib/agent-sdk.sh and the metrics collector
# (metrics_record_run in lib/agent-metrics.sh) work for both harnesses
# without changes:
#
#   one    {"type":"system","subtype":"init",...} line
#   one    {"type":"system","subtype":"compact_boundary",...} line per compaction
#   one    terminal {"type":"result","subtype":...} line
#
# The dsh 0.1.1-rc.2 on-disk format (measured — this file is the only place
# that knows it; if dsh's event taxonomy shifts, update only this file):
#
#   Every record is {"type":..., "seq":N, "time":...}; the high-volume chunk
#   types (reasoning-chunks, text-chunks, tool-call-chunks, assistant/chunk)
#   use seq0/time0 instead of seq/time. One real session carried 57k
#   reasoning chunks against 137 steps, so the chunk types are streamed and
#   discarded before aggregation — never accumulated in memory.
#
#   type                used here for
#   session             first record; data.cwd
#   request/context     data.model and data.contextWindow
#   request/header      fallback model: data.header.config.model
#   step/start          one model call == one Claude Code "turn", so
#                       num_turns = count of step/start. Do NOT use
#                       turn/start — a dsh turn is a whole user-message-to-
#                       quiescence cycle (one real session had 107 steps
#                       inside a single turn)
#   assistant/message   data.usage.{inputTokens,outputTokens,cacheReadTokens}
#                       — summed into the result usage
#   compaction/end      one compact_boundary line per
#   compaction/summary  data.shadowedTokenCount → compact_metadata.pre_tokens,
#                       matched to the end event by compactionId
#   turn/end            data.reason.kind == "completed" → subtype "success"
#                       (an aborted turn nests a further reason, e.g.
#                       {"kind":"aborted","reason":{"kind":"user"}});
#                       anything without a completed turn/end → "no_result"
#
# "time" values are accepted as ISO 8601 strings or epoch numbers (seconds or
# milliseconds, disambiguated by magnitude). duration_ms = last time minus
# first. No record in the format carries a cost figure, so none is invented.
#
# Sourced; no side effects. Requires zstdcat (zstd) in PATH.
# Tests: tests/lib-dsh-session.bats

set -euo pipefail

# dsh_session_normalise <session_dir> — print the normalised JSONL to stdout.
#
#   $1  session_dir — the session directory holding session.jsonl.zstd
#
# Exit 0 on success. Exit 1 with a message on stderr (and nothing on stdout)
# when the log is missing, truncated, corrupt, or holds no usable records —
# a partial parse is never emitted. Exit 2 on a usage error.
dsh_session_normalise() {
  local session_dir="${1:-}"
  if [ -z "$session_dir" ]; then
    echo "dsh-session: usage: dsh_session_normalise <session_dir>" >&2
    return 2
  fi

  local log_file="$session_dir/session.jsonl.zstd"
  if [ ! -d "$session_dir" ]; then
    echo "dsh-session: not a session directory: $session_dir" >&2
    return 1
  fi
  if [ ! -r "$log_file" ]; then
    echo "dsh-session: session log missing or unreadable: $log_file" >&2
    return 1
  fi
  if ! command -v zstdcat >/dev/null 2>&1; then
    echo "dsh-session: zstdcat (zstd) not found in PATH" >&2
    return 1
  fi

  local session_id
  session_id=$(basename "$session_dir")

  # Stage 1 streams the decompressed log and drops the chunk record types, so
  # stage 2 only ever sees the transcript records (a few hundred at most),
  # no matter how many chunks the session produced.
  local out
  if ! out=$( { zstdcat "$log_file" \
        | jq -c '
            . as $r
            | if type != "object" then error("session log record is not a JSON object")
              else
                ($r.type // null) as $t
                | if $t == "reasoning-chunks" or $t == "text-chunks"
                       or $t == "tool-call-chunks" or $t == "assistant/chunk"
                  then empty
                  else $r
                  end
              end
          ' \
        | jq -c -s --arg sid "$session_id" '
            # ISO 8601 string or epoch seconds/milliseconds → epoch ms.
            # Hinnant days-from-civil (same algorithm as stats_epoch_to_iso).
            def ts_ms:
              if type == "number" then
                (if . >= 100000000000 then . else (. * 1000 | floor) end)
              elif type == "string" then
                # Bind the captured fields to variables first; the last
                # line is a flat sum over them.
                capture("^(?<y>[0-9]{4})-(?<m>[0-9]{2})-(?<d>[0-9]{2})[Tt ](?<H>[0-9]{2}):(?<M>[0-9]{2}):(?<S>[0-9]{2})(?:\\.(?<f>[0-9]+))?(?<o>Z|[+-][0-9]{2}:?[0-9]{2})?$")
                 | (.y | tonumber) as $yy0
                 | (.m | tonumber) as $mm0
                 | (.d | tonumber) as $dy
                 | (.H | tonumber) as $hh
                 | (.M | tonumber) as $mi
                 | (.S | tonumber) as $ss
                 | ($yy0 - (if $mm0 <= 2 then 1 else 0 end)) as $yy
                 | ($mm0 + (if $mm0 > 2 then -3 else 9 end)) as $mm
                 | (($yy / 400) | floor) as $era
                 | ($yy - $era * 400) as $yoe
                 | (((153 * $mm + 2) / 5 | floor) + $dy - 1) as $doy
                 | ($era * 146097 + $yoe * 365 + ($yoe / 4 | floor) - ($yoe / 100 | floor) + $doy - 719468) as $days
                 | (if .f == null then 0 else ((.f + "000")[0:3] | tonumber) end) as $frac
                 | (if .o == null or .o == "Z" then 0
                    else ((if (.o[0:1]) == "-" then -1 else 1 end)
                          * ((((.o[1:] | gsub(":"; ""))[0:2] | tonumber) * 60
                              + ((.o[1:] | gsub(":"; ""))[2:4] | tonumber)) * 60000))
                    end) as $off
                 | $days * 86400000 + $hh * 3600000 + $mi * 60000 + $ss * 1000 + $frac - $off
              else null end;
            def reason_kind: (try (.data.reason.kind) catch null);
            if length == 0 then "NO_RECORDS"
            else
              . as $recs
              | ([ $recs[] | (.time // .time0 // null) | select(. != null) | ts_ms | select(. != null) ]) as $ts
              | (if ($ts | length) == 0 then null else (($ts | max) - ($ts | min)) end) as $dur
              | ([ $recs[] | select(.type == "session") ] | first) as $sess
              | ([ $recs[] | select(.type == "request/context") ] | first) as $reqctx
              | ([ $recs[] | select(.type == "request/header") ] | first) as $reqhdr
              | ($reqctx.data.model // $reqctx.data.header.config.model
                 // $reqhdr.data.header.config.model // null) as $model
              | ($reqctx.data.contextWindow // $reqctx.data.context_window // null) as $cwin
              | ([ $recs[] | select(.type == "step/start") ] | length) as $turns
              | ([ $recs[] | select(.type == "assistant/message") | .data.usage | select(. != null) ]) as $us
              | ([ $us[] | .inputTokens // 0 ] | add // 0) as $tin
              | ([ $us[] | .outputTokens // 0 ] | add // 0) as $tout
              | ([ $us[] | .cacheReadTokens // 0 ] | add // 0) as $tcr
              | ([ $recs[] | select(.type == "compaction/summary")
                    | { id: (.data.compactionId // null),
                        st: (.data.shadowedTokenCount // null) } ]) as $sums
              | ([ $recs[] | select(.type == "compaction/end")
                    | (.data.compactionId // null) as $id
                    | if $id == null then null
                      else ([ $sums[] | select(.id == $id) ] | first | .st)
                      end ]) as $pres
              | ([ $recs[] | select(.type == "turn/end" and (reason_kind == "completed")) ] | length > 0) as $ok
              | { type: "system", subtype: "init",
                  session_id: $sid, model: $model,
                  cwd: ($sess.data.cwd // null), context_window: $cwin } as $init
              | [ $pres[] | { type: "system", subtype: "compact_boundary",
                               compact_metadata: { pre_tokens: ., trigger: "auto" } } ] as $bounds
              | { type: "result",
                  subtype: (if $ok then "success" else "no_result" end),
                  session_id: $sid,
                  num_turns: $turns,
                  duration_ms: $dur,
                  usage: { input_tokens: $tin, output_tokens: $tout,
                           cache_read_input_tokens: $tcr },
                  modelUsage: (if $model != null and $cwin != null
                               then { ($model): { contextWindow: $cwin } }
                               else null end) } as $res
              | ([$init] + $bounds + [$res]) | .[]
            end
          ' \
      ; } 2>/dev/null ); then
    echo "dsh-session: truncated or corrupt session log: $log_file" >&2
    return 1
  fi

  case "$out" in
    '"NO_RECORDS"')
      echo "dsh-session: session log contains no usable records: $log_file" >&2
      return 1
      ;;
  esac

  printf '%s\n' "$out"
  return 0
}
