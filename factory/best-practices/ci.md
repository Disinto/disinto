# CI Best Practices

## Environment
- Woodpecker CI at localhost:8000 (Docker backend)
- Postgres DB: use `wpdb` helper from env.sh
- Woodpecker API: use `woodpecker_api` helper from env.sh
- Example (harb): CI images pre-built at `registry.niovi.voyage/harb/*:latest`

## Safe Fixes
- Retrigger CI: push empty commit to PR branch
  ```bash
  cd /tmp/${PROJECT_NAME}-worktree-<issue> && git commit --allow-empty -m "ci: retrigger" --no-verify && git push origin <branch> --force
  ```
- Restart woodpecker-agent: `sudo systemctl restart woodpecker-agent`
- View pipeline status: `wpdb -c "SELECT number, status FROM pipelines WHERE repo_id=$WOODPECKER_REPO_ID ORDER BY number DESC LIMIT 5;"`
- View failed steps: `bash ${FACTORY_ROOT}/lib/ci-debug.sh failures <pipeline-number>`
- View step logs: `bash ${FACTORY_ROOT}/lib/ci-debug.sh logs <pipeline-number> <step-name>`

## Dangerous (escalate)
- Restarting woodpecker-server (drops all running pipelines)
- Modifying pipeline configs in `.woodpecker/` directory

## Known Issues
- Codeberg rate-limits SSH clones. `git` step fails with exit 128. Retrigger usually works.
- `log_entries` table grows fast (was 5.6GB once). Truncate periodically.
- Example (harb): Running CI + harb stack = 14+ containers on 8GB. Memory pressure is real.
- CI images take hours to rebuild. Never run `docker system prune -a`.

## Lessons Learned
- Exit code 128 on git step = Codeberg rate limit, not a code problem. Retrigger.
- Exit code 137 = OOM kill. Check memory, kill stale processes, retrigger.
- `node-quality` step fails on eslint/typescript errors — these need code fixes, not CI fixes.

### Example (harb): FEE_DEST address must match DeployLocal.sol
When DeployLocal.sol changes the feeDest address, bootstrap-common.sh must also be updated.
Current feeDest = keccak256('harb.local.feeDest') = 0x8A9145E1Ea4C4d7FB08cF1011c8ac1F0e10F9383.
Symptom: bootstrap step exits 1 after 'Granting recenter access to deployer' with no error — setRecenterAccess reverts because wrong address is impersonated.

### Example (harb): keccak-derived FEE_DEST requires anvil_setBalance before impersonation
When FEE_DEST is a keccak-derived address (e.g. keccak256('harb.local.feeDest')), it has zero ETH balance. Any function that calls `anvil_impersonateAccount` then `cast send --from $FEE_DEST --unlocked` will fail silently (output redirected to LOG_FILE) but exit 1 due to gas deduction failure. Fix: add `cast rpc anvil_setBalance "$FEE_DEST" "0xDE0B6B3A7640000"` before impersonation. Applied in both bootstrap-common.sh and red-team.sh.
