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

Scene matching searches the local inspiration library and the bundled examples; it does not search Pinterest or Instagram. No model key is required.

## Pinterest reference collection

The [Pinterest discovery collection](ReferenceCollection/pinterest/README.md) contains 1,000 current solo-targeted, Instagram-style Pin candidates plus the archived first discovery run. A local download pass retrieved 999 images and normalized 997 distinct files. The development app bundles 816 references: 815 had one body detected by Apple Vision, and one more was visually checked. Pin links are retained in the catalog. Creators, original sources, and reuse rights remain unverified, so these assets are not cleared for distribution.

The [collection workflow](Tools/ReferenceLibrary/PINTEREST.md) provides the Playwright collector, local Vision review aids, and approved-image export tools. Browser sessions and credentials stay in the ignored `.reference-work` directory. The collection is separate from the app’s current bundled examples.
