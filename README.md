# Ceph RBD Docker volume plugin

Maps Ceph RBD images as Docker volumes so containers and Docker Swarm services can use them like any other named volume. Validated against Ceph Squid (19.x).


## Published images

| Image | For |
|---|---|
| `ghcr.io/r-oswald/rbd-swarm-mount-plugin:4.2.0` | Writers |
| `ghcr.io/r-oswald/rbd-swarm-mount-plugin-ro:4.2.0` | Read-only consumers |

The RO variant maps with `rbd map --read-only` and mounts with `-o ro,nouuid,norecovery` (XFS) or `-o ro,noload` (ext4).


## Requirements

- Docker ≥ 1.13 with plugin v2 support
- Ceph cluster reachable from each node, with `/etc/ceph/ceph.conf` and a keyring on the host (bind-mounted into the plugin)
- `rbd` kernel module loaded (`echo rbd >> /etc/modules`)


## Install

On every node that should be able to mount RBD volumes:

```bash
docker plugin install ghcr.io/r-oswald/rbd-swarm-mount-plugin:4.2.0 \
  --alias rbd \
  --grant-all-permissions \
  RBD_CONF_POOL=rbd \
  RBD_CONF_KEYRING_USER=client.admin \
  VOLUME_FSTYPE=xfs \
  VOLUME_MKFS_OPTIONS=-f \
  VOLUME_SIZE=10240 \
  MOUNT_OPTIONS="--options=noatime,nodiratime,logbufs=8,logbsize=256k"
```

Optional read-only alias on nodes that need read-only consumers:

```bash
docker plugin install ghcr.io/r-oswald/rbd-swarm-mount-plugin-ro:4.2.0 \
  --alias rbd-ro \
  --grant-all-permissions \
  RBD_CONF_POOL=rbd \
  RBD_CONF_KEYRING_USER=client.admin \
  VOLUME_FSTYPE=xfs \
  MOUNT_OPTIONS="--options=noatime,nodiratime"
```


## Using volumes

```bash
docker volume create -d rbd --opt size=10240 mydata

docker run -v mydata:/data alpine sh

docker service create --replicas=1 \
  --mount type=volume,source=mydata,destination=/data,volume-driver=rbd \
  alpine sleep infinity
```


## Per-volume options (`docker volume create --opt`)

| Option | Effect |
|---|---|
| `size=<MB>` | RBD image size in MB |
| `order=<n>` | RBD object size order (22 = 4 MiB) |
| `fstype=<ext4\|xfs\|...>` | Filesystem to format at create. Detected at mount time. |
| `mkfsOptions=<single arg>` | mkfs options (passed as a single argument) |
| `mountOptions=<single arg>` | Per-volume mount options, persisted as `rbd image-meta` and applied by any plugin instance on any node. Overrides the plugin's `MOUNT_OPTIONS` default. |


## Plugin env vars

| Key | Default | Meaning |
|---|---|---|
| `LOG_LEVEL` | `0` | 0=Error, 1=Warn, 2=Info, 3=Debug |
| `RBD_CONF_POOL` | `ssd` | Ceph pool name |
| `RBD_CONF_CLUSTER` | `ceph` | Ceph cluster name |
| `RBD_CONF_KEYRING_USER` | `client.admin` | Ceph client (needs `profile rbd` cap on the pool) |
| `RBD_CONF_NAMESPACE` | `""` | Optional RBD namespace |
| `VOLUME_FSTYPE` | `ext4` | Default fs for new volumes |
| `VOLUME_MKFS_OPTIONS` | `-O mmp` | Default mkfs options |
| `VOLUME_SIZE` | `512` | Default size in MB |
| `VOLUME_ORDER` | `22` | Default RBD object size order |
| `MOUNT_OPTIONS` | `--options=noatime` | Default mount options (single arg, no spaces) |


## Concurrency model

Don't have multiple writers on the same volume.

For a read-only container, use `docker run -v vol:/data:ro`. The plugin doesn't enforce read-only — Docker does, at the bind-mount layer.

To mount the same volume read-only from another node (or container) alongside the writer, install the `-ro` variant. It maps with `--read-only` so the block device can coexist with the writer; without it, RBD's exclusive-lock blocks the second mount.


## About

Fork of [wetopi/docker-volume-rbd](https://github.com/wetopi/docker-volume-rbd) v4.1.0 with updated dependencies (Go 1.26, go-ceph v0.39, Ceph Squid base), tighter failover and cleanup, per-volume mount options, and separate writer / reader images.

For anything not covered here, the [upstream README](https://github.com/wetopi/docker-volume-rbd) still applies — most behavior is unchanged.


## License

MIT. Copyright (c) 2017 wetopi. Copyright (c) 2026 Roman Oswald.
