package dockerVolumeRbd

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/ceph/go-ceph/rbd"
	"github.com/sirupsen/logrus"
	"golang.org/x/sys/unix"
)


func (d *rbdDriver) mapImage(imageName string) error {
	logrus.Debugf("volume-rbd Name=%s Message=rbd map", imageName)

	path := filepath.Join(d.conf["pool"], d.conf["namespace"], imageName)
	if isReadOnly() {
		_, err := d.rbdsh("map", "--read-only", path)
		return err
	}
	_, err := d.rbdsh("map", path)
	return err
}

// per-volume settings are persisted in rbd image-meta under this prefix
const imageMetaPrefix = "docker-volume-rbd."

// isReadOnly returns true when this plugin instance is configured to
// map+mount volumes read-only (RBD_READONLY=1). Read-only is a consumer-side
// decision — for mixed RW/RO access deploy a separate plugin alias with
// RBD_READONLY=1 for the read-only consumers.
func isReadOnly() bool {
	return os.Getenv("RBD_READONLY") == "1"
}

// mountOptionsFor returns the mount options string for this image.
// Precedence: per-volume image-meta override → MOUNT_OPTIONS env var → "".
func (d *rbdDriver) mountOptionsFor(imageName string) string {
	if v := d.getImageMeta(imageName, "mount-options"); v != "" {
		return v
	}
	return os.Getenv("MOUNT_OPTIONS")
}

// getImageMeta fetches a single image-meta value or empty string on any error/unset
func (d *rbdDriver) getImageMeta(imageName, key string) string {
	out, err := d.rbdsh("image-meta", "get", imageName, imageMetaPrefix+key)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(out)
}

// setImageMeta stores a key/value; logs but doesn't fail on error.
// The "--" separator prevents rbd CLI from parsing value as a flag when
// value starts with "--" (e.g. mount options "--options=noatime,...").
func (d *rbdDriver) setImageMeta(imageName, key, value string) {
	if _, err := d.rbdsh("image-meta", "set", imageName, imageMetaPrefix+key, "--", value); err != nil {
		logrus.Warnf("volume-rbd Name=%s Message=unable to set image-meta %s: %s", imageName, key, err)
	}
}


// unmapImage finds every kernel rbd device for this image and unmaps each
// by device path. Avoids the ambiguity of `rbd unmap <pool>/<image>` when
// multiple kernel devices exist for the same image (e.g. after a failed
// remount left a stale device behind).
func (d *rbdDriver) unmapImage(imageName string) error {
	logrus.Debugf("volume-rbd Name=%s Message=rbd unmap", imageName)

	devices := d.findKernelDevicesForImage(imageName)
	if len(devices) == 0 {
		return nil
	}

	var firstErr error
	for _, dev := range devices {
		// flush the block-device buffer cache so any writes the kernel was
		// still draining at umount reach the rbd image before we unmap
		shWithDefaultTimeout("blockdev", "--flushbufs", dev)

		_, err := shWithDefaultTimeout("rbd", "unmap", dev)
		if err == nil {
			continue
		}
		if rbdNotMappedRegexp.MatchString(err.Error()) {
			continue
		}
		logrus.Warnf("volume-rbd Name=%s Message=rbd unmap %s failed: %s", imageName, dev, err)
		if firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}


// findKernelDevicesForImage enumerates /sys/bus/rbd/devices and returns
// /dev/rbdN paths whose pool+namespace+name match this image.
func (d *rbdDriver) findKernelDevicesForImage(imageName string) []string {
	entries, err := os.ReadDir("/sys/bus/rbd/devices")
	if err != nil {
		return nil
	}

	pool := d.conf["pool"]
	namespace := d.conf["namespace"]

	var devices []string
	for _, entry := range entries {
		base := filepath.Join("/sys/bus/rbd/devices", entry.Name())

		if name, err := readSysfsFile(base, "name"); err != nil || name != imageName {
			continue
		}
		if p, err := readSysfsFile(base, "pool"); err != nil || p != pool {
			continue
		}
		// namespace file may be absent on older kernels; absence == empty namespace
		ns, _ := readSysfsFile(base, "namespace")
		if ns != namespace {
			continue
		}

		devices = append(devices, "/dev/rbd"+entry.Name())
	}
	return devices
}


func readSysfsFile(dir, name string) (string, error) {
	b, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(b)), nil
}


