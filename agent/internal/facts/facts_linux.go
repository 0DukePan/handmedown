//go:build linux

package facts

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

func memMB() int {
	raw, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return 0
	}
	return parseMeminfoMB(string(raw))
}

func diskFreeMB(path string) int {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err != nil {
		return 0
	}
	return int((stat.Bavail * uint64(stat.Bsize)) / (1024 * 1024))
}

func battery() int {
	// Termux and most Android kernels expose one or two of these globs.
	patterns := []string{
		"/sys/class/power_supply/BAT*/capacity",
		"/sys/class/power_supply/battery/capacity",
	}
	for _, pattern := range patterns {
		matches, err := filepath.Glob(pattern)
		if err != nil || len(matches) == 0 {
			continue
		}
		raw, err := os.ReadFile(matches[0])
		if err != nil {
			continue
		}
		percent, err := strconv.Atoi(strings.TrimSpace(string(raw)))
		if err != nil {
			continue
		}
		if percent < 0 || percent > 100 {
			continue
		}
		return percent
	}
	return -1
}

func thermal() string {
	matches, err := filepath.Glob("/sys/class/thermal/thermal_zone*/temp")
	if err != nil || len(matches) == 0 {
		return "unknown"
	}
	raw, err := os.ReadFile(matches[0])
	if err != nil {
		return "unknown"
	}
	milliC, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil {
		return "unknown"
	}
	return classifyThermalMilliC(milliC)
}
