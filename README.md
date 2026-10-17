# Carezaar iOS

The native iOS app for Carezaar, written in SwiftUI. It connects families who need care with caregivers, and runs against the live Carezaar API. Its behaviour follows the Android app, and its design follows the Figma file.

## Features

- **Accounts**
  - Sign up as a client or as a caregiver, using email and password with an emailed verification code.
  - Sign in, forgot password, change password and delete account. Sign In requires both fields and sends the entered values to the backend for validation. Signing in to an account whose sign-up was never finished shows the server's message and resumes sign-up at the profile step.
  - Create Account checks every field when Continue is tapped and shows each problem under its field. The consent sentence links to the Terms of Use and Privacy Policy, shown in an in-app viewer; their addresses are set in `LegalDocumentConfiguration` (`Core/Networking/APIConfiguration.swift`) and are empty until the client supplies the documents.
- **Onboarding**
  - A preferences wizard: needs, availability, location and languages. The location is never filled in automatically: the map opens on the whole country (USA) and uses the phone's position only after My Location. Continuing without a location shows the managed "Please select a location to continue.", and refused location access is explained.
  - A profile with a photo, taken with the camera or picked from the gallery, then cropped.
- **Discovery:** browse and sort profiles, add favourites, and open profile details.
- **Matches**
  - All match actions happen on the profile page:
    - send a request, with an optional introduction;
    - withdraw a pending request;
    - accept or reject a received request;
    - unmatch an active match.
  - Every action asks for confirmation.
  - Accepting a request opens the "It's a Match!" screen.
  - The Matches list shows cards; tapping a card opens the profile.
- **Messages:** one-to-one chat between matched users. The conversation list refreshes every 10 seconds while it is on screen. A conversation with a former match or a deleted account is closed with a note above the disabled typing box, and deleted accounts are shown as "Deleted Account".
- **Notifications:** an in-app list. Match notifications open the related profile or the "It's a Match!" screen. The app asks for notification permission as soon as it opens and carries on whatever the answer.
- **Settings:** language, Help Center (FAQ, contact, Delete Account) and Report an Issue (on the Profile page).
- **Languages:** the language list and translations come from the backend. The verified list includes English, Hindi, Chinese, Spanish, French, Russian, Arabic and Persian, with right-to-left layout for Arabic and Persian.

## Requirements

| | |
|---|---|
| Xcode | 16 or later (last built with Xcode 26.6) |
| Deployment target | iOS 17.0 |
| Devices | iPhone, portrait |
| Swift | Swift 5 language mode |
| Dependencies | None; no Swift packages or CocoaPods |

## Build and run

1. Open `Carezaar.xcodeproj`.
2. Select the **Carezaar** scheme and an iPhone simulator.
3. Run.

To run on a device:
- set your development team under *Signing & Capabilities*;
- if needed, change the bundle identifier (currently `com.aariz51.carezaar`) to one your team owns.

To build from the command line:

```sh
xcodebuild -project Carezaar.xcodeproj -scheme Carezaar \
  -sdk iphonesimulator -configuration Debug \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

## Configuration

**API**
- The base URL is `https://new.carezaar.com/api/`, set in `Core/Networking/APIConfiguration.swift`.
- Debug builds can point at another server through the `CAREZAAR_API_BASE_URL` environment variable in the scheme. Release builds always use production.

**Authentication**
- `auth/login` returns an access token and a refresh token, which are stored in the Keychain (`Core/Session/TokenStore.swift`).
- APIClient uses one shared session renewal when the server rejects the access token. If the server answers the renewal with any HTTP error, the person is signed out. Only when the server cannot be reached does the managed Connection Problem/Retry window appear; the request that failed shows its own error and is not repeated, and a successful Retry renews the session and closes the window. A malformed success answer or a local Keychain failure keeps the credentials and shows the managed error. A known-refused mutation is distinguished from an uncertain write, and late results cannot affect another account.

**Localisation**
- UI text is served by the backend, not bundled. `GET base/contents` returns every label by slug and language (`Core/Storage/Localization.swift`).
- Missing translations fall back to English.

**Permissions** (Info.plist keys generated from build settings):
- camera, for profile photos;
- photo library, for profile photos;
- location when in use, for nearby matches.

The project contains no API keys, secrets or signing credentials.

## Project structure

| Folder | Contents |
|---|---|
| `Core/Networking` | `APIClient` (an actor):<br>• response envelope decoding;<br>• `Accept-Language` on every request;<br>• single-flight token refresh;<br>• 60-second timeouts.<br>Also `Endpoint` and `APIError`. |
| `Core/Session` | `SessionManager`, Keychain tokens (`TokenStore`), the 30-second notification poll, device fields, UTC to local time |
| `Core/Storage` | Base-table cache (`BaseDataStore`), server-driven copy (`Localization`) |
| `Core/Validation` | Password, email and verification-code rules |
| `Services` | One type per API group (`AuthService`, `UserService`, `ClientService`, `CaregiverService`, `BaseService`) |
| `Models` | Wire models. Identity fields are strict; optional fields fall back to defaults. |
| `Navigation` | `Route` (identifiers match the Android app's navigation), `AppRouter` and Debug-only launch arguments |
| `Features` | Screens by area: `Auth`, `Onboarding`, `Main`, `Settings`, and `DesignSystem` (theme and shared components) |
| `Design`, `Components`, `Screens`, `Resources/Scenes` | Renderer for the screens built directly from Figma frames: Splash, Intro, Sign In, Create Account and the preferences intro |
| `scripts/prune-bundle.py` | Release build phase that strips design-review assets from the shipped app |

## Debug-only tools

- `--design-catalog` (or a shake) opens a catalogue of the Figma-derived screens for design review.
- `QALaunch.swift` lists launch arguments for development and screen capture, such as signing in or opening a given screen.

The Release build compiles none of these and ships none of their assets.

## Known limitations

- Missing managed translations use coherent English fallback copy. The QA reports identify which language controls and flows were actually verified.
- Notifications are polled every 30 seconds while the app is open. There is no remote push (APNs).
- The app depends on the live backend for all content, including UI text. Some backend endpoints are slow on first load, so the app caches base tables locally.
