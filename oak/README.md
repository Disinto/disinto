# oak — tabular SARSA tick-learner

One-tick driver (`oak/tick.sh`) plus its three pieces:

| Program | Contract |
|---|---|
| `oak/sense.sh PACK.toml` | Read a feature pack → state `x` + reused key (`{"x":{...},"key":"2\|0"}`) |
| `oak/pick.sh WEIGHTS.json LEGAL.json` | ε-greedy over the legal actions → one action name |
| `oak/td.sh WEIGHTS.json UPDATE.json` | Tabular SARSA update (atomic), → new Q value |
| `oak/tick.sh PROJECT.toml` | **The driver:** sense → critic (r) → pick a2 → SARSA td → log transition → start at most one organ |

The tick picks **first**, then applies the SARSA update with the action it
actually picked (`a2`) — that is what makes it SARSA, not Q-learning.

## Where the state lives

All oak state lives in the **ops repo** under `$OPS_REPO_ROOT/oak/`:

| File | Meaning |
|---|---|
| `weights.json` | The weights table `{"q0":..., "gvf":{"purpose":{"Q":{key:{action:q}}}, "inbound":{"V":{key:v}}}}`. Missing `Q[key][action]` reads as `q0`. Created on the first `td` (first tick is a boot: it only writes `last.json`). |
| `transitions.jsonl` | One line per learned transition: `{"t", "x", "a", "r", "x2"}` — appended when a previous tick (`last.json`) exists. |
| `last.json` | The previous tick `{"x_key","a","x"}` (raw `x` stored, so the transition needs no re-sense). |

The pack defaults to the factory's `oak/pack.example.toml`; put your own
`pack.toml` in the ops repo root to override. The toml argument to
`tick.sh` is passed through to any organ the tick starts.

## Printing Q

Q is plain JSON in the ops repo:

```sh
# Whole purpose table
jq '.gvf.purpose.Q' "$OPS_REPO_ROOT/oak/weights.json"

# One state key, all actions
jq '.gvf.purpose.Q["2|0"]' "$OPS_REPO_ROOT/oak/weights.json"

# The q the agent currently reads for a state+action (missing → q0)
jq '.gvf.purpose.Q["2|0"]["dev-poll"] // .q0' "$OPS_REPO_ROOT/oak/weights.json"
```

State keys are `sense.sh` keys: feature bins/0-1 bits joined with `|`,
features sorted by name (e.g. `disk_free_gb=1, vault_in_flight=0` → `"1|0"`).

## Dry run

`OAK_DRY_RUN=1` runs the whole tick — sense, critic, pick, td, transition
append — and prints the chosen action, but never execs an organ:

```sh
OAK_DRY_RUN=1 bash oak/tick.sh projects/<name>.toml   # → prints e.g. idle
```

## What a tick does (and does not do)

- **Legal actions:** `idle` is always legal. Each organ action in the pack is
  legal unless its script is already running (`pgrep -f` on the script base
  name) — one instance per organ. Note that `pgrep -f` scans the *full*
  command line, so a test/CI wrapper whose argv merely quotes the script
  name also drops that organ for that tick; keep organ script names
  distinctive. `dispatch` is legal only in an `automatic`-mode vault while
  `x.vault_in_flight < max_in_flight` — a missing `[vault]` (no mode) or a
  missing `max_in_flight` (zero capacity) drops it, so `dispatch` is never
  legal-but-never-startable (the tick never execs it anyway, see below).
  When `AGENT_ROLES` is set, each organ must map to a role in it
  (`dispatch` needs no role — the vault gate governs it).
- **Reward (critic):** pack `[critic]` builtin `present` → `r=1` iff
  `x[feature]` is non-zero, else 0. No `[critic]` → `r=0`.
- **Start:** the picked organ runs as `bash <script> <project-toml>`
  in the background, logged to `$DISINTO_LOG_DIR/<action>.log` (same
  pattern as the entrypoint loop, which #1333 wires up). `dispatch` is
  never exec'd by the tick — external actions go through vault dispatch
  (AD-006). No git commits from a tick; the tick never waits for its organ.
