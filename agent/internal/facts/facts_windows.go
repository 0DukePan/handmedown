//go:build windows

package facts

import (
	"syscall"
	"unsafe"
)

var (
	kernel32                 = syscall.NewLazyDLL("kernel32.dll")
	procGlobalMemoryStatusEx = kernel32.NewProc("GlobalMemoryStatusEx")
	procGetDiskFreeSpaceExW  = kernel32.NewProc("GetDiskFreeSpaceExW")
	procGetSystemPowerStatus = kernel32.NewProc("GetSystemPowerStatus")
)

type memoryStatusEx struct {
	Length               uint32
	MemoryLoad           uint32
	TotalPhys            uint64
	AvailPhys            uint64
	TotalPageFile        uint64
	AvailPageFile        uint64
	TotalVirtual         uint64
	AvailVirtual         uint64
	AvailExtendedVirtual uint64
}

func memMB() int {
	var status memoryStatusEx
	status.Length = uint32(unsafe.Sizeof(status))

	ok, _, _ := procGlobalMemoryStatusEx.Call(uintptr(unsafe.Pointer(&status)))
	if ok == 0 {
		return 0
	}
	return int(status.TotalPhys / (1024 * 1024))
}

func diskFreeMB(path string) int {
	wide, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return 0
	}

	var freeToCaller, total, totalFree uint64
	ok, _, _ := procGetDiskFreeSpaceExW.Call(
		uintptr(unsafe.Pointer(wide)),
		uintptr(unsafe.Pointer(&freeToCaller)),
		uintptr(unsafe.Pointer(&total)),
		uintptr(unsafe.Pointer(&totalFree)),
	)
	if ok == 0 {
		return 0
	}
	return int(freeToCaller / (1024 * 1024))
}

type systemPowerStatus struct {
	ACLineStatus        byte
	BatteryFlag         byte
	BatteryLifePercent  byte
	SystemStatusFlag    byte
	BatteryLifeTime     uint32
	BatteryFullLifeTime uint32
}

func battery() int {
	var status systemPowerStatus
	ok, _, _ := procGetSystemPowerStatus.Call(uintptr(unsafe.Pointer(&status)))
	if ok == 0 {
		return -1
	}
	// 255 means "unknown", which is what desktops report.
	if status.BatteryLifePercent == 255 {
		return -1
	}
	return int(status.BatteryLifePercent)
}

// thermal: Windows exposes this through WMI, which is COM and far more code than the signal is worth
// in v0.1. Reporting unknown is honest and costs only a scheduling refinement.
func thermal() string { return "unknown" }
