# Native iOS review status — 20 October 2026

This file supersedes the status sections of earlier handoffs. Nothing here has been released to TestFlight or the App Store.

## Build and tests

- All 171 unit tests pass (`CarezaarTests`, iPhone 17 Pro Max simulator, iOS 26.5).
- Debug build-for-testing and Release build succeed. Warnings: Xcode's App Intents metadata notice, and one unused local in a UI test.
- QA launch arguments (`Navigation/QALaunch.swift`) are compiled only in Debug; the Release binary contains none of them.
- The Release bundle's built-in images are the logo, rooms, a desk, abstract shapes and the hands-only Messages header. No people or faces (see `ARTWORK_POLICY.md`).

## Changes in this review

- **FAQ in right-to-left languages.** In Farsi the category strip is wider than the screen and opened at its far end, so the selected "All" chip was off-screen. The strip now scrolls "All" into view when the screen opens and when the language changes (`Features/Settings/SettingsScreens.swift`).
- Earlier in this review: agreement feedback, date-of-birth serialization, pagination cancellation, managed request-cancellation wording, semantic Back labels, notification read state (kept unread when marking seen fails, with an explicit retry), and accessibility layout fixes. The Terms of Use and Privacy Policy viewer reads `CarezaarTermsOfUseURL` / `CarezaarPrivacyPolicyURL` from `Info.plist` (build settings `CAREZAAR_TERMS_OF_USE_URL`, `CAREZAAR_PRIVACY_POLICY_URL`) and shows the supplied PDFs until those URLs are set.

UI test corrections (each one followed a recorded failure and was retested):

- The app's own "New Notification(s)" system banner covers the top of the screen after sign-in; Partner navigation and the managed-language test wait for it to clear before hit-testing.
- Profile fields: wait for the date-of-birth popover to close before using the gender menu.
- Small screen: the logout row must be fully inside the list, not just inside the window; the French menu and the Pro Max chat transcript are scrolled with short drags so a row is not skipped between samples.
- Chat offline send: the app sends without a pre-send read, and the transport retries only failures that never reached the server (one attempt plus three). The test now asserts that design: four refused attempts, nothing stored, the draft kept, one explicit retry that is stored once. A chat-read count was dropped because an open chat re-reads itself every 10 seconds.
- Match confirmation buttons and the empty-draft Send follow the current Android parity (both actions labelled "Cancel"; Send stays tappable with an empty draft and explains).
- FAQ tests read the live FAQ answer, because the FAQ is edited in the admin panel.

## Verified on simulators (production API, owned QA client and caregiver)

Devices: iPhone 17 Pro Max ("Pro Max") and iPhone SE 3rd generation ("SE"), both roles unless a test is role-specific.

| Area | Result |
|---|---|
| Sign-up → OTP → profile → wizard → photo → password change → forgot password (wrong code first) → delete account | Pass, client and caregiver on both sizes (4 new disposable accounts) |
| Notification and location permission: fresh allow/deny, change in Settings, revoke and re-enable | Pass, 34 runs |
| Match lifecycle: request with/without introduction, cancel, accept, reject, unmatch, reciprocal request | Pass on both sizes; on Pro Max the caregiver-request/client-accept/chat/client-unmatch run completed every step but its final history check could not single out the ended match among many earlier ones |
| Chat: offline send, slow send, replies, unread, incoming while reading older messages, unsent drafts | Pass |
| Session: refresh, revoked session, offline restart, logout | Pass |
| Languages: all 8 server languages including Farsi, French/Arabic tab captions at the largest text size | Pass |
| Startup cache, help/settings, partner navigation, favourites, preferences, large HEIC photo | Pass |
| Physical iPhone 15 (iOS 26.5.2), both roles: camera prompt, Don't Allow, Allow with capture/Retake/crop/Cancel, Camera off and on again in Settings, notification banner; FAQ, language and splash smoke | Pass (nothing uploaded; camera images not kept) |

## Not yet accepted

- **Terms of Use / Privacy Policy URLs** from the client.
- **Apple's strict accessibility audit** still fails on every screen set. Measured on the audited screenshots, the grey text it flags is #595959 on white (about 7:1) and only white on the brand blue is 4.03:1 (bold ≥ 14 pt, WCAG large text; the brand colour is the owner's decision). The other findings are the intentional one-line message preview and notification rows marked "partly unsupported" for Dynamic Type although they scale. A spoken VoiceOver review by a person has not been done.
- **Physical device**: switching Wi-Fi/cellular during use and a real incoming call still need a person at the iPhone. The app has no remote push (the backend has no iOS push channel); its foreground notification banner works on the device.
- **Built-in artwork**: by the owner's instruction, the parity items asking to restore people images (A1, F1, F2, G1, M1, M2) are intentionally not implemented. User-uploaded photos are unaffected.
