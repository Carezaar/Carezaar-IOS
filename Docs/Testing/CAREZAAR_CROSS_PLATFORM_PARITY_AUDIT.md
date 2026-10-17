# Carezaar cross-platform parity audit (web v4.0 and iOS v3.0)

**Date:** 17 October 2026

**Source documents** (both prepared by Mohammad Mostafa Shahraki, dated 16 October 2026, 10 pages each):

| Document | Version | Governs | Items to change | Accepted differences |
|---|---|---|---|---|
| `Carezaar - Web and Android Parity Review v4.0.pdf` | 4.0 | Web app | 19 | 3 |
| `Carezaar - iOS and Android Parity Review v3.0.pdf` | 3.0 | iOS app | 17 | 0 |

Each PDF was read in full. Text was extracted with `pdftotext -layout`; the only embedded image is the cover logo. Each item keeps the reviewer's own reference code, prefixed here with the platform: W- for web, I- for iOS.

## Android reference used

- The two reviews, which state the Android behaviour for every item.
- The live managed texts (`GET base/contents`, 17 October 2026). Every text quoted by the reviews exists there.
- The live API (`https://new.carezaar.com/api/`, OpenAPI at `/openapi`).
- `Carezaar v1_0_0 2026-09-21 10-00.apk`, decompiled with jadx 1.5.6. **This build predates the 13 and 15 October Android update the reviews compare against.** None of the new texts or behaviours are in it.
- **No Kotlin source was available; none was reviewed.**

## Status legend

- **PASS:** verified on the running app with evidence.
- **FAIL:** reproduced and not resolved.
- **BLOCKED:** needs something outside the code.
- **NOT APPLICABLE:** genuinely does not apply.

---

## Web (review v4.0)

Details, code locations and evidence: `CareerZar React App/docs/WEB-ANDROID-FUNCTIONAL-PARITY.md`. Test log: `CareerZar React App/WEB_PARITY_TEST_EXECUTION_REPORT.md`.

| Audit ID | Page | Original issue (web today) | Expected (Android) | Status | Retest (final build) |
|---|---|---|---|---|---|
| W-A1 | 4 | Site covered by an explanation until notifications are allowed | Ask as the app opens; carry on either way | PASS | pass (allowed and refused) |
| W-B1 | 4 | Server's message as an error, stuck on Sign In | Show the message, go to the profile step | PASS | pass (real 409 account) |
| W-C1 | 5 | Sign-up progress kept per browser session | Accepted difference | NOT APPLICABLE (agreed) | — |
| W-C2 | 5 | Continue disabled, one problem at a time, English-only wording | Continue active; every field's problem at once, managed texts | PASS | pass (3 browsers, 2 layouts) |
| W-C3 | 5 | "I accept the license agreement", empty window | Terms of Use / Privacy Policy sentence; documents open in the app, scrollable and zoomable | **BLOCKED** (UI done and tested; no documents exist) | UI pass |
| W-C4 | 5 | Own confirmation sentence under a missing text name | `signup_credentials_confirm_dialog_description` | PASS | pass |
| W-C5 | 5 | Code not sent → stuck; account already exists | Code screen opens; code can be requested again | PASS | pass |
| W-E1 | 5 | JPEG/PNG/WebP up to 10 MB | Accepted difference | NOT APPLICABLE (agreed) | — |
| W-F1 | 6 | Locates the visitor as the map opens | Whole country; location only on My Location | PASS | pass (0 / 1 geolocation calls) |
| W-F2 | 6 | Nothing when location is refused | "Allow location access to use your current location." | PASS | pass |
| W-F3 | 6 | Hint instead of the message | "Please select a location to continue." | PASS | pass |
| W-F4 | 6 | Any length, decimals rounded | Digits only, up to 6 | PASS | pass |
| W-K1 | 7 | List updates only when reopened | Updates every 10 s while open | PASS | pass (≈9 s, cross-role) |
| W-K2 | 7 | Typing box open; pop-up on send | Box off, grey send, note above | PASS | pass (3 browsers) |
| W-K3 | 7 | Empty name, open for typing | "Deleted Account" everywhere; closed with note | PASS | pass (real deleted account) |
| W-K4 | 7 | Send disabled, no explanation | "Please type a message first." | PASS | pass (3 browsers) |
| W-M1 | 8 | My Matches care photos | Phone with a conversation; everyday care scenes | **BLOCKED** (images not available) | — |
| W-M2 | 8 | "Update your account password" | "Change your current password" | PASS | pass |
| W-O1 | 8 | Stays signed in after a password change | Signed out, back to the start | PASS | pass (also answer-lost case) |
| W-Q1 | 9 | Connection Problem for a server error; stays signed in | Renewal error → signed out; window only when unreachable | PASS | pass (browser + unit) |
| W-Q2 | 9 | Waiting requests carry on after Retry | Window closes; failed requests show their error, not repeated | PASS | pass (browser + unit) |
| W-Q3 | 9 | Photo read through the site's address | Accepted difference | NOT APPLICABLE (agreed) | — |

**Web totals: 19 items to change, 17 PASS, 2 BLOCKED, 0 FAIL. 3 accepted differences (no change).**

---

## iOS (review v3.0)

Details, code locations and evidence: `Carezaar-IOS/Docs/Testing/IOS-ANDROID-FUNCTIONAL-PARITY.md`. Test log: `Carezaar-IOS/Docs/Testing/IOS_PARITY_TEST_EXECUTION_REPORT.md`. Evidence: `test-evidence/ios-parity-v3/`.

