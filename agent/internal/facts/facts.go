// Package facts reports what a device can offer, in the shape the scheduler needs.
//
// Every value is best-effort. A device with no battery, no thermal zone, or an OS this build does not
// know yet still runs jobs — it just reports "unknown" (-1 / "unknown") and gets scheduled on what is
// known. Refusing to run because a sensor is missing would be the wrong failure mode for a tool whose
// whole point is using old hardware.
package facts

import (
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
)

// Facts is one device's self-description.
type Facts struct {
	Host       string
	OS         string
	Arch       string
	Cores      int
	MemMB      int
	DiskFreeMB int
	Battery    int    // percent, or -1 when there is no battery reading
	Thermal    string // nominal | warm | hot | unknown
}

// Collect reads the current device facts. It never fails: anything unavailable becomes a zero or an
// explicit "unknown".
func Collect() Facts {
	host, err := os.Hostname()
	if err != nil {
		host = "unknown"
	}

	return Facts{
		Host:       host,
		OS:         runtime.GOOS,
		Arch:       runtime.GOARCH,
		Cores:      runtime.NumCPU(),
		MemMB:      memMB(),
		DiskFreeMB: diskFreeMB("."),
		Battery:    battery(),
		Thermal:    thermal(),
	}
}

// Summary is the one-line form `hand doctor` prints.
func (f Facts) Summary() string {
	battery := "no battery"
	if f.Battery >= 0 {
		battery = fmt.Sprintf("%d%%", f.Battery)
	}
	return fmt.Sprintf("%s  %s/%s  %d cores  %d MB RAM  %d MB disk free  %s  thermal %s",
		f.Host, f.OS, f.Arch, f.Cores, f.MemMB, f.DiskFreeMB, battery, f.Thermal)
}

// CanRun reports whether a shard of the given size could start here. It is intentionally permissive:
// the scheduler uses full facts to *rank* devices, and only hard facts (disk, drained battery) veto.
func (f Facts) CanRun(needDiskMB int) bool {
	if f.DiskFreeMB > 0 && f.DiskFreeMB < needDiskMB {
		return false
	}
	// A phone at 4% is a phone that is about to vanish mid-shard, which is legal but rude.
	if f.Battery >= 0 && f.Battery < 15 {
		return false
	}
	return f.Thermal != "hot"
}

// --- pure helpers, tested on every platform ---------------------------------

// parseMeminfoMB reads the MemTotal line of /proc/meminfo, in kB.
func parseMeminfoMB(raw string) int {
	for _, line := range strings.Split(raw, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 || fields[0] != "MemTotal:" {
			continue
		}
		kb, err := strconv.Atoi(fields[1])
		if err != nil || kb <= 0 {
			return 0
		}
		return kb / 1024
	}
	return 0
}

// classifyThermalMilliC buckets a millidegree reading. The thresholds are deliberately conservative:
// a device is only "hot" when a long job on it would be a bad idea.
func classifyThermalMilliC(milliC int) string {
	switch {
	case milliC <= 0:
		return "unknown"
	case milliC >= 80_000:
		return "hot"
	case milliC >= 65_000:
		return "warm"
	default:
		return "nominal"
	}
}

// parsePmsetPercent reads the first percentage out of `pmset -g batt`.
func parsePmsetPercent(raw string) int {
	index := strings.Index(raw, "%")
	if index < 0 {
		return -1
	}
	// Walk back over the digits that precede the sign.
	start := index
	for start > 0 && raw[start-1] >= '0' && raw[start-1] <= '9' {
		start--
	}
	if start == index {
		return -1
	}
	percent, err := strconv.Atoi(raw[start:index])
	if err != nil {
		return -1
	}
	return percent
}
