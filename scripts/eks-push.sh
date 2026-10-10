#!/usr/bin/env bash
# Push the locally built images to ECR under their rev tags (the repositories are immutable-tag,
# so a rev that is already there is skipped, not overwritten).
#   eks-push.sh <ecr registry> <local registry prefix> name:tag [name:tag ...]
set -euo pipefail
ECR=${1:?ecr registry (terraform output -raw ecr_registry)}; LOCAL=${2:?local registry prefix}; shift 2
REGION=${ECR#*.dkr.ecr.}; REGION=${REGION%%.*}
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR"
for it in "$@"; do
  name=${it%%:*}; tag=${it#*:}
  if ! docker image inspect "$LOCAL/$name:$tag" >/dev/null 2>&1; then echo "skip $name:$tag (not built locally)"; continue; fi
  if aws ecr describe-images --region "$REGION" --repository-name "ycash/$name" --image-ids imageTag="$tag" >/dev/null 2>&1; then
    echo "skip $name:$tag (already in ECR)"; continue
  fi
  docker tag "$LOCAL/$name:$tag" "$ECR/ycash/$name:$tag"
  docker push "$ECR/ycash/$name:$tag"
done
