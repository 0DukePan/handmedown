//go:build !windows && !linux && !darwin

package facts

// Any other platform gets the shape without the readings: it can still join a fleet and run work.
func memMB() int              { return 0 }
func diskFreeMB(_ string) int { return 0 }
func battery() int            { return -1 }
func thermal() string         { return "unknown" }
