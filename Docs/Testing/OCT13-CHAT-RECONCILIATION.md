> Final-source checkpoint: all 143 signed units, Arabic and English native match-card regressions, Release build/static analysis and 32-marker audit passed after the Arabic CMS-key fix. See IOS_TEST_EXECUTION_REPORT.md and OCT13-REQUIREMENTS.md for current scoped acceptance; preliminary pending statements below are preserved history. The full original QA plan remains incomplete.

# October 13 chat requirements 3 and 14

## Investigation and test seam

The existing native send action reads the conversation before every POST, and its coordinator turns a lost response into a blanket uncertain state that disables further messages behind English-only controls. The latest explicit requirements supersede those behaviors. Historical October 12 results are retained in the earlier reports.

The regression seam is `ChatSendCoordinator.submit` through the production `UserService` and `APIClient`, with a controlled URLSession protocol at the HTTP boundary. The first tracer sends once, loses the POST response, then returns a stored message from GET. It must return the verified transcript without another POST. The root-managed RED run failed this test with network error -1005 in 0.297 seconds; the baseline never reconciled the stored message. Raw evidence: `test-evidence/ios-client-update-20261013/startup-green-chat-red.log` and corresponding `.xcresult` outside the repository.

## Intended outcome rules

- Normal sending uses the current loaded conversation and does not GET before POST.
- Only one submission or reconciliation runs at a time.
- An ambiguous response triggers a read and checks newly stored message IDs against the captured transcript, current sender role, exact text, and reply target.
- A confirmed result follows normal success handling, including clearing only the submitted draft content and preserving newer typing.
- An absent or unverifiable result retains the draft and presents the existing managed error.
- Each unresolved operation retains its original snapshot. Trying that same text and reply again rechecks the outcome and never blindly repeats its POST, including after sending different text.
- Initial loading, explicit refresh, periodic refresh, and post-ambiguity reconciliation remain.

## Validation status

The first tracer passed in 0.015 seconds after the implementation change, as executed by the root-managed XCTest run. Additional regression scenarios have been written and await execution. The next tracer failed in 1.976 seconds with network error -1004: the coordinator incorrectly retained a pending outcome despite a proven closed-connection failure. The networking layer now preserves explicit `connectionUnavailable` provenance, which the chat coordinator treats as definitely not delivered; a later deliberate same-draft Send is allowed after recovery. It distinguishes safe preconnection transport retries from acknowledged server writes.

The old native chat controls specification is explicitly replaced by a direct-send, managed-error, retained-draft and deliberate-recovery scenario. The closed-port fixture does not prove committed-message/lost-ack behavior; controlled service tests cover that outcome. Inactive native sending now uses already loaded inactive metadata and makes no pre-send read. The existing offline and slow-send scenarios preserve draft, one-at-a-time and duplicate prevention assertions while removing the superseded preflight expectation.

Manual simulator results and full regression totals remain pending. This document makes no production readiness claim.
