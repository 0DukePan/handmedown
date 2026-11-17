// Package version carries the build identity of the hand binary.
package version

import "runtime"

// Version is the release version. It is overridden at release time, not committed:
//
//	go build -ldflags "-X github.com/0DukePan/handmedown/agent/internal/version.Version=v0.1.0"
var Version = "dev"

// Runtime is the target this binary was built for, as os/arch. Bug reports need it:
// "it will not join" means something different on windows/amd64 than on linux/arm64.
func Runtime() string {
	return runtime.GOOS + "/" + runtime.GOARCH
}
