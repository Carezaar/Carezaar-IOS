> Final-source checkpoint: all 143 signed units, Arabic and English native match-card regressions, Release build/static analysis and 32-marker audit passed after the Arabic CMS-key fix. See IOS_TEST_EXECUTION_REPORT.md and OCT13-REQUIREMENTS.md for current scoped acceptance; preliminary pending statements below are preserved history. The full original QA plan remains incomplete.

# October 13 match and favorite requirements 3 and 7

## Root cause and historical conflict

The old profile action retained only an enum when verification failed, then Try Again merely fetched and cleared that action. It discarded the confirmed introduction/context and required another confirmation. Its failed-write resolution treated every changed state as an external change, including the same relationship becoming active after the user accepted it. Favorite failures restored an optimistic snapshot without reading the server.

The latest client instructions supersede those behaviors. Earlier reports remain historical evidence.

## Match regression loop

The existing public pure `MatchFailureResolution` seam reproduced the defect: received relationship 41 becoming active relationship 41 returned changed. The root-managed RED tracer failed in 0.326 seconds, in `password-green-poller-match-red.log` and matching `.xcresult` outside the repository.

The updated assertion requires the exact matched outcome with explicit accept intent. Production now retains the originally confirmed action, relationship and introduction, plus preflight/uncertain/acknowledged phase. Try Again may submit only a preflight intent whose original relationship is still valid. An attempted or acknowledged operation is read and reconciled without replay. Same-relationship accept success or request success becoming active opens the matched screen. Completed cancellation actions reflect none. Replacement IDs and incompatible states retain changed presentation.

Cancelling a connection window does not erase an uncertain operation. A later confirmation first reconciles that operation, rather than silently resetting it.

## Validation status

MatchingTests passed all 9 tests in 0.010 seconds in the root-managed run, including exact matched success and replacement-ID changed outcome. The favorite seam was extracted and wired into both actual call sites with behavior equivalent to the prior mutation-only implementation and failure rollback. The lost-response/profile-read tracer then failed in 0.202 seconds with no authoritative read. After that RED result, the coordinator was updated to read the appropriate role-specific profile after an ambiguous write, verify target identity, and return its actual favorite state. A typed failure carries authoritative state when it differs from the desired state, so both views reflect the actual state while showing the managed underlying error. Shared per-account/partner operation ownership rejects overlapping mutations. Unresolved desired-state attempts remain read-only on later taps; proven preconnection failure permits deliberate retry. The favorite GREEN and broader scenarios are pending. Broader match/favorite scenarios remain pending. No manual simulator or production readiness claim is made here.
