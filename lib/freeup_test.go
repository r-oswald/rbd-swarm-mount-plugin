package dockerVolumeRbd

import (
	"errors"
	"fmt"
	"syscall"
	"testing"

	"golang.org/x/sys/unix"
)

// verifies errors.Is matches unix.EINVAL/ENOENT against syscall.Errno values,
// which is what FreeUpRbdImage relies on for idempotent cleanup
func TestUnmountErrnoMatchesUnixErrno(t *testing.T) {
	var raw error = syscall.EINVAL
	if !errors.Is(raw, unix.EINVAL) {
		t.Fatalf("errors.Is(syscall.EINVAL, unix.EINVAL) returned false")
	}

	wrapped := fmt.Errorf("unmount failed: %w", syscall.ENOENT)
	if !errors.Is(wrapped, unix.ENOENT) {
		t.Fatalf("errors.Is wrapped ENOENT returned false")
	}

	if errors.Is(syscall.EPERM, unix.EINVAL) {
		t.Fatalf("errors.Is(EPERM, EINVAL) returned true")
	}
}
