# Sato release candidate workflow

`release.sh` prepares a Developer ID-signed, Apple-notarized, Sparkle-signed
release candidate. It does not build through the terminal and does not publish
anything.

## 1. Set the version

For v1.2.0, these values must match in both the app target's Xcode build
settings and `leanring-buddy/Info.plist` before archiving:

```xml
<key>CFBundleShortVersionString</key>
<string>1.2.0</string>
<key>CFBundleVersion</key>
<string>10200</string>
```

The build number is derived as `major + two-digit minor + two-digit patch`.
The repository is already configured for v1.2.0 (10200).

## 2. Archive and export in Xcode

1. Open `leanring-buddy.xcodeproj`.
2. Select the `leanring-buddy` scheme and `Any Mac`.
3. Choose Product → Archive.
4. In Organizer, choose Distribute App → Developer ID → Export.
5. Export the signed app as `Sato.app`.

Do not run `xcodebuild` from Terminal. Terminal builds invalidate the app's TCC
permissions in this project.

## 3. Prepare the candidate

```bash
brew install create-dmg

# The default Keychain profile is "sato-notarization".
./scripts/release.sh 1.2.0 ~/Desktop/Sato.app

# To use a different notary profile or Sparkle tool location:
SATO_NOTARY_PROFILE=my-profile \
SPARKLE_BIN=/path/to/Sparkle/bin \
./scripts/release.sh 1.2.0 ~/Desktop/Sato.app
```

The script:

1. Confirms the exported app has the requested version and build number.
2. Verifies its Developer ID signature.
3. Notarizes and staples the app.
4. Creates `Sato-<version>.dmg`.
5. Notarizes, staples, and Gatekeeper-validates the DMG.
6. Signs the final DMG with Sparkle EdDSA.
7. Generates and validates a staged `appcast.xml`.
8. Writes release notes and all artifacts under
   `build/release-candidate-v<version>/`.

It never creates a git tag, GitHub Release, or website commit. Those actions
happen only after the candidate has been reviewed and publication is explicitly
approved.

## Prerequisites

- macOS with Xcode and the Developer ID certificate installed
- `create-dmg`
- notarization credentials stored in Keychain:

```bash
xcrun notarytool store-credentials "sato-notarization" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "UP52GQK38V" \
  --password "YOUR_APP_SPECIFIC_PASSWORD"
```

- Sparkle's `sign_update` and `generate_appcast` tools, normally downloaded by
  Swift Package Manager after an Xcode build

## Publication checklist

After explicit approval:

1. Tag the exact reviewed source commit as `v<version>`.
2. Create a GitHub Release in `vitalune/sato` and upload the DMG.
3. Copy the staged appcast to `sato-site/public/appcast.xml`.
4. Deploy `sato-site`.
5. Confirm `https://sato.host/appcast.xml` returns the new version and that the
   DMG URL, file length, and EdDSA signature match the candidate.
