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

## Desktop repair incidents, 2026-10-11

- Retina menu rendering: the mandatory gate obtained 2x lockFocus snapshots while
  focused probes obtained 1x snapshots. Identical source icon pixels downsampled
  differently when image widths changed; the independent verifier reproduced an
  alpha difference above the unchanged0.03 limit. Search `rg -n 'lockFocus|NSImage'
  app/MenuBarStatus.swift` when changing variable-width menu images. An explicit
  bitmap used at its native scale is not this implicit-resampling case. Use
  destination-resolution vector drawing; DesktopMenuTests compares the shared
  mark across provider states and render scales.
- Chrome consent: three encrypted auxiliary cookies retried one denied Keychain
  read within a single discovery. Finder and verifier reproduced three calls;
  the repaired discovery caches success or failure and makes one call. Search
  `rg -n 'passwordProvider|cachedPassword|decrypt' app/ChromeCookies.swift` when
  adding cookie paths. A later explicit user detection is a distinct operation
  and may legitimately request consent. DesktopChromeTests covers both background
  and explicit discovery with denied auxiliary reads and a valid plaintext session.
- Diagnostics opt-out: a newer main-thread enable could overtake worker teardown,
  retaining the prior cache epoch. Search `rg -n 'revision|generation|purge|close'
  app/SentryDiagnostics.swift` when changing lifecycle work. A stale callback that
  is rejected before any write/send is safe. The regression in SentryPrivacyTests
  requires generation revocation before teardown, a new epoch after re-enable and
  deletion of old queued data; it uses an offline intercepted SDK transport.