Testing ran on the iOS Simulator (iOS 26.5) on two devices: iPhone 17 Pro and iPhone SE (3rd generation). It covered English, Arabic (RTL) and Accessibility-L Dynamic Type, against the live server with real accounts in both roles.

| Audit ID | Page | Original issue (iOS today) | Expected (Android) | Status | Retest (final source) |
|---|---|---|---|---|---|
| I-A1 | 4 | Asks for notifications only after sign-in | Ask at launch; carry on either way | PASS | pass (refused → app continues) |
| I-B1 | 4 | Server's message as an error, stuck on Sign In | Show the message; open the profile step | PASS | pass (client and caregiver, with and without a profile) |
| I-C1 | 5 | Continue disabled; one problem at a time; English-only wording | Continue active; all problems under their fields | PASS | pass (en, ar, AX-L) |
| I-C2 | 5 | Licence agreement with an empty window | Terms of Use / Privacy Policy sentence and in-app documents | **BLOCKED** (UI done: WKWebView viewer, scroll and pinch zoom; no documents exist) | UI pass |
| I-C3 | 5 | Own sentence under a missing text name | Managed confirmation sentence | PASS | pass |
| I-C4 | 5 | Code not sent → stuck | Code screen opens; Re-send available | PASS | pass (real send failure, then a real code) |
| I-F1 | 6 | Fills in the phone location by itself; world map | No auto-fill; whole-country map; My Location only on tap | PASS | pass |
| I-F2 | 6 | Nothing when access is refused | Managed refusal message | PASS | pass (Debug "denied" fixture; a live OS-prompt refusal was not automated) |
| I-F3 | 6 | Carries on, then opens the map on save | "Please select a location to continue." | PASS | pass |
| I-K1 | 7 | List updates only on pull or reopen | Every 10 s while open | PASS | pass (message from the other role in about 11 s; one timer) |
| I-K2 | 7 | Box open; pop-up on send | Box off, grey send, note | PASS | pass (both roles). On review, the send button was changed from faded blue to grey and rechecked |
| I-K3 | 7 | Empty name; open for typing | "Deleted Account" everywhere; closed with note | PASS | pass (real deleted account; list, header, notifications) |
| I-K4 | 7 | Send turned off when empty | "Please type a message first." | PASS | pass |
| I-M1 | 8 | Older empty-room pictures | Phone with a conversation; care scenes | **BLOCKED** (images not available) | — |
| I-M2 | 8 | "Update your account password" | "Change your current password" | PASS | pass |
| I-Q1 | 9 | Renewal error keeps the person signed in | Any HTTP error → signed out; window only when unreachable | PASS | pass (unit tests + real 404 on the simulator) |
| I-Q2 | 9 | Waiting requests carry on after Retry | Window closes; nothing replayed | PASS | pass (unit tests + simulator) |

**iOS totals: 17 items, 15 PASS, 2 BLOCKED, 0 FAIL.**

**iOS automated tests on the final source:**
- `CarezaarTests`: 157/157 pass (also re-run independently in review).
- Parity UI tests: 15 in English, 5 in Arabic, and 6 on the SE at Accessibility-L, all passed.
- Regression UI batches: 50 passed, 13 skipped (quarantined or fixture-gated) and 1 failed. The failure is pre-existing and fails identically on the unmodified previous commit (`testOwnedChatOfflinePreflightKeepsExactDraftThenNativeRetrySendsOnce` expects a text the app has never used).
- Debug and Release builds succeed with no new warnings.

---

## Both platforms compared with Android

The same Android behaviour was implemented independently on each platform. The two share:
- the same managed texts;
- the same 409 resume rule;
- the same `is_deleted` rule;
- the same renewal rules.

They differ only where the reviews accept platform differences:
- Web: notifications are asked on the first click (browsers require a user action); OpenStreetMap; browser camera.
- iOS: Apple Maps, the iOS photo picker, iOS alerts and the Keychain.

## Mandatory QA documents

- **QA document 1** (`You are acting as a Senior QA Engineer a`): the production test plan. `PRODUCTION_TEST_PLAN.md` already existed for the web and was extended with Phase 29 for this review. The iOS plan lives in `Carezaar-IOS/Docs/Testing/`.
- **QA document 2** (`You are acting as a Senior QA Engineer, .md`): executing that plan.
  - Web: suites A (78 pass, 1 N/A), B (69/69), ten-change (51/51) and gaps (10/10), plus the parity suites, all on the final build.
  - iOS: the unit target and the UI regression batches listed above.

## Remaining blockers (both platforms)

1. **Terms of Use and Privacy Policy documents** (W-C3, I-C2). The consent sentence, links and in-app viewer are built. The documents themselves are needed: either their addresses, or the files to bundle. Web: set `VITE_CAREZAAR_TERMS_URL` / `VITE_CAREZAAR_PRIVACY_URL`, and add the documents' origin to `frame-src` in `vercel.json`.
2. **Header pictures for Messages and Profile** (W-M1, I-M1). The two images from the current Android build are needed.
3. **Current Android build.** Supplying the build the reviews were made against (after 15 October) would let both teams check the remaining details against it directly.

## Backend notes

- `POST auth/login` answers 409 with `meta.role` for any unfinished sign-up: before the profile step, and after it until the client or caregiver record exists. Verified live on 17 October. No backend change is needed for B1.
- Deleted accounts come back with `is_deleted: true` and null names. The apps rely on this flag.
