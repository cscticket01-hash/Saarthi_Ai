# Sync Engine 3: clearer pending diagnostics and adaptive speed

Scope: the user's two requested additions only; no release/version rename or provider deployment.

Control Center overview now shows retained pending work, the owner's recorded recovery deadline, pause/automatic-off state and measured adaptive batch status. Queue cards explain the classified reason and row-specific retry deadline, raised by a later shared quota deadline. Review-only/legacy items never present a stale timestamp as an automatic send. Unknown deadlines remain unknown. Local display refresh uses the existing 30-second UI timer and adds no network polling. Raw server error text is not used by the new diagnostics helper.

Existing independent-record batching remains bounded to 2–10 records. Complete responses at <=2 seconds increase the window by one; 5–8 seconds reduce it by one; >=8 seconds or errors/incomplete receipts halve it. Unmeasured or intermediate timings hold the window. Timings measure the broker request, not independently measured internet bandwidth. Dependency ordering, operation IDs and verified receipt consumption remain with the existing owner.

Malformed batch response identity, duplicated/unrecognized ACKs or missing verified receipts now also record reduced pressure. Tuning metadata records prior/next window and adjustment reason. Failure to save non-authoritative tuning metadata cannot discard a verified provider reply; profile/school scope guards still apply.

Verification: dependency-free Dart checks pass for adaptive growth/backoff/bounds, row reasons, quota deadline maximum, pause, review, automatic-off, overdue and unknown deadlines, and raw-error suppression. Previous pressure/restart policy checks also pass. All edited Dart files parse; diff checks pass. Added a Flutter integration regression for invalid batch receipts retaining original operations while contracting pressure, but it has not been run. Full Flutter setup remains blocked by the earlier instance-metadata approval rejection and was not retried. No backend files changed in this turn; no new backend test-count or live performance claim is made.

Branch: codex/sync3-diagnostics-adaptive. Changes remain local until approved publication and deployment. These additions are not evidence of a Windows/Android/web release.
