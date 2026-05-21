#!/bin/bash
# uninstall-wetopi-rbd.sh
# Cleanly remove the legacy wetopi/rbd plugin from a swarm node.
# Idempotent: safe to run when the plugin isn't installed.
# Does NOT touch any RBD images in the Ceph cluster — only the local plugin install.
# Usage: bash uninstall-wetopi-rbd.sh

set -euo pipefail

PLUGIN_ALIAS="wetopi/rbd"

echo "========================================"
echo " wetopi/rbd uninstall: $(hostname)"
echo "========================================"

if ! docker plugin ls --format '{{.Name}}' | grep -q "^${PLUGIN_ALIAS}"; then
    echo "✓ ${PLUGIN_ALIAS} is not installed — nothing to do"
    exit 0
fi

# warn if any docker volumes still reference the plugin
in_use=$(docker volume ls --format '{{.Driver}} {{.Name}}' | awk -v d="${PLUGIN_ALIAS}" '$1 ~ d {print $2}' || true)
if [ -n "$in_use" ]; then
    echo "WARNING: the following docker volumes still reference ${PLUGIN_ALIAS}:"
    echo "$in_use" | sed 's/^/  - /'
    echo ""
    echo "Migrate or remove these references first; aborting to avoid breaking running containers."
    exit 1
fi

# warn if the plugin is still holding kernel-side rbd maps
if rbd showmapped 2>/dev/null | tail -n +2 | grep -q .; then
    echo "WARNING: this host has kernel rbd devices mapped:"
    rbd showmapped | sed 's/^/  /'
    echo ""
    echo "These may belong to wetopi or another plugin. Confirm + clean before removing the plugin."
    echo "To proceed anyway: set FORCE=1 and re-run."
    [ "${FORCE:-0}" = "1" ] || exit 1
fi

echo "disabling ${PLUGIN_ALIAS}..."
docker plugin disable "${PLUGIN_ALIAS}" --force 2>&1 | tail -1

echo "removing ${PLUGIN_ALIAS}..."
docker plugin rm "${PLUGIN_ALIAS}" --force 2>&1 | tail -1

echo ""
echo "========================================"
echo " ✓ ${PLUGIN_ALIAS} removed from $(hostname)"
echo "========================================"
echo ""
echo "Note: this only removed the local plugin install."
echo "Underlying RBD images in the Ceph cluster were not touched."
