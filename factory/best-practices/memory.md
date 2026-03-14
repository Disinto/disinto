# Memory Best Practices

## Environment
- VPS: 8GB RAM, 4GB swap, Debian
- Running: Docker stack (8 containers), Woodpecker CI, OpenClaw gateway

## Safe Fixes (no permission needed)
- Kill stale `claude` processes (>3h old): `pgrep -f "claude" --older 10800 | xargs kill`
- Drop filesystem caches: `sync && echo 3 | sudo tee /proc/sys/vm/drop_caches`
- Restart bloated Anvil: `sudo docker restart ${PROJECT_NAME}-anvil-1` (grows to 12GB+ over hours)
- Kill orphan node processes from dead worktrees

## Dangerous (escalate)
- `docker system prune -a --volumes` — kills CI images, hours to rebuild
- Stopping project stack containers — breaks dev environment
- OOM that survives all safe fixes — needs human decision on what to kill

## Known Memory Hogs
- `claude` processes from dev-agent: 200MB+ each, can zombie
- `dockerd`: 600MB+ baseline (normal)
- `openclaw-gateway`: 500MB+ (normal)
- Anvil container: starts small, grows unbounded over hours
- `forge build` with via_ir: can spike to 4GB+. Use `--skip test script` to reduce.
- Vite dev servers inside containers: 150MB+ each

## Lessons Learned
- After killing processes, always `sync && echo 3 | sudo tee /proc/sys/vm/drop_caches`
- Swap doesn't drain from dropping caches alone — it's actual paged-out process memory
- Running CI + full project stack = 14+ containers on 8GB. Only one pipeline at a time.
