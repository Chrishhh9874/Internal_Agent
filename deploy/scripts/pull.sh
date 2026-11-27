#!/bin/bash
# AfterInstall: log in to ECR with the instance role and pull the image named in image.env.
set -euo pipefail

source /opt/internal-agent/deploy/image.env          # sets IMAGE=<registry>/<repo>:<sha>
REGISTRY=$(echo "$IMAGE" | cut -d/ -f1)              # registry host, the part before the first "/"

aws ecr get-login-password --region us-east-2 \
  | docker login --username AWS --password-stdin "$REGISTRY"
docker pull "$IMAGE"
