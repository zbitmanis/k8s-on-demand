#!/bin/bash

echo "v${nextRelease.version}" > .VERSION

sed -i "s/^version:.*/version: ${nextRelease.version}/" src/app-of-apps/Chart.yaml

for chart in src/applications/*/Chart.yaml; do
  sed -i "s/^version:.*/version: ${nextRelease.version}/" "$chart"
done

# Update platform-scripts image tag if src/scripts/ changed since last release
PREV=$(git tag --sort=-version:refname | head -1)
SCRIPTS_CHANGED=false

if [ -z "$PREV" ]; then
  echo "No previous tag — treating platform-scripts as changed."
  SCRIPTS_CHANGED=true
elif ! git diff --quiet "$PREV" HEAD -- src/scripts/; then
  echo "src/scripts changed since $PREV — updating image references."
  SCRIPTS_CHANGED=true
else
  echo "src/scripts unchanged since $PREV — skipping image reference update."
fi

if [ "$SCRIPTS_CHANGED" = "true" ]; then
  NEW_IMAGE="${DOCKERHUB_USERNAME}/${DOCKERHUB_REGISTRY}:v${nextRelease.version}"
  echo "Setting platform-scripts image to $NEW_IMAGE"

  sed -i "s|value: \"[^\"]*platform-scripts:[^\"]*\"|value: \"$NEW_IMAGE\"|g" \
    src/workflows/tenant-lifecycle.yaml \
    src/workflows/cluster-suspend.yaml \
    src/events/sensors.yaml
fi
