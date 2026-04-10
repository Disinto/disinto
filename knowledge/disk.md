# Disk Management — Best Practices

## Disk Pressure Response (P1)

When disk usage exceeds 80%, take these actions in order:

### Immediate Actions
1. **Docker cleanup** (safe, low impact):
   ```bash
   sudo docker system prune -f
   ```

2. **Aggressive Docker cleanup** (if still >80%):
   ```bash
   sudo docker system prune -a -f
   ```
   This removes unused images in addition to containers/volumes.

3. **Log rotation**:
   ```bash
   for f in "$FACTORY_ROOT"/{dev,review,supervisor,gardener,planner,predictor}/*.log; do
     [ -f "$f" ] && [ "$(du -k "$f" | cut -f1)" -gt 10240 ] && truncate -s 0 "$f"
   done
   ```

### Prevention
- Monitor disk with alerts at 70% (warning) and 80% (critical)
- Set up automatic log rotation for agent logs
- Clean up old Docker images regularly
- Consider using separate partitions for `/var/lib/docker`

### When to Escalate
- Disk stays >80% after cleanup (indicates legitimate growth)
- No unused Docker images to clean
- Critical data filling disk (check /home, /var/log)
