# Memory Management — Best Practices

## Memory Crisis Response (P0)

When RAM available drops below 500MB or swap usage exceeds 3GB, take these actions:

### Immediate Actions
1. **Kill stale claude processes** (>3 hours old):
   ```bash
   pgrep -f "claude -p" --older 10800 2>/dev/null | xargs kill 2>/dev/null || true
   ```

2. **Drop filesystem caches**:
   ```bash
   sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
   ```

### Prevention
- Set memory_guard to 2000MB minimum (default in env.sh)
- Configure swap usage alerts at 2GB
- Monitor for memory leaks in long-running processes
- Use cgroups for process memory limits

### When to Escalate
- RAM stays <500MB after cache drop
- Swap continues growing after process kills
- System becomes unresponsive (OOM killer active)
