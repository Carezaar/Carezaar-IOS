# Native iOS review status — 20 October 2026

This file supersedes the status sections of earlier handoffs. Nothing here has been released to TestFlight or the App Store.

## Build and tests

- All 172 unit tests in this commit pass (`CarezaarTests`, iOS 26.5 simulator).
- Debug build-for-testing and Release build succeed. Warnings: Xcode's App Intents metadata notice, and one unused local in a UI test.
- QA launch arguments (`Navigation/QALaunch.swift`) are compiled only in Debug; the Release binary contains none of them.
- The Release bundle's built-in images are the logo, rooms, a desk, abstract shapes and the hands-only Messages header. No people or faces (see `ARTWORK_POLICY.md`).

## Changes in this review

- **No sign-out when a request is refused on a valid session.** The backend answers 403 both for an expired token and for "not allowed here". A 403 that names a field is a normal error straight away. Otherwise the app renews the token once; if the renewed request is refused again, it is reported as "You can't do this right now." and the user stays signed in, as on the web (owner decision for the other role's screen, P16-015). Only a refused identity check (`auth/info`) after a renewal still ends the session (`Core/Networking/APIClient.swift`, `APIError.forbidden`, unit tests in `NetworkTests` and `SessionTests`).
- **An unreadable photo says so.** A photo chosen in the gallery that could not be loaded or decoded did nothing; the app now shows the managed general error and keeps the form (`Features/Auth/ProfileFormView.swift`). On the simulator the system itself refuses the corrupt test file and the picker keeps the truncated one, so this branch is a safeguard that no test reached.
- **Offline pull-to-refresh on My Matches says so.** A failed refresh kept the list but gave no sign; it now shows the managed "Cannot communicate with server." message while keeping the list (`Features/Main/MainView.swift`). Checked on a physical iPhone with mobile data off and on.
- **FAQ in right-to-left languages.** In Farsi the category strip is wider than the screen and opened at its far end, so the selected "All" chip was off-screen. The strip now scrolls "All" into view when the screen opens and when the language changes (`Features/Settings/SettingsScreens.swift`).
- Earlier in this review: agreement feedback, date-of-birth serialization, pagination cancellation, managed request-cancellation wording, semantic Back labels, notification read state (kept unread when marking seen fails, with an explicit retry), and accessibility layout fixes. The Terms of Use and Privacy Policy viewer reads `CarezaarTermsOfUseURL` / `CarezaarPrivacyPolicyURL` from `Info.plist` (build settings `CAREZAAR_TERMS_OF_USE_URL`, `CAREZAAR_PRIVACY_POLICY_URL`) and these now point at the client's documents (`https://new.carezaar.com/terms_of_use.pdf`, `https://new.carezaar.com/privacy_policy.pdf`), opened in the in-app viewer with a title bar, scrolling and zoom. The server is slow to send them (5–37 s measured), so the viewer shows its loading indicator meanwhile.

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
| Physical iPhone 15 (iOS 26.5.2), both roles: camera prompt, Don't Allow, Allow with capture/Retake/crop/Cancel, Camera off and on again in Settings, notification banner; Mail hand-off from Help Center; Siri and a real incoming phone call during an unsaved edit; FAQ, language and splash smoke | Pass (nothing uploaded; camera images not kept) |
| Physical iPhone 15, owner at the phone: mobile data off and on during use | Pass (list kept, managed message, recovery) |
| Owner-approved test data: QA support issue submitted once and listed once; a deleted partner shown as "Deleted Account" with the chat closed; another pair's chat refused with nothing shown or sent; quitting mid-sign-up creates nothing | Pass |
| Slow start-up, failed save then retry, photo add/remove, interrupted photo picker, launch timings, favourite while offline, caregiver saved location | Pass, both sizes and roles where the case applies |
| Unfinished sign-up resumes at the profile step; a bio edited by the caregiver appears for the client (then removed); a client with no gender/experience/role preference shows none | Pass on both sizes (preferences cleared for the run and restored, no differences) |
| Sort changed while every response is slowed: the sort control is blocked while a page loads and the list ends in the last choice's order | Pass on both sizes |
| Photos: corrupt and truncated files refused safely, an EXIF-rotated image saved upright and a landscape image cropped square without stretching (checked on the saved server photo), an upload that fails offline then saves once on retry, and the Camera choice on the simulator (which reports a camera) | Pass, both sizes and roles; the photo is removed again |
| A chat notification whose target is missing: Show dismisses, nothing opened, no private data | Pass, both sizes and roles |
| Both simulators at once: client on the Pro Max and caregiver on the SE chat live in the owned pair's chat | Pass (47 s overlap) |
| Full client journey (request, Accept, chat both ways, Unmatch, ended History row) | Pass on both sizes |
| Other role's preferences screen: nothing shown or written, session kept | Pass, both sizes and roles |
| Create Account: the two links open the client's server PDFs in the titled viewer | Pass on both sizes |

## Not yet accepted

- **Final FAQ**: the client's final FAQ has 18 questions; the server (`base/faqs`, managed with translations) still serves the earlier 14. It is entered in the server's content admin; the app shows whatever the server sends.
- **Apple's strict accessibility audit** still fails on every screen set. Measured on the audited screenshots, the grey text it flags is #595959 on white (about 7:1) and only white on the brand blue is 4.03:1 (bold ≥ 14 pt, WCAG large text). Proposed to the client: #0071EC, the nearest shade of the brand blue at 4.59:1; not applied until the client confirms. The other findings are the intentional one-line message preview and notification rows marked "partly unsupported" for Dynamic Type although they scale. A spoken VoiceOver review by a person has not been done.
- **Physical device**: a true Wi-Fi-to-mobile handover was not possible (the test iPhone was not on Wi-Fi). The app has no remote push (the backend has no iOS push channel); its foreground notification banner works on the device.
- **Android reference**: the client's release APK runs on an Android emulator until sign-in; after a successful sign-in it ends its own process, so signed-in Android behaviour could not be observed side by side (needs a physical Android phone). Signed-out screens were compared.
- **VoiceOver**: a spoken walk-through by a person on a device has not been done.
- **Built-in artwork**: by the owner's instruction, the parity items asking to restore people images (A1, F1, F2, G1, M1, M2) are intentionally not implemented. User-uploaded photos are unaffected.
