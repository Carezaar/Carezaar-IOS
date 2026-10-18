# iOS Parity Test Execution Report: Parity Review v3.0

- **Source document:** `Carezaar - iOS and Android Parity Review v3.0.pdf`, version 3.0, dated 16 October 2026 (Android app, iOS app and server as of 16 October 2026). 17 items, all "Align with app".
- **Executed:** 17 October 2026, on the iOS repository at HEAD `17bbeda` plus uncommitted changes (not committed or pushed; for lead review).
- **Reference:** the PDF and the live managed texts (`GET base/contents`). The local Android APK (21 Sep) predates the Android update the PDF compares against.
- **Evidence root:** `outputs/Carezaar/test-evidence/ios-parity-v3/`. Screenshots are in `ui-raw/<run>/`, sanitized test summaries are in `logs/`, and pre-change screenshots are in `baseline/`. Emails are not shown. The only address visible in any screenshot is the synthetic `parity.v3@example.com` that the tests type, which an OCR sweep confirmed. No passwords or tokens appear.

## Environment

| | |
|---|---|
| Xcode | 26.6, iOS Simulator runtime iOS 26.5 (23F77) |
| Devices (created for this run) | "PV3 iPhone 17 Pro" (iPhone 17 Pro, iOS 26.5) and "PV3 iPhone SE3" (iPhone SE 3rd generation, iOS 26.5, small screen) |
| Server | live `https://new.carezaar.com/api/` |
| Variants | English; Arabic RTL (language id 3); Dynamic Type Accessibility-L (`UICTContentSizeCategoryAccessibilityL`) on the SE |

## Per-item results

The status column is the final retest result, run on the final source. A status is PASS only where that run was observed passing with evidence.

