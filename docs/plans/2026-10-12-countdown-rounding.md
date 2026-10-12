# Countdown rounding thresholds

The user explicitly chooses the next hour from minute 45 onward and the next
day from hour 12 onward. This replaces flooring for hour/day numbers. Previously
accepted unit selection remains: minutes below one hour, hours below one day,
days from one day onward. The current centered-dot layout and 2pt/3pt spacing stay.
Plan mode cannot be switched by this client; this saved plan is the equivalent.

## Acceptance

- R1: 4h44m59s renders 4h; 4h45m and 4h59m render 5h. Apply to every hour.
- R2: 1d11h59m59s renders 1d; 1d12h renders 2d. Apply to every day.
- R3: Unit choice uses actual remaining duration. 59m stays 59m; 23h50m
  stays 24h. At exactly one day, show 1d. Minutes keep existing ceiling.
- R4: Expired reset stays 0m. Missing/nonfinite/unsupported timestamps hide the
  countdown without dropping the provider. Supported date bounds remain safe.
- R5: Both provider image and accessibility label use the same selected reset
  label. Raw utilization, reset deadlines, polling, percentage mode and freshness
  remain unchanged. No saved data or migration is needed.

## What can go wrong

| Category | Trigger, invariant and test | Status |
| --- | --- | --- |
| Invalid input | Missing/nonfinite/out-of-range dates must still return nil; expired dates 0m. Keep negative coverage. | Existing acceptance retained |
| Concurrency | Repeated calls with a fixed clock must give the same label; formatter has no mutable state. No async or shared state change. | Fixed-clock/idempotence tests |
| Idempotency | Same date/clock repeats identically; new clock crosses each threshold once. | Boundary sequence tests |
| Timeouts | No new external boundary; pure formatting only. Existing gate/build limits stay. | Not applicable to formatter |
| Retries | No fetch/retry/polling edit. Existing usage scheduling compares raw dates. | Call-site inspection |
| Partial failure | Unknown reset omits suffix while keeping logo/percentage; rendering cannot fabricate a reset. | Existing native invalid-reset tests |
| Auth | No credential, account or cache edit; use current selected window. | Not applicable to formatter |
| Data limits | Threshold arithmetic must remain bounded for supported dates; fractional seconds near 45m/12h must not jump early. | Seeded boundaries and date extremes |
| Migration | No setting/schema change. Existing selected windows and used/remaining preference keep their values. | Not applicable; unchanged contracts |

Fresh spec-only tests use gpt-6.1-sol; separate implementation uses gpt-6-astra.
Shared filesystem isolation is procedural. Freeze the threshold tests before
production code, reproduce the old flooring mismatch, implement the scoped
formatter, then run focused acceptance and unchanged full configured gates.
Challenge the strict threshold in a disposable mutant. Final docs and staging
must finish before guarded commit; do not mutate them while checks run.

PR #3 is now merged. Start from fetched main in a clean branch, create a new PR
assigned to innolope-dev, verify exact-head hosted checks and the clean-source
universal build, then update the installed app with rollback. No merge or release
publication is inferred. Preserve the current verified400f7a9 app until replacement
verification succeeds.

Independent tests froze before production edits at SHA256
6b4ee627a0652faf8f7d23350334b80e04794c59f7a8d7cb1e2199fdd92f1dac.
Coverage includes literal boundaries, all 23 hour boundaries and 100 day boundaries
at ±0.001 seconds, fixed/advancing clocks, supported date extremes and 8,192 generated
samples (seed 0xC0FFEE). Existing selection/image/invalid-reset assertions remain.

## Verification before full project gates

- Baseline: the old formatter fails the frozen acceptance suite at 7,199.999
  seconds, returning 1h where the accepted policy expects 2h.
- Implementation: all 8,664 countdown checks pass, including 8,192 generated
  samples with seed 0xC0FFEE and native menu rendering assertions.
- Deliberate failing variant: a disposable copy delays the hour threshold by one
  second. The frozen suite rejects it at exactly 17,100 seconds (4h45m).
- Bounded breadth: 23 hour boundaries and 100 day boundaries at three offsets,
  plus generated fractional durations and supported date extremes. No new I/O,
  async state, persistence or retry logic was introduced, so concurrency, fault
  injection and load workloads are not applicable to this pure formatter.
- Remaining delivery checks: unchanged configured tests/lint, exact-head CI,
  universal build provenance/signature, and installed app verification.
