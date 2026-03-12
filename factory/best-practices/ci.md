# CI Best Practices

## Environment
- Woodpecker CI at localhost:8000 (Docker backend)
- Postgres DB: use `wpdb` helper from env.sh
- Woodpecker API: use `woodpecker_api` helper from env.sh
- CI images: pre-built at `registry.niovi.voyage/harb/*:latest`

## Safe Fixes
- Retrigger CI: push empty commit to PR branch
  ```bash
  cd /tmp/harb-worktree-<issue> && git commit --allow-empty -m "ci: retrigger" --no-verify && git push origin <branch> --force
  ```
- Restart woodpecker-agent: `sudo systemctl restart woodpecker-agent`
- View pipeline status: `wpdb -c "SELECT number, status FROM pipelines WHERE repo_id=2 ORDER BY number DESC LIMIT 5;"`
- View failed steps: `bash ${FACTORY_ROOT}/lib/ci-debug.sh failures <pipeline-number>`
- View step logs: `bash ${FACTORY_ROOT}/lib/ci-debug.sh logs <pipeline-number> <step-name>`

## Dangerous (escalate)
- Restarting woodpecker-server (drops all running pipelines)
- Modifying pipeline configs in `.woodpecker/` directory

## Known Issues
- Codeberg rate-limits SSH clones. `git` step fails with exit 128. Retrigger usually works.
- `log_entries` table grows fast (was 5.6GB once). Truncate periodically.
- Running CI + harb stack = 14+ containers on 8GB. Memory pressure is real.
- CI images take hours to rebuild. Never run `docker system prune -a`.

## Lessons Learned
- Exit code 128 on git step = Codeberg rate limit, not a code problem. Retrigger.
- Exit code 137 = OOM kill. Check memory, kill stale processes, retrigger.
- `node-quality` step fails on eslint/typescript errors — these need code fixes, not CI fixes.