| ID | PDF | Original issue (iOS before) | Expected (Android) | Code location | Implementation | Test case(s) | Evidence | Status |
|---|---|---|---|---|---|---|---|---|
| A1 | p4 | Asked only after sign-in, when Main first opened | Ask at app start, carry on whatever the answer | `CarezaarApp.swift`, `Core/Session/NotificationPoller.swift` | `requestPermissionAtLaunch()` called from the root `.onAppear`. Polling no longer asks first, and the request is made only once | `PollerTests.testPermissionIsRequestedAtLaunchOnceAndPollingDoesNotAskAgain`; `ParityV3UITests.testA1…` (fresh install) | `ui-raw/final-A1-pro/A1-prompt-at-launch.png` (prompt over the splash, signed out), `A1-welcome-after-refusal.png` | **PASS** |
| B1 | p4 | Showed a generic error and stayed on Sign In | Show the server's message and open the profile step | `Core/Networking/APIClient.swift`, `APIError.swift`, `Features/Auth/AuthScreens.swift` (SignInView), `SignUpFlow.swift` | `auth/login` 409 → `RegistrationIncompleteError(message, meta.role)`. The app shows a toast with the server text, `SignUpFlow.resume(role, email, password)`, then pushes the profile step. Anonymous `users/profile` (keyed by email, repeatable; verified live) → role wizard → `clients`/`caregivers` with `user_id` → sign-in | `SessionTests.testIncompleteRegistrationLoginCarriesServerMessageAndRole`, `testSignUpResumeSeedsProfileStepState`; `SignupTests.testUnfinishedSignupSignInResumesAtProfileStep` (end to end to Main) | `ui-raw/final-b1k3-pro/B1-profile-step-with-server-message.png`; earlier client (`B1-client-pro`) and caregiver on SE (`SE/`) | **PASS**: client with no profile, client with an existing profile (final run) and caregiver with no profile on SE all completed sign-up and reached Main |
| C1 | p5 | Continue disabled; one problem at a time; English-only email texts; weak password reported as "This field is required." | Continue always active; every problem under its own field | `Core/Validation/Validation.swift` (`SignUpCredentialsValidation`), `AuthScreens.swift` (SignUpCredentialsView), `SceneBinder.swift` + `DesignElement.swift` (`yOffset`) | Missing → `general_required`; invalid email → `signup_credentials_email_invalid`; password → the first unmet rule's managed label (`signup_credentials_password_validation_*`, checklist order: 8 letters, lowercase, uppercase, number, symbol); mismatch → `signup_credentials_password_match`; agreement → `signup_credentials_accept_required`. Errors clear when the field is edited and are announced to VoiceOver. Continue moves down to make room | `ValidationTests` (3 new); `ParityV3UITests.testC1C2C3…`; `AuthBoundaryUITests` and `AuthRuleMatrixUITests` adapted to the new contract | `ui-raw/final-active-pro/C1-*.png`, `final-rtl-pro/C1-*-ar.png`, `final-axl-se/C1-*-axl.png` | **PASS** |
| C2 | p5 | "I accept the license agreement", whose sheet is now empty | Consent sentence; each name opens the document in the app (scroll and zoom) | `AuthScreens.swift` (consent row, `LegalDocument`, `LegalDocumentView`, `LegalWebView`), `APIConfiguration.swift` (`LegalDocumentConfiguration`), `Resources/Assets/legal/*.pdf` | `signup_credentials_consent` with underlined, tappable managed names. The client's Terms of Use (22 pages) and Privacy Policy PDFs (17 Oct) are bundled and shown in a WKWebView with native scroll and pinch zoom (up to 5×). The old checkbox label and licence sheet are removed | `ParityV3UITests.testC1C2C3…` (both documents open, scroll, pinch-zoom, close; VoiceOver labels); `AuthBoundaryUITests.testSignupConfirmationTerms…` | `ui-raw/client-material/C2-viewer-terms.png`, `-zoomed.png`, `C2-viewer-privacy*.png` | **PASS** (18 Oct, with the client's documents; PDFs present in the Release bundle) |
| C3 | p5 | Own sentence under a slug the server lacks | `signup_credentials_confirm_dialog_description` | `AuthScreens.swift` | The managed sentence is drawn as written (the design node's Title Case styling would have changed it), localized | `ParityV3UITests.testC1C2C3…` | `ui-raw/final-active-pro/C3-confirmation-dialog.png` (+ `-ar`, `-axl`) | **PASS** |
| C4 | p5 | Stayed on the form; a second Continue failed because the account existed | Open the code screen anyway; the code can be requested again | `AuthScreens.swift` (`confirm()`, OTPView), `SignUpFlow.swift` (`otpSendFailed`) | Registration and code sending are separate. A send failure shows a toast and still opens the code screen, where Re-send is available at once | `ParityV3UITests.testC4…` (Debug `--qa-fail-once POST users/otp/send` forces a real connection failure on the first send only; real Re-send; real emailed code; continues to the profile step) | `ui-raw/final-active-pro/C4-code-screen-after-send-failure.png`, `C4-profile-step-after-resend.png` | **PASS** |
| F1 | p6 | Filled in the phone location automatically; whole-world map | No auto-fill; map opens on the whole country; phone location only via My Location | `Features/Onboarding/PreferencesWizard.swift` | The wizard no longer creates a LocationProvider. `MapLocationPicker.countryRegion` = 39.8283, −98.5795 (the web/Android US centre). The phone fix is applied only after My Location | `ParityV3UITests.testF1F3…`; rewritten `LocationBoundaryUITests` (5 tests); `SignupTests` wizard path | `ui-raw/final-active-pro/F1-location-row-empty.png`, `F1-map-opens-on-country.png`, `F1-after-my-location.png` | **PASS** |
| F2 | p6 | Nothing shown when access is refused | `general_location_permission_denied` | `PreferencesWizard.swift` (MapLocationPicker) | A note on the map (with a VoiceOver announcement) when access is denied, whether already denied or refused at the prompt My Location raised | `ParityV3UITests.testF2…`; `LocationBoundaryUITests.testControlledNoFixRequiresLocationAndExplainsRefusedAccess` | `ui-raw/final-active-pro/F2-location-permission-denied.png` (+ `-ar`, `-axl`) | **PASS** (after a lead-review fix). The simulator test uses the Debug "denied" fixture. On a physical iPhone 15 the live iOS prompt + "Don't Allow" first showed **no** note (defect: `.onReceive(location.$status)` read the old status, because `@Published` emits before the value changes); fixed to use the emitted value and re-verified on the device (`test-evidence/ios-parity-v3/device-iphone15/device-F2-live-dont-allow.png`) |
| F3 | p6 | Allowed continuing, then opened the map on Save without saying why | `general_location_required` | `PreferencesWizard.swift` | Step 3 Continue and Save without a location show the managed message and stay | `ParityV3UITests.testF1F3…`; `SignupTests` (B1 path); `LocationBoundaryUITests` | `ui-raw/final-active-pro/F3-location-required.png` | **PASS** |
| K1 | p7 | Updated only on pull or reopen | Refresh every 10 s while open | `Features/Main/MainView.swift` (MessagesTab), `DesignSystem/Kit.swift` (`Pager.refreshQuietly`) | `.task(id: visible && scene active)` loop, so there is at most one timer and none while hidden or in the background. It replaces page 1 only on success, with no spinner or error | `PagerTests` (2 new); `ParityV3UITests.testK1…` | `ui-raw/final-active-pro/K1-list-refreshed-with-partner-message.png` | **PASS**: a caregiver message sent through the API appeared in the client's open list without any action (11 s in the first run); request counts show one timer, and none while on Profile |
| K2 | p7 | Box stayed open; pop-up on send | Box off, grey Send, note `chat_screen_match_check` | `Features/Main/ChatView.swift` (`ChatAvailability`, `ChatComposer`) | Note above the disabled field; Send disabled; send-time pop-up removed | `ChatSettingsTests.testDeletedAccountDecodesAndWinsOverMatchCheck`; `ParityV3UITests.testK2…` (client) and `testK2CaregiverSide…`; rewritten `MatchStateMatrixUITests.rejectInactiveSend` | `ui-raw/final-k2-pro/K2-unmatched-conversation.png`, `K2-unmatched-conversation-caregiver.png`, `final-rtl-k2-pro/`, `final-axl-se-k2/` | **PASS** (both roles after a real unmatch; lead review corrected Send from faded blue to grey and re-ran both K2 tests and K3 on iPhone 17 Pro / iOS 26.5: 3/3 passed, `ui-raw/lead-grey-send/`) |
| K3 | p7 | Empty name; conversation open | "Deleted Account" everywhere; conversation closed with `chat_screen_account_deleted` | `Models/User.swift` (`isDeleted`, `displayName`), `ChatView.swift`, `MainView.swift`, `NotificationsView.swift`, `FavoritesView.swift`, `PartnerDetailsView.swift` | `is_deleted` decoded. Deleted users are named `general_deleted_account` in lists, the chat header, notifications, cards and profiles. The deleted note wins over K2 (the server also sends `is_match:false`) | `ChatSettingsTests` (2 new); `ParityV3UITests.testK3…` | `ui-raw/final-b1k3-pro/K3-messages-list.png`, `K3-conversation-closed.png`, `K3-notifications.png` (+ `-ar`, `-axl`) | **PASS** (caregiver account actually deleted through the API) |
| K4 | p7 | Send disabled when empty | Send tappable; `chat_screen_message_required` | `ChatView.swift` | Empty tap shows the managed toast; no request | `ParityV3UITests.testK4…`; `ChatNetworkBoundaryUITests` updated | `ui-raw/final-active-pro/K4-empty-send.png`, `final-axl-se/K4-empty-send-axl.png` | **PASS** |
| M1 | p8 | Old empty-room header photos | Phone-with-conversation (Messages) and care-scenes illustration (Profile) | `MainView.swift` (MessagesTab), `Resources/Assets/app/header_messages.webp` | Messages uses the client's phone picture (17 Oct). Profile is unchanged: the supplied illustration shows people, and we don't use pictures of people; the client may add it themselves | simulator screenshots | `ui-raw/client-material/M1-messages-header.png`, `M1-profile-header-unchanged.png` | Messages **PASS**; Profile **left to the client** |
| M2 | p8 | "Update your account password" | `profile_password_change_description` | `MainView.swift` (ProfileTab) | Slug switched | `ParityV3UITests.testM2…` | `ui-raw/final-active-pro/M2-profile-menu.png` (+ `-ar`, `-axl`) | **PASS** |
| Q1 | p9 | A renewal server error kept the person signed in and showed an error | Any HTTP error answer → sign out; the window appears only when the server is unreachable | `APIClient.swift` (`refreshSession`, `sendEnvelope`) | A non-2xx renewal answer counts as rejection → `expireSession` → Welcome. A transport failure is the only path to the window. Kept: a malformed 2xx body or a Keychain write failure keeps the credentials (not an HTTP error) | `SessionTests.testRenewalHTTPErrorSignsOutButMalformedSuccessKeepsSessionWithoutDialog` (400/404/500/503/200-malformed), `testRenewalServerErrorDuringStartupSignsOut`; `ChatSettingsTests` updated; `ParityV3UITests.testQ1…` (real server 404 via Debug `--qa-refresh-http-error`) | `ui-raw/final-active-pro/Q1-signed-out-after-renewal-error.png` | **PASS** |
| Q2 | p9 | Waiting requests resumed after Retry | Retry success closes the window; failed requests keep their error and are not repeated | `APIClient.swift` (`retryRenewal`), `SessionManager.swift` (`SessionRecoveryCoordinator`), `CarezaarApp.swift` | The request fails at once with its own error and reports "unreachable". The coordinator shows one window; Retry renews only (renewed → close, unreachable → reopen, rejected → signed out) | `SessionTests` (5 new/rewritten); `ParityV3UITests.testQ2…`; existing `SessionNetworkTests.testNativeRenewalConnectionDialogRetriesAndPreservesHelpRoute` | `ui-raw/final-active-pro/Q2-connection-problem.png`, `Q2-after-retry.png` (error state kept, window closed, no extra GET) | **PASS** |

Summary (updated 18 Oct): 16 PASS, 1 partly done (M1: Messages done; the Profile picture shows people, so it is left to the client), 0 FAIL, 0 NOT APPLICABLE.

### Choices made where the PDF is silent

- **C1 password wording:** the "first password rule not met" is shown with that rule's managed checklist label ("8 letters", "One lowercase", "One uppercase", "One number", "One special symbol"). No fuller managed sentence exists. The order follows the app's checklist.
- **C4:** because no code was sent, Re-send is available immediately rather than after the 2-minute wait.
- **F1:** "whole country" is the contiguous USA (centre 39.8283, −98.5795, as in the web `LocationPicker.tsx`, zoom 4 ≈ MapKit span 28° × 62°).
- **Q1:** only HTTP error answers sign the person out. A 2xx with an unusable body, or a local Keychain failure, keeps the session (it is not a server error answer).
- **Scene geometry:** the Create Account screen is a fixed-geometry Figma scene. The new consent sentence, field errors and dialog sentence use the scene's fixed type sizes, so Dynamic Type does not push them over the controls (verified at Accessibility-L). The legal viewer and all other new UI (chat note, map note) scale with Dynamic Type.

## Lead review (17 Oct, after the agent run)

- K2/K3: the closed composer's Send button was faded blue; Android (and the PDF) say grey. `ChatView.swift` now draws it in `Theme.Palette.textSecondary` when the conversation is closed. Re-ran `testK2UnmatchedConversationIsClosedWithNote`, `testK2CaregiverSideOfUnmatchedConversationIsClosed` and `testK3DeletedAccountShownAndConversationClosed` on a fresh iPhone 17 Pro (iOS 26.5) simulator: 3/3 passed (screenshots in `test-evidence/ios-parity-v3/ui-raw/lead-grey-send/`).
- Unit target re-run on the final source: 157/157 passed. Debug and Release builds succeed.

## Physical device (iPhone 15, iOS 26.5.2), lead review 17 Oct

Signed Debug build (team 9Y959T63P7), fresh install each run, live server, disposable client with a closed and a deleted-account conversation. Tests: `ParityV3UITests.testDeviceA1NotificationPromptAndF2LiveLocationRefusal`, `testDeviceAccessibilityAuditOfChangedScreens` (skip in the Simulator).

| Check | Result |
|---|---|
| A1: real prompt "“Carezaar” Would Like to Send You Notifications" at launch; "Don't Allow"; app carries on to the screen it opened | PASS |
| F1: map opens on the saved location; the phone's position is only asked for on My Location | PASS (real prompt "Allow “Carezaar” to use your location?" appeared only after My Location) |
| F2: real location prompt → "Don't Allow" → "Allow location access to use your current location." | **FAIL, then fixed and PASS** (see F2 row) |
| Accessibility audit on 4 changed screens | PASS (test fails only on missing VoiceOver descriptions: none). 15 advisory findings logged in `device-iphone15/accessibility-audit.txt`: Dynamic Type not supported by the fixed-geometry Figma sign-up scene (known, documented design choice); clipped previews in the list (intentional truncation); contrast on profile secondary text (pre-existing); contrast on the closed-chat note, which is a false positive: `#595959` on `#EDF4FC` is 6.32:1, above WCAG AA 4.5:1 |

After the F2 fix: device run 2/2 passed; Simulator unit target 157/157; `ParityV3UITests` F1/F3 and F2 (fixture path) passed.

## Automated test commands and counts

Built with `xcodebuild build-for-testing -project Carezaar.xcodeproj -scheme Carezaar -sdk iphonesimulator -destination id=<sim> -derivedDataPath <scratch>/dd`. Tests ran with `xcodebuild test-without-building … -only-testing:<suite or test>`. Accounts reached the runner through `TEST_RUNNER_*` environment variables only.

| Run (on final app source unless noted) | Result |
|---|---|
| Clean build (`clean` + `build-for-testing`) | Succeeded. Warnings: the 2 pre-existing `QALaunch.swift` `appendInterpolation` deprecations (same statement, line moved from 370 to 389) and nothing new |
| Unit target `CarezaarTests` (final) | **157 executed, 157 passed, 0 failed, 0 skipped** (`logs/unit-final.summary.txt`). An earlier run with `CODE_SIGNING_ALLOWED=NO` failed only `KeychainTests` (real Keychain needs a signed host); runs are signed since |
| `ParityV3UITests` + B1, 17 Pro, English (`final-A1-pro`, `final-active-pro`, `final-b1k3-pro`, `final-k2-pro`) | 15 distinct tests, all passed. The first attempt had 2 failures. K3 notifications: the deleted partner's rows were below the first page after the regression suites added many notifications, so the test now scrolls (test-only change). B1 My Location produced no fix: the simulator's simulated location was stale after the A1 uninstall; after `simctl location set` it passed. Both re-ran and passed |
| Same, Arabic RTL (`final-rtl-pro`, `final-rtl-k2-pro`) | C, K2, K3, F2, M2: 5/5 passed |
| Same, iPhone SE, Accessibility-L (`final-axl-se`, `-k3`, `-k2`) | C, F2, K2, K3, K4, M2: 6/6 passed (K3 re-run after the same test-only scroll fix) |
| Regression batch 1, 17 Pro: `AuthBoundaryUITests`, `AuthRuleMatrixUITests`, `LocationBoundaryUITests`, `SessionNetworkTests` | **26 executed: 22 passed, 0 failed, 4 skipped** (pre-existing quarantined legacy fixtures) |
| Regression batch 2, 17 Pro: `ChatNetworkBoundaryUITests`, `MatchStateMatrixUITests`, `HelpSettingsBoundaryUITests`, `CarezaarUITests`, `StartupGateUITests` | **38 executed: 28 passed, 1 failed, 9 skipped** (env- or fixture-gated or quarantined). The failure, `ChatNetworkBoundaryUITests.testOwnedChatOfflinePreflightKeepsExactDraftThenNativeRetrySendsOnce`, is pre-existing: it fails identically at unmodified HEAD `17bbeda` (`logs/HEAD-chat-preflight.summary.txt`). It expects "Cannot communicate with server. Check your internet connection and try again.", but the app never uses `error_check_connection` |

The last source change (a test-harness change making the C4 test write one credentials file per run) was compiled but not re-run, because each C4 run creates a real account.

## Manual and cross-role workflows exercised (through XCUITest on the real app and live server)

- **Client (Ava):** signed in; Messages list refresh; conversation with an active, then unmatched, caregiver; conversation with a deleted caregiver; Notifications; Profile menu; Preferences location step (read-only); renewal error and Connection Problem flows.
- **Caregiver (Ben):** writes a message while the client's list is open (K1); after the client unmatches, his own side of the conversation is closed (K2).
- **Caregiver (Cora):** deleted through `DELETE users?reason_id=1` while having a match and conversation with the client. Seen by the client as "Deleted Account" in the list, header and notifications, with the conversation closed (K3).
- **Sign-up:** new client to the code screen with a forced code-send failure, then Re-send and the real code (C4). Unfinished accounts resumed from Sign In: client with no profile, client with an existing profile, and caregiver with no profile on the SE. All reached Main (B1).
- **Visual review:** every screenshot listed above was inspected. RTL mirroring of the notes and errors is correct. Keyboard and small-screen layouts are usable (SE runs). Dynamic Type Accessibility-L is legible with no overlap.
- **VoiceOver labels (asserted):** the consent tick-box speaks the whole managed sentence; "Terms of Use" and "Privacy Policy" are links (plus named accessibility actions); the closed-chat note is a combined element; "My location" and the refusal note are labelled. A full spoken VoiceOver walk-through was not performed by a person; instead Apple's `performAccessibilityAudit` (element descriptions, contrast, Dynamic Type, hit regions, traits) ran on the physical iPhone over Create Account (with errors), Messages, a closed conversation and Profile: **no element lacks a VoiceOver description** (details below).

## Regressions and test migrations

- No product regression was found. The existing suites that encoded superseded behaviour were adapted to the PDF contract, not weakened:
  - Continue gating → errors or the review dialog (`AuthBoundaryUITests`, `AuthRuleMatrixUITests`).
  - License sheet → in-app viewer.
  - Automatic or optional location → F1/F3 (`LocationBoundaryUITests`, `SignupTests`).
  - Pop-up on inactive send → closed composer (`MatchStateMatrixUITests`).
  - Disabled empty Send → K4 (`ChatNetworkBoundaryUITests`).
  - Resumed requests after Retry and kept session on 5xx → Q1/Q2 (`SessionTests`, `ChatSettingsTests`).
- Superseded October 13 rules, documented in `IOS-FUNCTIONAL-PARITY-MATRIX.md`: continuing without a location, and keeping the session after a server error during renewal.

## Backend issues and limitations

- **C2:** no Terms of Use or Privacy Policy document exists on the server, API, website or APK. The URLs are empty until the client provides them.
- **M1:** the new Android header images are unavailable.
- **B1 (server):** anonymous `users/profile` returns HTTP 500 when no `Accept-Language` header is sent (the earlier probe hit this). The app always sends it, so the app is unaffected.
- **Timing:** the server stores times to the minute and the simulator shows local time. K1 timing was measured in the UI only (marker visible after 11 s with a 10 s timer).
- **Debug-only hooks added** (compiled out of Release, like the existing ones): `--qa-fail-once <METHOD> <path>` and `--qa-refresh-http-error`.
- **Not verified:** document scroll and zoom with real content (C2: no documents exist); Android side-by-side (no current APK); a spoken VoiceOver session by a person (the automated audit ran instead).

## Accounts and resources

- **Created and deleted:** all disposable accounts are logged in `CareerZar React App/qa/created-accounts.txt` with the tag "(iOS parity v3; disposable)". Deleted via `DELETE users?reason_id=1`, with re-login refused: client A, caregivers B and C (C as the K3 fixture), unfinished caregiver U and client V (both completed by the B1 runs), the final C4 account, and the lead's original B1 fixture (completed by the B1 client run).
- **Not deletable:**
  - C4 run 1: registered but never verified; its inbox token was not kept.
  - C4 run 2: verified, no profile; its password was not retained, because XCTest redacts secure text and the next run overwrote the credentials file (now fixed in the test).
- **Unintended deletion:** the B1 fixture file was replaced mid-session by a new "(web parity v4)" unfinished account, and my cleanup deleted it. It is annotated in the log, and a replacement unfinished client was staged with the same script into the same `probe/b1-account.json` (login answers 409, role client) and kept for retest.
- **Simulators:** "PV3 iPhone 17 Pro" and "PV3 iPhone SE3" were created for this run and removed at the end. No other simulator was touched.
