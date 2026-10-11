# Building and distributing LimitFuel

## Local build

With Xcode or its Command Line Tools installed, run `cd app && ./build.sh --local`.
This creates a universal Intel/Apple Silicon app with an ad-hoc signature. Open
`app/build/LimitFuel.app` manually. No Apple Developer or App Store Connect record
is needed for local development.

## Direct distribution: Developer ID and notarization

The release scripts contain workflow logic and public certificate/profile names,
so they belong in Git. Passwords, private keys and local configuration do not.
Do not copy TeleCRM's environment file; its Electron entitlements are also specific
to that app. This native Swift app uses hardened runtime without Electron exceptions.

1. Use an Apple Developer Program team with a **Developer ID Application** certificate
   and its private key installed in your login Keychain. The default signing identity
   is `Developer ID Application: Innolope LLC (MQD26CY5MA)`; override `DEVELOPER_ID`
   for a different team.
2. Store notarization credentials in Keychain once with the interactive command
   `xcrun notarytool store-credentials LimitFuel`. Follow its prompts rather than
   putting a password in shell history or a tracked file. `NOTARY_PROFILE` overrides
   the public profile name; it is not a password.
3. From a clean checkout, run `cd app && ./build.sh`. This signs with Developer ID,
   hardened runtime and a secure timestamp, and records source provenance inside
   the signed app. It does not launch the app.
4. Run `./create_dmg.sh` explicitly to upload the signed DMG to Apple's notary service.
   This is a submission action, not an offline build check. It signs, notarizes,
   staples, validates and runs Gatekeeper assessment before publishing
   `app/dist/LimitFuel-<version>-<build>/LimitFuel-Installer.dmg` plus a hash/provenance
   record. No App Store Connect app listing is needed for this path.

Increment version/build in `app/Info.plist` before a new release. Packaging refuses
an existing release directory, dirty source provenance, a changed commit, an ad-hoc
app, another team's signature or missing hardened runtime. Build and packaging
share a lock. After an interrupted process, confirm no release/build process remains
before manually removing a stale `app/.release-lock` directory.

Notarization has a 20-minute total deadline (`NOTARY_TIMEOUT_SECONDS`, integer
1–3600); other external commands are also bounded. A timeout or transport error may
leave a submission processing at Apple. There is no automatic resubmission. Inspect
`xcrun notarytool history --keychain-profile LimitFuel`, then use
`xcrun notarytool info <submission-id> --keychain-profile LimitFuel` and
`xcrun notarytool log <submission-id> --keychain-profile LimitFuel` before deciding
whether to retry. Failed runs do not publish a ready installer. A successful offline
fixture test or local build does not prove actual signing/notarization acceptance.

Local `.env*`, `*.local.env`, signing keys/certificates, provisioning profiles and
generated build/release output are ignored. This is a backstop: inspect the staged
diff and tracked filenames before pushing; ignore rules do not untrack existing files.

## Mac App Store: separate distribution work

App Store distribution requires an Apple Developer Program membership, an explicit
App ID with a bundle identifier owned by your team, and a macOS app record in
App Store Connect. LimitFuel currently retains upstream's `com.claude.usagebar` for
local settings compatibility. Do not assume that identifier is available to Innolope;
a Store variant needs an owned identifier and an explicit settings migration plan.

The current app is **not App Store ready**. Store macOS apps must be sandboxed and
self-contained. Reading Chrome's cookie database/Keychain and executing an external
Codex app-server need a viable sandbox design and provider authorization review.
User-granted file access alone does not settle every subprocess/Keychain constraint.
Store-specific update behavior also needs review. Removing Accessibility permission
does not resolve those distribution constraints.

Once that design works, add the App Sandbox capabilities/entitlements and Store
provisioning/signing configuration, build a signed App Store installer package and
upload with Xcode/Transporter. Complete the app name/category, description, screenshots,
support and privacy-policy URLs, privacy disclosures, age rating, export-compliance
answers and review instructions/demo access. Confirm rights to the third-party
services and branding. Apple review acceptance remains a separate step.

Apple references: [Developer ID](https://developer.apple.com/developer-id/),
[macOS review requirements](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility),
[App Store Connect app record](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/),
[Mac software packaging](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).
