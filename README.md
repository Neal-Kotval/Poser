# Poser

An iOS photography assistant built with SwiftUI, AVFoundation, Vision, and Core Motion.

## Run

Open `Poser.xcodeproj` in Xcode and run the Poser target on iOS 26 or later. For an iPhone build, sign in under Xcode → Settings → Accounts and select your development team for the Poser target. On a physical iPhone, scanning and capture use the device camera. In the simulator, Poser shows a labeled sample preview and lets you test the scan, guidance, and capture flow without camera hardware.

## MVP flow

1. Select a reference from Photos. Imported images are saved in an on-device inspiration library.
2. Scan the surroundings to rank the featured photo and saved references by scene structure, color, and light.
3. Poser analyzes image labels, saliency, and body landmarks on device where available.
4. Review a shot recipe with distance, phone height, tilt, framing, subject position, and light guidance. Full-body references can provide 3D setup estimates. For cropped portraits, face size provides a rough distance and the pose guide offers adjustable starting height and tilt.
5. Preview an animated stick figure pose guide, then open the camera.
6. Use the thirds grid, motion based level, pose overlay, and live pose cue, then capture.
7. Compare the captured shot with the reference and save it to Photos. A pose score appears when Vision detects enough body joints in both photos.

Scene matching searches the local inspiration library and the bundled examples. Optional Typesense keyword search uses a configured remote index; image similarity falls back to on-device matching on the free tier. See [Tools/Typesense/README.md](Tools/Typesense/README.md). The on-device flow does not require a model key.

## Optional Gemini image guidance

Poser can ask Gemini to describe a reference pose and compare a captured shot with its reference. Each request starts when the user taps its button; the selected image or image pair is sent to Google. Gemini supplies qualitative advice only. Vision continues to calculate pose measurements and the pose score locally.

The iOS client uses [Firebase AI Logic](https://firebase.google.com/docs/ai-logic) so a Gemini API key is not embedded in the app. To enable it:

1. The dedicated Firebase project is `poser-neal-app-20261114`, registered to iOS bundle ID `com.nealkotval.Poser` with the Gemini Developer API. It uses the no-billing Spark plan, and Firebase AI Logic generation is limited to 5 requests per minute per user.
2. [Firebase App Check](https://firebase.google.com/docs/ai-logic/app-check) is enforced for AI Logic. Local Debug builds use the App Check debug provider; register each device's logged debug token in Firebase before using Gemini. A production release needs App Attest and an Apple Developer team that supports that capability; the current Personal Team does not.
3. `Poser/GoogleService-Info.plist` is the Firebase app config and is included in the target's **Copy Bundle Resources**. It contains a Firebase client API key, not a Gemini API key; that key is restricted to the Poser iOS bundle ID and supported Firebase APIs. Keep debug tokens out of the repository. If regenerating the project from `project.yml`, check that the config resource and Release App Attest entitlement remain included.
4. Build and run. The Gemini buttons appear when the Firebase configuration is bundled. They use `gemini-3.5-flash-lite` and show errors without interrupting local analysis.

The committed Firebase config identifies the Poser project. App Check still requires a registered development token for Debug builds or a supported production attestation provider for Release builds.

## Pinterest reference collection

The [Pinterest discovery collection](ReferenceCollection/pinterest/README.md) contains 1,000 current solo-targeted, Instagram-style Pin candidates plus the archived first discovery run. A local download pass retrieved 999 images and normalized 997 distinct files. The development app bundles 816 references: 815 had one body detected by Apple Vision, and one more was visually checked. Pin links are retained in the catalog. Creators, original sources, and reuse rights remain unverified, so these assets are not cleared for distribution.

The [collection workflow](Tools/ReferenceLibrary/PINTEREST.md) provides the Playwright collector, local Vision review aids, and approved-image export tools. Browser sessions and credentials stay in the ignored `.reference-work` directory. The collection is separate from the app’s current bundled examples.
