# Native iOS review status — 19 October 2026

This file supersedes the status sections of earlier handoffs. Nothing here has been released to TestFlight or the App Store.

## Build and tests

- All 171 unit tests pass (`CarezaarTests`, iPhone 17 Pro Max simulator, iOS 26.5).
- Debug build-for-testing and Release build succeed. The only Release warning is Xcode's App Intents metadata notice.
- QA launch arguments (`Navigation/QALaunch.swift`) are compiled only in Debug; the Release binary contains none of them.
- The Release bundle's built-in images are the logo, rooms, a desk, abstract shapes and the hands-only Messages header. No people or faces (see `ARTWORK_POLICY.md`).

## Changes in this review

Agreement feedback, date-of-birth serialization, pagination cancellation, managed request-cancellation wording, semantic Back labels, notification read state (kept unread when marking seen fails, with an explicit retry), and accessibility layout fixes. The Terms of Use and Privacy Policy viewer reads `CarezaarTermsOfUseURL` / `CarezaarPrivacyPolicyURL` from `Info.plist` (build settings `CAREZAAR_TERMS_OF_USE_URL`, `CAREZAAR_PRIVACY_POLICY_URL`) and shows the supplied PDFs until those URLs are set.

UI tests: the FAQ tests now read the live FAQ answer instead of a hard-coded sentence, because the FAQ is edited in the admin panel.

## Verified on simulators (production API, owned QA client and caregiver)

Match lifecycle, both phone sizes (iPhone 17 Pro Max and iPhone SE 3rd generation):

| Scenario | SE | Pro Max |
|---|---|---|
| Caregiver request with introduction, then Cancel | Pass | Pass |
| Caregiver request, client Accept, chat both ways, client Unmatch | Pass | Request, accept and chat reached; the test's "read older messages" step needs more history than fits on the tall screen |
| Client request, caregiver Accept, caregiver Unmatch | Pass | Pass |
| Blank client request, caregiver Reject | Pass | Pass |

Both roles on both sizes: role walkthroughs (tabs, sort, details, lists, forms, French and Arabic) and the screen sweep pass. Help/settings, partner navigation and the remaining suites are being rerun; their individual results are recorded in the QA evidence.

## Not yet accepted

- **Terms of Use / Privacy Policy URLs** from the client.
- **Apple's strict accessibility audit** still reports findings: white labels on the brand blue (bold ≥ 14 pt, which WCAG treats as large text; the brand colour is the owner's decision), an intentional one-line message preview, and lower notification rows the audit marks as partly unsupported for Dynamic Type although they scale at the largest size. A spoken VoiceOver review by a person has not been done.
- **Physical device**: camera, cellular and other hardware-only checks were not possible on this machine.
- **Built-in artwork**: by the owner's instruction, the parity items asking to restore people images (A1, F1, F2, G1, M1, M2) are intentionally not implemented. User-uploaded photos are unaffected.
