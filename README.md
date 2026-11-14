# Poser

An iOS photography assistant built with SwiftUI, AVFoundation, Vision, and Core Motion.

## Run

Open `Poser.xcodeproj` in Xcode and run the Poser target. On a physical iPhone, scanning and capture use the device camera. In the simulator, Poser shows a labeled sample preview and lets you test capture and comparison without camera hardware.

## MVP flow

1. Select a reference from Photos, paste a public image or social post link, or scan the surroundings.
2. Poser analyzes image labels, saliency, and body landmarks on device where available.
3. Review a shot recipe with camera height, framing, subject position, and light guidance.
4. Preview an animated stick figure pose guide, then open the camera.
5. Use the thirds grid, motion based level, and pose overlay, then capture.
6. Compare the captured shot with the reference and save it to Photos.

Social post previews depend on the metadata a site exposes to iOS. If a post is private or blocks previews, save its image to Photos and import it instead. Scene inspiration is a curated set of shot recipes matched to Vision's scene labels; no external image search or model key is required.
