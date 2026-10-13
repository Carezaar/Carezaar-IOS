# October 13 UI implementation and verification notes

This supplement covers R5, R8, R9, R10, R11, R13, R15 and R16 in the existing SwiftUI implementation. Current execution evidence is recorded in the four root reports; early pending entries below are dated implementation findings. The root execution report remains authoritative for complete QA.

## Reference and instruction access

Read the October13 brief, both mandatory testing documents, `KOTLIN-REVERSE-ENGINEERING.md`, and `ANDROID-RUNTIME-BEHAVIOUR.md`. Original Kotlin source was not supplied. The coordinating task subsequently found and read the two-page Carezaar iOS Architecture Documentation PDF in Downloads. Current code, the supplied APK behavior and the latest client instructions resolve its older route/authentication descriptions.

The engineering chain uses investigate, diagnosing-bugs, TDD and iterate-until-verified. For the narrow UI changes, Apple HIG dialog and foundations guidance, Apple Design reduced-motion guidance and SwiftUI design guidance were read. Existing brand, typography and layouts are preserved. Explicit client changes supersede old assertions requiring location notices, Notifications modal heading/date/close, and withdrawal Close.

## Managed text evidence

Read-only `GET https://new.carezaar.com/api/base/contents?ts_cache=0` on October13 returned the actual key `settings_change_password_dialog_message` with the exact English text `You are going to change your password.` and translations for all8supported languageIDs1,2,3,4,5,6,7,8. Also present: `settings_change_password_dialog_title`, `_confirm`, `_deny`, `general_cancel`, `general_show`, `general_confirm`, and `splash_initialization` with all8translations. No undocumented key is invented.

## Initial findings

| Requirement | Actual pre-change behavior | Intended correction | Runtime evidence |
|---|---|---|---|
|5|Password alert omitted its managed message.|Use existing dialog message key between title/buttons.|Pending simulator verification.|
|8|Withdrawal dismiss action explicitly used general_close.|Use general_cancel; keep confirming action.|Pending small/large runtime verification.|
|9|Profile and Matched showed identical page text and error toast, although guarded2sreturn already existed.|Keep one short toast, preserve delayed navigation cancellation.|Modern client focused GREEN observed; broader coverage pending.|
|10|Matched cards had no slide, rotation or reduced-motion presentation.|Opposite entry paths, balanced slight angles, reduced-motion equivalent.|Implemented once-per-presentation opposing slide with slight angles, RTL mirroring and reduced-motion fade; runtime pending.|
|11|Notification sheet showed Notifications heading, explicit xmark, and timestamp.|Photo/name/text/Show only, tappable outside dismiss.|Modern client focused GREEN observed; broader coverage pending.|
|13|Header rotated every6s; hidden screen task continued sleeping and discarded ticks.|5s rotation with task cancellation for hidden/background.|Pending runtime verification.|
|15|Wizard and map exposed English stale/unavailable notices.|Silent cached position, no notices, map remains usable without selecting.|Modern client focused GREEN observed; broader coverage pending.|
|16|Only initialization hint node221:11986 had#595959fill.|Exact#7F7F7F at that node.|Semantic JSON comparison verified exactly3RGB changes; rendered check pending.|

## Test seams

- `LocationBoundaryUITests/testStaleCachedLocationIsUsedSilentlyInWizardAndMap`: real wizard/map with controlled stale provider input, actual native route and untouched backend profile.
- `PartnerNavigationBoundaryUITests/testFailedProfileShowsOneShortMessageAndReturnsWithoutRetry`: actual failing missing-profile GET, one toast, automatic return, one read, no retry.
- `NotificationFallbackUITests/testNotificationDetailsContainOnlyContentAndShowAndBackdropDismisses`: actual existing owned notification, native modal, no destination read on outside dismissal.

R9 retains `visible`, route identity and task cancellation guards so the delayed pop cannot affect a newer screen. Original tests and raw evidence are retained as history; assertions conflicting with explicit latest client instructions must be updated without weakening unrelated invariants.

No Xcode builds were launched by the UI worker while root tests were running. No Git commits, pushes, backend changes, credential publication or photo capture/uploads were performed by this worker.

## Actual RED evidence before behavior fixes

The root executed the focused native UI regressions before changes to their production behavior. `test-evidence/ios-client-update-20261013/ui-requirements-red.log` and `.xcresult` preserve the original results: stale location notice present (84.679s), Notifications modal heading present (44.965s), and profile message count2when expected1 (26.566s). These exact observed symptoms determined the fixes; results are not suppressed. Modern-client focused GREEN observed as recorded below; broader coverage remains pending.

The R16 source JSON was compared recursively against HEAD. Only the three RGB components of node221:11986 changed from0.34902to127/255; no other scene geometry, text, art or progress-bar change occurred.

The no-fix fallback map is a broad world viewport, not a saved coordinate. `center` stays nil until a real eligible fix or manual map camera movement. Continue remains available and no fake backend latitude/longitude is introduced. Removed notices also include the prior English-only save-specific map guidance. Existing no-fix, invalid-fix, late-fix and OS-denial tests retain coordinate/write safety assertions while expecting silent behavior.

Notification details now dismiss from the outside scrim and VoiceOver escape. Background content is inaccessible while details are shown; Show remains the sole button within the detail and destination resolution/missing-target safety is unchanged. Old assertions requiring heading/close/timestamp were replaced specifically because the client removed those elements. List-row timestamp and unread behavior stay covered.

## Actual focused GREEN evidence

The coordinating root ran the three regression tests on the Modern client simulator after the scoped behavior fixes. Silent stale cached location passed41.990s; minimal notification contents plus backdrop dismissal passed44.642s; singular profile error and automatic return passed21.687s. The combined run also contained independent R6 RED tests and therefore its bundle status remained FAIL; these three individual results are PASS, not a blanket suite claim.

Remaining required verification: small-screen and caregiver counterparts, R9 retest against the newly corrected managed error mapping, no-fix/denied/invalid/late location regression, notification missing targets and long text, actual R5 dialog legibility, withdrawal Cancel behavior, R10 rendered motion/reduced-motion/reopening, R13 observed5secondrotation and navigation/background cancellation, and R16 rendered exact hint color. No assigned requirement is declared fully verified from this focused run alone.

## Final-source match presentation checkpoint

Actual Arabic self label used a nonexistent CMS key. Native regression reproduced this defect before the one-line correction to chat_screen_you and passed afterward. Final-source English settled geometry/foreground/reopening also passed. Small-client default opposing entrance and actual Settings Reduced Motion stationary fade were independently reviewed from native recording frames. Invalid recording timestamps prevent precise timing/smoothness certification, and navigation during animation remains unverified. Release build/static analysis and 143 signed unit tests passed on the corrected source.