func (d *rbdDriver) mountImage(imageName string, mountOptions string) error {

    device := d.getTheDevice(imageName)
    mountpoint := d.GetMountPointPath(imageName)
    fstype := detectFstype(device)

    // XFS refuses to mount when the UUID is already mounted elsewhere; nouuid bypasses
    // this safety, which is what we want when an old client's unmount is still in flight
    // (no concurrent live writers — the old container is gone, the kernel will share
    // the superblock and the old mount completes cleanup independently)
    if fstype == "xfs" {
        if mountOptions == "" {
            mountOptions = "-o nouuid"
        } else {
            mountOptions = mountOptions + ",nouuid"
        }
    }
    if isReadOnly() {
        if mountOptions == "" {
            mountOptions = "-o ro"
        } else {
            mountOptions = mountOptions + ",ro"
        }
        // device is mapped --read-only so the kernel cannot replay any
        // pending journal; skip recovery (safe — we're a consumer-side reader)
        switch fstype {
        case "xfs":
            mountOptions = mountOptions + ",norecovery"
        case "ext4":
            mountOptions = mountOptions + ",noload"
        }
    }

	logrus.Debugf("volume-rbd Name=%s Message=mount %s %s %s", imageName, mountOptions, device, mountpoint)

    err := tryMount(fstype, mountOptions, device, mountpoint)
    if err == nil {
        return nil
    }
    // when XFS sees on-disk metadata ahead of the journal (typical after the
    // previous container was SIGKILL'd before the journal was fully flushed),
    // the kernel refuses to mount. xfs_repair -L zeros the dirty log so the
    // mount succeeds; any app-level WAL replays on startup
    if fstype == "xfs" && xfsLogInconsistent(device) {
        logrus.Warnf("volume-rbd Name=%s Message=xfs log inconsistent on %s; running xfs_repair -L", imageName, device)
        if _, rerr := shWithDefaultTimeout("xfs_repair", "-L", device); rerr != nil {
            return fmt.Errorf("xfs_repair -L %s: %s", device, rerr)
        }
        return tryMount(fstype, mountOptions, device, mountpoint)
    }
    return err
}

func tryMount(fstype, mountOptions, device, mountpoint string) error {
    if fstype != "" {
        _, err := shWithDefaultTimeout("mount", "-t", fstype, mountOptions, device, mountpoint)
        return err
    }
    _, err := shWithDefaultTimeout("mount", mountOptions, device, mountpoint)
    return err
}

// xfsLogInconsistent reports whether the kernel ring buffer shows a recent
// XFS log/metadata LSN mismatch for the given device. Used to distinguish the
// recoverable "log ahead of fs" case from a genuinely bad mount.
//
// Only entries within xfsLogScrapeWindow of now are considered, so stale
// errors from a prior incarnation of the same /dev/rbdN slot don't trigger a
// false-positive xfs_repair on a now-healthy image.
const xfsLogScrapeWindow = 60 * time.Second

func xfsLogInconsistent(device string) bool {
    out, err := shWithDefaultTimeout("dmesg", "-T", "--ctime")
    if err != nil {
        return false
    }
    needle := "(" + strings.TrimPrefix(device, "/dev/") + "):"
    cutoff := time.Now().Add(-xfsLogScrapeWindow)
    for _, line := range strings.Split(out, "\n") {
        if !strings.Contains(line, needle) {
            continue
        }
        if !dmesgLineRecent(line, cutoff) {
            continue
        }
        if strings.Contains(line, "log mount/recovery failed") ||
            strings.Contains(line, "Metadata has LSN") {
            return true
        }
    }
    return false
}

// dmesgLineRecent returns true if the bracketed ctime prefix is at or after
// cutoff. Lines without a parseable timestamp (older dmesg builds, truncated
// lines) are treated as recent so we don't lose the self-heal path entirely.
func dmesgLineRecent(line string, cutoff time.Time) bool {
    end := strings.IndexByte(line, ']')
    if end < 2 || line[0] != '[' {
        return true
    }
    t, err := time.ParseInLocation("Mon Jan _2 15:04:05 2006", line[1:end], time.Local)
    if err != nil {
        return true
    }
    return !t.Before(cutoff)
}

// detectFstype returns the filesystem type on the device by parsing blkid;
// returns "" if blkid is unavailable or can't identify it, in which case mount
// will auto-detect.
func detectFstype(device string) string {
    out, err := shWithDefaultTimeout("blkid", "-o", "value", "-s", "TYPE", device)
    if err != nil {
        return ""
    }
    return strings.TrimSpace(out)
}


func (d *rbdDriver) unmountDevice(imageName string) error {

    mountpoint := d.GetMountPointPath(imageName)
	logrus.Debugf("volume-rbd Message=umount %s", mountpoint)

    // mounts can stack at the same path (rapid rollovers under nouuid); unmount all layers
    var lastErr error
    for i := 0; i < 10; i++ {
        err := unix.Unmount(mountpoint, 0)
        if err == nil {
            continue
        }
        if errors.Is(err, unix.EINVAL) || errors.Is(err, unix.ENOENT) {
            return nil
        }
        lastErr = err
        break
    }
    return lastErr
}


func (d *rbdDriver) removeRbdImage(imageName string) error {
	logrus.Debugf("volume-rbd Name=%s Message=remove rbd image", imageName)

	rbdImage := rbd.GetImage(d.ioctx, imageName)

	return rbdImage.Remove()
}


// rbdsh will call rbd with the given command arguments, also adding config, user and pool flags
func (d *rbdDriver) rbdsh(command string, args ...string) (string, error) {

	args = append([]string{"--cluster", d.conf["cluster"], "--pool", d.conf["pool"], "--name", d.conf["keyring_user"], command}, args...)

	return shWithDefaultTimeout("rbd", args...)
}


// returns the aliased device under device_map_root
func (d *rbdDriver) getTheDevice(imageName string) string {
	return filepath.Join(d.conf["device_map_root"], d.conf["pool"], imageName)
}
