#!/bin/bash
# rbd-plugin-setup.sh
# Idempotent install of ghcr.io/r-oswald/rbd-swarm-mount-plugin on a Swarm node.
# Defaults are tuned for MariaDB / InnoDB on Ceph RBD.
# Safe to run multiple times on any node.
# Usage: bash rbd-plugin-setup.sh

set -euo pipefail

PLUGIN_IMAGE="ghcr.io/r-oswald/rbd-swarm-mount-plugin:4.2.0"
PLUGIN_ALIAS="ghcr.io/r-oswald/rbd-swarm-mount-plugin:4.2.0"

# Ceph
RBD_POOL="rbd"
RBD_CLUSTER="ceph"
RBD_KEYRING_USER="client.admin"

# Filesystem + mount tuning for MariaDB (InnoDB):
#   noatime/nodiratime  — skip access-time updates; DBs don't need them
#   logbufs=8           — more in-memory XFS log buffers (helps fsync-heavy workloads)
#   logbsize=256k       — bigger log buffer (default 32k); reduces log-write churn
#   inode64             — allow 64-bit inodes across the device
#   -i size=512 (mkfs)  — larger inodes leave room for InnoDB xattrs without spilling
VOLUME_FSTYPE="xfs"
VOLUME_MKFS_OPTIONS="-f -i size=512"
MOUNT_OPTIONS="--options=noatime,nodiratime,logbufs=8,logbsize=256k,inode64"

# Default size (MB) when a volume is created without --opt size=
VOLUME_SIZE="10240"

echo "========================================"
echo " RBD Plugin Setup: $(hostname)"
echo "========================================"
echo ""

# ── 1. RBD Kernel Module ─────────────────────────────────────────────────────
echo "=== [1/3] RBD Kernel Module ==="

if ! lsmod | grep -q "^rbd"; then
    modprobe rbd
    echo "✓ rbd module loaded"
else
    echo "✓ rbd module already loaded"
fi

if [ ! -f /etc/modules-load.d/rbd.conf ] || ! grep -q "^rbd$" /etc/modules-load.d/rbd.conf; then
    echo "rbd" > /etc/modules-load.d/rbd.conf
    echo "✓ rbd module persistence set (/etc/modules-load.d/rbd.conf)"
else
    echo "✓ rbd module persistence already configured"
fi

# ── 2. Install Plugin ─────────────────────────────────────────────────────────
echo ""
echo "=== [2/3] rbd-swarm-mount-plugin ==="

if docker plugin ls --format '{{.Name}}' | grep -qx "${PLUGIN_ALIAS}"; then
    echo "✓ Plugin already installed — skipping install"
else
    echo "Pulling + installing ${PLUGIN_IMAGE}..."
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
    echo "✓ Plugin installed"
fi

# ── 3. Configure & Enable Plugin ─────────────────────────────────────────────
echo ""
echo "=== [3/3] Configure & Enable Plugin ==="

# Disable so docker plugin set takes effect (idempotent — ignore error if already disabled)
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
echo "✓ Plugin configured and enabled"

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
echo "=== Verify ==="
echo "Kernel module:"
lsmod | grep "^rbd" || echo "  WARNING: rbd module not found in lsmod"

echo ""
echo "Plugin status:"
docker plugin ls | grep rbd-swarm-mount-plugin || echo "  WARNING: plugin not found"

echo ""
echo "Plugin settings:"
docker plugin inspect "${PLUGIN_ALIAS}" \
    --format '{{range .Settings.Env}}{{.}}{{"\n"}}{{end}}' \
    | grep -E "POOL|NAMESPACE|FSTYPE|MOUNT|KEYRING|SIZE"

echo ""
echo "========================================"
echo " ✓ Setup complete on $(hostname)"
echo "========================================"
