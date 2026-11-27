#!/bin/bash
# ApplicationStart: replace the running container with one from the new image.
# ApplicationStop is not used, so this script removes the old container itself.
set -euo pipefail

source /opt/internal-agent/deploy/image.env

docker rm -f internal-agent || true                  # no old container on the first deploy
docker run -d \
  --name internal-agent \
  --restart unless-stopped \
  -p 80:8000 \
  "$IMAGE"
# Host port 80 is already open in the security group; uvicorn listens on 8000 inside.
