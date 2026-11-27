#!/bin/bash
# ValidateService: the deployment succeeds only if the health check passes.
set -euo pipefail

# Host port 80 maps to container port 8000 (see start.sh).
# -f makes curl fail on 4xx/5xx; without it a 500 would count as healthy.
for i in $(seq 1 10); do
  if curl -fsS http://localhost/api/health > /dev/null; then
    echo "healthy"
    exit 0
  fi
  echo "not ready yet ($i/10)"
  sleep 3
done

echo "health check failed"
docker logs --tail 50 internal-agent
exit 1
