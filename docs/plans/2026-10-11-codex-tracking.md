# Add Codex usage tracking

User explicitly added Codex tracking and approved use of a fork on 2026-10-11.
Keep the Chrome work in scope. Use documented Codex app-server account/rateLimits/read
through the installed Codex executable so Codex owns its authentication/renewal.
No OAuth tokens are copied, no inference or conversations are started.
Source inspected: https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt

## Acceptance

- C1: Claude/Codex selector shows independent usage. Selected provider drives the
  menu bar. Both refresh at launch and every minute and support manual refresh.
- C2: Codex shows each returned metered bucket, primary/secondary used percentages,
  actual window lengths and reset timestamps. Prefer rateLimitsByLimitId when
  nonempty; fall back to legacy rateLimits. Missing data is unavailable, never zero.
- C3: Connect to an installed Codex CLI/app executable using stdio JSON RPC:
  initialize, initialized, account/read, account/rateLimits/read only. No thread,
  inference, credits/email action, shell expansion or copied credentials.
- C4: Missing CLI/sign-in, API-key-only auth, process/protocol failures and timeouts
  show actionable errors. Re-read Codex login each fetch; clear stale usage on error.
- C5: Coalesce requests; execute off-main; timeout after 20 seconds and clean up
  process/pipes with forced termination after a grace period. Bound output to 1MiB,
  buckets to 64 and reject malformed numeric fields. Ignore unrelated notifications.
- C6: Notifications use the existing usage-alert setting and thresholds; each
  Codex bucket/window has independent deduplication, reset with window or login.
  Provider credentials never appear in UI, logs, app defaults or test fixtures.
- C7: Keep all Claude settings and manual fallback. A local executable picker and
  sign-in/download guidance recover missing Codex installations.

## What can go wrong

| Category | Trigger | Invariant and test |
|---|---|---|
| Invalid input | Invalid JSON, missing/null/Boolean/negative/nonfinite percentages | Reject or mark missing; never fabricate zero; schema fixtures |
| Concurrency | Timer/manual overlap or account switch | Single request, main-thread publication, fresh process/login; injected fetch tests |
| Idempotency | Duplicate refresh/unchanged usage | Coalesce, one notification per bucket/window threshold; manager fixtures |
| Timeouts | Hung executable/no newline/no response | 20s deadline, forced exit, error and next-refresh recovery; fake executable |
| Retries | Auth/network failure | No inner retry loop; next minute/manual attempt |
| Partial failure | Some missing windows, child exits after initialize | Null shown unavailable; partial RPC fails without stale usage; fixtures |
| Auth | No login, API key login, changed account | Require ChatGPT account, use Codex auth lifecycle; never copy tokens |
| Data limits | Huge output/buckets/strings | 1MiB transport, 64 buckets, bounded labels; boundary fixtures |
| Migrations | Older Codex/legacy rateLimits, new fields | Legacy fallback, ignore additive fields, actionable upgrade message |

These are technical defaults presented for edits; no business decisions are needed
to keep Claude and Codex separate. Tests derive from this spec before code.
Bounded load is not applicable to a one-request-per-minute personal tracker.
Use synthetic parser/fake-process fixtures and independent test author. Real signed-in
Codex verification may use its read-only rate-limits endpoint without logging secrets.

## Adaptive polling addition

User requested (2026-10-11 chat): above 90% five-hour usage, poll every 12 seconds
and return to normal when it resets. Apply independently to Claude and Codex.
Strict boundary: 90% stays at 60 seconds, greater than 90% uses 12 seconds only
for a 300-minute window. A known reset at/before now restores 60 seconds even if
the last response is stale. Lower usage also restores 60 seconds. Other Codex
window lengths and hourly browser sync are unaffected. Coalesce slow requests.
Tests: threshold boundaries, reset before/at/after now, null windows/reset, different
window lengths and nonfinite inputs. Invalid input must not trigger faster polling.
