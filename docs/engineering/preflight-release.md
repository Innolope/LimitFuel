# Release preflight findings

2026-10-11, intermediate release-preparation diff: a foreground signing child could
hang indefinitely. Sending TERM to the build shell deferred its trap, retaining the
child and shared lock. The disposable reproduction used a sleeping codesign stub;
no real certificate/Apple service was involved.

For shell release scripts, search `rg -n 'trap|wait|codesign|swiftc|lipo' app/build.sh`
and inspect whether each long command has a deadline and whether the shell can
forward cancellation while waiting. A foreground command that is guaranteed short
and has no owned child is not evidence of this defect by itself.

Regression: Tests/BoundedCommandTests.py proves timeout/SIGINT/SIGTERM stop delayed
descendant writes. The build invokes the runner in the background, waits with the
shell builtin, and forwards interrupts from its EXIT cleanup before releasing lock.
