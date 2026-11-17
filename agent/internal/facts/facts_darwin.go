//go:build darwin

package facts

import (
	"os/exec"
	"strconv"
	"strings"
	"syscall"
)

func memMB() int {
	out, err := exec.Command("sysctl", "-n", "hw.memsize").Output()
	if err != nil {
		return 0
	}
	bytes, err := strconv.ParseInt(strings.TrimSpace(string(out)), 10, 64)
	if err != nil || bytes <= 0 {
		return 0
	}
	return int(bytes / (1024 * 1024))
}

func diskFreeMB(path string) int {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err != nil {
		return 0
	}
	return int((stat.Bavail * uint64(stat.Bsize)) / (1024 * 1024))
}

func battery() int {
	out, err := exec.Command("pmset", "-g", "batt").Output()
	if err != nil {
		return -1
	}
	return parsePmsetPercent(string(out))
}

// thermal: macOS does not expose a stable CLI reading, and `powermetrics` needs sudo. Unknown is the
// honest answer; a Mac is not the device that will cook itself running a shard.
func thermal() string { return "unknown" }
