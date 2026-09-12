#!/usr/bin/env bats
# tests/lib-run-ledger.bats — append-only run ledger writer (#1297)
#
# run_ledger_append <ops_root> <record.json>: writes runs/<id>.json,
# validates the required record keys, refuses duplicate ids, allows extra
# keys, and refuses unsafe ids.

load '../lib/run-ledger.sh'

setup() {
  OPS="${BATS_TEST_TMPDIR}/ops"
  RECDIR="${BATS_TEST_TMPDIR}/records"
  mkdir -p "$OPS" "$RECDIR"
}

teardown() {
  cd /
  rm -rf "$OPS" "$RECDIR"
}

# valid_record <id> — write a record with every required key into RECDIR
valid_record() {
  local id="$1"
  cat > "$RECDIR/${id}.json" <<EOF
{
  "id": "${id}",
  "action_id": "run-experiment-1",
  "git_tree": "abc123def",
  "image": "disinto/agents:latest",
  "host": "nomad-box-1",
  "argv": ["run-experiment.sh", "--formula", "release"],
  "started": "2026-02-11T00:00:00Z",
  "ended": "2026-02-11T00:10:00Z",
  "exit": 0,
  "artifacts": ["run-experiment-1/results.csv"]
}
EOF
}

@test "appends a valid row to runs/<id>.json" {
  valid_record run-1
  run_ledger_append "$OPS" "$RECDIR/run-1.json"
  [ -f "$OPS/runs/run-1.json" ]
  jq -e '.id == "run-1" and .action_id == "run-experiment-1"
      and .git_tree == "abc123def" and .image == "disinto/agents:latest"
      and .host == "nomad-box-1" and (.argv | length == 3)
      and (.artifacts == ["run-experiment-1/results.csv"])
      and .exit == 0' "$OPS/runs/run-1.json" >/dev/null
  # The record content is preserved verbatim
  diff "$OPS/runs/run-1.json" "$RECDIR/run-1.json"
}

@test "a second append with the same id fails and leaves the row untouched" {
  valid_record run-1
  run_ledger_append "$OPS" "$RECDIR/run-1.json"
  local before
  before="$(sha256sum "$OPS/runs/run-1.json" | cut -d' ' -f1)"
  if run_ledger_append "$OPS" "$RECDIR/run-1.json"; then
    echo "duplicate id was accepted — ledger must be append-only"
    return 1
  fi
  [ "$(sha256sum "$OPS/runs/run-1.json" | cut -d' ' -f1)" = "$before" ]
}

@test "different ids coexist" {
  valid_record run-1
  valid_record run-2
  run_ledger_append "$OPS" "$RECDIR/run-1.json"
  run_ledger_append "$OPS" "$RECDIR/run-2.json"
  [ -f "$OPS/runs/run-1.json" ]
  [ -f "$OPS/runs/run-2.json" ]
}

@test "missing required keys fail" {
  local key
  for key in id action_id git_tree image host argv started ended exit artifacts; do
    valid_record run-miss
    jq --arg k "$key" 'del(.[$k])' "$RECDIR/run-miss.json" > "$RECDIR/run-miss-${key}.json"
    if run_ledger_append "$OPS" "$RECDIR/run-miss-${key}.json"; then
      echo "record without '${key}' was accepted"
      return 1
    fi
  done
  [ ! -e "$OPS/runs" ]
}

@test "extra keys are allowed" {
  valid_record run-x
  jq '. + {"notes": "pilot run", "resource_class": "gpu"}' \
    "$RECDIR/run-x.json" > "$RECDIR/run-x-extra.json"
  run_ledger_append "$OPS" "$RECDIR/run-x-extra.json"
  jq -e '.notes == "pilot run" and .resource_class == "gpu"' \
    "$OPS/runs/run-x.json" >/dev/null
}

@test "argv and artifacts must be arrays of strings; exit a number" {
  valid_record run-bad
  jq '.argv = "not-an-array"' "$RECDIR/run-bad.json" > "$RECDIR/bad-argv.json"
  if run_ledger_append "$OPS" "$RECDIR/bad-argv.json"; then
    echo "string argv was accepted"
    return 1
  fi
  jq '.artifacts = "results.csv"' "$RECDIR/run-bad.json" > "$RECDIR/bad-artifacts.json"
  if run_ledger_append "$OPS" "$RECDIR/bad-artifacts.json"; then
    echo "string artifacts was accepted (must be a list of relative paths)"
    return 1
  fi
  jq '.exit = "0"' "$RECDIR/run-bad.json" > "$RECDIR/bad-exit.json"
  if run_ledger_append "$OPS" "$RECDIR/bad-exit.json"; then
    echo "string exit was accepted"
    return 1
  fi
}

@test "unsafe ids (path separators, leading dot) are refused" {
  valid_record run-1
  jq '.id = "../evil"' "$RECDIR/run-1.json" > "$RECDIR/evil.json"
  if run_ledger_append "$OPS" "$RECDIR/evil.json"; then
    echo "id with a path separator was accepted"
    return 1
  fi
  jq '.id = ".hidden"' "$RECDIR/run-1.json" > "$RECDIR/hidden.json"
  if run_ledger_append "$OPS" "$RECDIR/hidden.json"; then
    echo "dot-leading id was accepted"
    return 1
  fi
  [ ! -e "$OPS/runs" ]
}

@test "non-string id (null, number) is refused" {
  valid_record run-ns
  jq '.id = null' "$RECDIR/run-ns.json" > "$RECDIR/null-id.json"
  if run_ledger_append "$OPS" "$RECDIR/null-id.json"; then
    echo "null id was accepted (jq -r would stringify it to 'null')"
    return 1
  fi
  jq '.id = 5' "$RECDIR/run-ns.json" > "$RECDIR/num-id.json"
  if run_ledger_append "$OPS" "$RECDIR/num-id.json"; then
    echo "numeric id was accepted"
    return 1
  fi
  [ ! -e "$OPS/runs" ]
}

@test "non-object JSON fails" {
  echo '[1,2,3]' > "$RECDIR/array.json"
  if run_ledger_append "$OPS" "$RECDIR/array.json"; then
    echo "a JSON array was accepted as a record"
    return 1
  fi
}

@test "missing record file is a usage error (rc 2)" {
  local rc=0
  run_ledger_append "$OPS" "$RECDIR/does-not-exist.json" || rc=$?
  [ "$rc" -eq 2 ]
}
