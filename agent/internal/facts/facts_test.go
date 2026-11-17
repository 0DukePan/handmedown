package facts

import (
	"runtime"
	"testing"
)

// Fixtures are real command output, so the parsers are tested against the format that actually
// arrives rather than the one that seemed likely when the code was written.

const meminfoFixture = `MemTotal:       16331172 kB
MemFree:          512044 kB
MemAvailable:    4183420 kB
Buffers:          245120 kB
`

const pmsetFixture = `Now drawing from 'Battery Power'
 -InternalBattery-0 (id=4653155)	97%; discharging; 0:22 remaining present: true
`

func TestParseMeminfoMB(t *testing.T) {
	if got := parseMeminfoMB(meminfoFixture); got != 15948 {
		t.Errorf("parseMeminfoMB = %d, want 15948 (16331172 kB)", got)
	}
}

func TestParseMeminfoMBHandlesJunk(t *testing.T) {
	for _, raw := range []string{"", "no numbers here", "MemTotal: gibberish kB", "SwapTotal: 100 kB"} {
		if got := parseMeminfoMB(raw); got != 0 {
			t.Errorf("parseMeminfoMB(%q) = %d, want 0", raw, got)
		}
	}
}

func TestClassifyThermal(t *testing.T) {
	cases := map[int]string{
		0:      "unknown",
		-5:     "unknown",
		45_000: "nominal",
		64_999: "nominal",
		65_000: "warm",
		79_999: "warm",
		80_000: "hot",
		95_000: "hot",
	}
	for milliC, want := range cases {
		if got := classifyThermalMilliC(milliC); got != want {
			t.Errorf("classifyThermalMilliC(%d) = %q, want %q", milliC, got, want)
		}
	}
}

func TestParsePmsetPercent(t *testing.T) {
	if got := parsePmsetPercent(pmsetFixture); got != 97 {
		t.Errorf("parsePmsetPercent = %d, want 97", got)
	}
	if got := parsePmsetPercent("no battery attached"); got != -1 {
		t.Errorf("parsePmsetPercent(no battery) = %d, want -1", got)
	}
	if got := parsePmsetPercent("%"); got != -1 {
		t.Errorf("parsePmsetPercent(%% alone) = %d, want -1", got)
	}
}

func TestCollectReportsSomethingUseful(t *testing.T) {
	got := Collect()

	if got.OS != runtime.GOOS {
		t.Errorf("OS = %q, want %q", got.OS, runtime.GOOS)
	}
	if got.Arch != runtime.GOARCH {
		t.Errorf("Arch = %q, want %q", got.Arch, runtime.GOARCH)
	}
	if got.Cores < 1 {
		t.Errorf("Cores = %d, want at least 1", got.Cores)
	}
	if got.Host == "" {
		t.Error("Host is empty")
	}
	switch got.Thermal {
	case "nominal", "warm", "hot", "unknown":
	default:
		t.Errorf("Thermal = %q, want one of nominal/warm/hot/unknown", got.Thermal)
	}
	if got.Battery < -1 || got.Battery > 100 {
		t.Errorf("Battery = %d, want -1 or 0..100", got.Battery)
	}
	if got.Summary() == "" {
		t.Error("Summary is empty")
	}
}

func TestCanRunVetoesOnlyHardFacts(t *testing.T) {
	healthy := Facts{Cores: 4, DiskFreeMB: 10_000, Battery: 80, Thermal: "nominal"}
	if !healthy.CanRun(1_000) {
		t.Error("healthy device refused work")
	}

	drained := healthy
	drained.Battery = 10
	if drained.CanRun(1_000) {
		t.Error("device at 10% accepted work")
	}

	hot := healthy
	hot.Thermal = "hot"
	if hot.CanRun(1_000) {
		t.Error("device over temperature accepted work")
	}

	full := healthy
	full.DiskFreeMB = 100
	if full.CanRun(1_000) {
		t.Error("device without disk space accepted work")
	}

	// A device that reports no battery at all (a desktop) is not "drained".
	desktop := healthy
	desktop.Battery = -1
	if !desktop.CanRun(1_000) {
		t.Error("desktop with no battery reading was treated as drained")
	}

	// Unknown disk space must not veto: better to try than to leave useful hardware idle.
	unknownDisk := healthy
	unknownDisk.DiskFreeMB = 0
	if !unknownDisk.CanRun(1_000) {
		t.Error("device with unknown disk space was refused")
	}
}
