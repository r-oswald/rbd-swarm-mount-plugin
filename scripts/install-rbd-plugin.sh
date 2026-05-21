#!/bin/bash
# install-rbd-plugin.sh
# Idempotent installer for the ghcr.io/r-oswald/rbd-swarm-mount-plugin Docker plugin
# Safe to run multiple times on any Swarm node
# Usage: bash install-rbd-plugin.sh

set -euo pipefail

PLUGIN_IMAGE="ghcr.io/r-oswald/rbd-swarm-mount-plugin:4.2.0"
PLUGIN_ALIAS="r-oswald/rbd-swarm-mount-plugin:4.2.0"
RBD_POOL="rbd"
RBD_CLUSTER="ceph"
RBD_KEYRING_USER="client.admin"
MOUNT_OPTIONS="--options=noatime,nodiratime,logbufs=8,logbsize=256k"
VOLUME_FSTYPE="xfs"
VOLUME_MKFS_OPTIONS="-f"
VOLUME_SIZE="10240"

echo "========================================"
echo " RBD plugin install: $(hostname)"
echo "========================================"

# ── 1. RBD kernel module ─────────────────────────────────────────────────────
echo ""
echo "=== [1/3] kernel module ==="

if ! lsmod | grep -q "^rbd"; then
    modprobe rbd
    echo "✓ rbd module loaded"
else
    echo "✓ rbd module already loaded"
fi

if [ ! -f /etc/modules-load.d/rbd.conf ] || ! grep -q "^rbd$" /etc/modules-load.d/rbd.conf; then
    echo "rbd" > /etc/modules-load.d/rbd.conf
    echo "✓ rbd module persistence configured"
else
    echo "✓ rbd module persistence already configured"
fi

# ── 2. Install plugin ─────────────────────────────────────────────────────────
echo ""
echo "=== [2/3] install plugin ==="

if docker plugin ls --format '{{.Name}}' | grep -qx "${PLUGIN_ALIAS}"; then
    echo "✓ plugin already installed — skipping install"
else
    echo "pulling + installing ${PLUGIN_IMAGE} as ${PLUGIN_ALIAS}..."
    docker plugin install "${PLUGIN_IMAGE}" \
        --alias="${PLUGIN_ALIAS}" \
        --grant-all-permissions \
        --disable \
        RBD_CONF_POOL="${RBD_POOL}" \
        RBD_CONF_CLUSTER="${RBD_CLUSTER}" \
        RBD_CONF_KEYRING_USER="${RBD_KEYRING_USER}" \
        RBD_CONF_NAMESPACE="" \
        MOUNT_OPTIONS="${MOUNT_OPTIONS}" \
        VOLUME_FSTYPE="${VOLUME_FSTYPE}" \
        VOLUME_MKFS_OPTIONS="${VOLUME_MKFS_OPTIONS}" \
        VOLUME_SIZE="${VOLUME_SIZE}"
    echo "✓ plugin installed"
fi

# ── 3. Configure + enable ─────────────────────────────────────────────────────
echo ""
echo "=== [3/3] configure + enable ==="

docker plugin disable "${PLUGIN_ALIAS}" 2>/dev/null || true

docker plugin set "${PLUGIN_ALIAS}" \
    RBD_CONF_POOL="${RBD_POOL}" \
    RBD_CONF_CLUSTER="${RBD_CLUSTER}" \
    RBD_CONF_KEYRING_USER="${RBD_KEYRING_USER}" \
    RBD_CONF_NAMESPACE="" \
    MOUNT_OPTIONS="${MOUNT_OPTIONS}" \
    VOLUME_FSTYPE="${VOLUME_FSTYPE}" \
    VOLUME_MKFS_OPTIONS="${VOLUME_MKFS_OPTIONS}" \
    VOLUME_SIZE="${VOLUME_SIZE}"

docker plugin enable "${PLUGIN_ALIAS}"
echo "✓ plugin configured and enabled"

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
echo "=== verify ==="
lsmod | grep "^rbd" || echo "  WARNING: rbd module not loaded"
echo ""
docker plugin ls | grep ceph-rbd-swarm-mount || echo "  WARNING: plugin not visible"
echo ""
docker plugin inspect "${PLUGIN_ALIAS}" \
    --format '{{range .Settings.Env}}{{.}}{{"\n"}}{{end}}' \
    | grep -E "POOL|NAMESPACE|FSTYPE|MOUNT|KEYRING|SIZE"

echo ""
echo "========================================"
echo " ✓ install complete on $(hostname)"
echo "========================================"
