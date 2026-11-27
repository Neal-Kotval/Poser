# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

Everyday iPhone users and solo photo-takers who want better portraits and candid shots without hiring a photographer or guessing angles. They use Poser on location (outdoors, cafes, streets, travel spots) and while browsing inspiration before or during a shoot.

## Product Purpose

Poser is a camera-first personal photography assistant with social-app ergonomics. It helps users discover or import reference photos, match poses to their real surroundings, follow live camera guidance (pose overlay, framing, level, distance/tilt cues), and review/save their recreations with a Vision-based pose match score.

## Positioning

Combines on-device Apple Vision pose/scene matching and optional Gemini qualitative coaching with the familiar, low-friction browsing and capture ergonomics of social photo apps like Instagram and BeReal.

## Operating Context

- Native iOS 26+ SwiftUI app (`Poser.xcodeproj`), dark-only (`preferredColorScheme(.dark)`).
- Three top-level swipeable tabs in a floating bottom glass capsule: Home (inspiration feed), Camera (live viewfinder, scene scan, shoot plan & review — opens first), and Profile (completed shots, saved poses, progress).
- Local-first on-device storage (`InspirationStore`, `ShootStore`, `UserProfileStore`, `ReferenceLikeStore`); social elements on the Home feed (demo handles, mock like counts) are local ergonomics rather than a live social network.
- Simulator runs with a labeled sample preview and supports `-PoserDemoProfile` launch argument for demo data.

## Capabilities and Constraints

- Bundled catalog of 816 curated solo Instagram-style Pinterest reference photos (`ReferenceCatalog`) with setting and pose tags, plus optional Typesense keyword search and on-device scene matching.
- Photo library import (up to 10 photos with review sheet) into a local inspiration library (`InspirationStore`) with edit/bulk-delete support.
- Live camera viewfinder with pose skeleton overlay (drag/pinch/snap), thirds grid, motion level, pre-shot animated pictogram pose guide, and post-capture comparison with Vision pose score and optional Gemini photo tips.
- Must preserve existing dark `#090A0E` + native iOS 26 Liquid Glass design language, Dynamic Type, Reduce Motion, Reduce Transparency fallbacks, and 44pt minimum touch targets.
- Reference asset rights are unverified (development-only bundled Pinterest references); do not present mock handles or demo likes as real creator attribution or live social engagement.

## Brand Commitments

- Name: **Poser**
- Visual language: Existing dark, photo-focused canvas (`#090A0E`) paired with native Liquid Glass controls, continuous rounded corners, SF Rounded display/titles, SF Pro body, monochrome white-on-dark contrast, and floating bottom glass capsule navigation (documented in `DESIGN.md`).
- UX ergonomics: Draw structural inspiration from Instagram and BeReal (e.g., full-bleed vertical feed, edge-to-edge photo grids) while staying true to Poser's personal photography tool identity.

## Evidence on Hand

- `DESIGN.md` and `Poser/Design.swift`: established design tokens and Liquid Glass components.
- `Poser/PinterestLibrary/`: 816 bundled reference photos + `catalog.json`.
- `Poser/HomeView.swift`, `Poser/Camera.swift`, `Poser/ProfileView.swift`, `Poser/PoseTutorial.swift`: full working SwiftUI implementation.
- No live social backend, user accounts, or real engagement metrics exist.

## Product Principles

1. **Photo first, chrome second.** Reference photos and the live viewfinder own the viewport; controls recede until needed.
2. **Social-app muscle memory, utility-grade speed.** Borrowing Instagram/BeReal layout rhythm reduces friction without turning the app into noisy social media.
3. **One tap from inspiration to camera.** Every saved or discovered pose should launch a guided shoot with minimal detours.
4. **Honest on-device feedback.** Keep mock social metadata clearly non-attributive and Vision/Gemini guidance transparent about what is measured vs. estimated.
