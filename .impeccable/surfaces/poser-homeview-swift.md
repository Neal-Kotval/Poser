---
version: 1
slug: "poser-homeview-swift"
primary_target: "Poser/HomeView.swift"
related_targets: []
---

# Home Feed Surface Brief

- **Scope:** Home tab in `Poser/HomeView.swift` (`For you` discovery stream + `Saved` inspiration library, sticky header with segmented switcher, collapsible search, quick-filter chips).
- **Mode:** Operate
- **Audience & job:** Solo iPhone photo-takers browsing curated poses or their saved references on location and launching a guided camera shoot in one tap.
- **Constraints:** Preserve Poser's dark `#090A0E` canvas, native iOS 26 Liquid Glass (`poserGlass`), SF Rounded display / SF Pro body, floating bottom glass capsule navigation, edge-swipe pager (`HomePaging`), Dynamic Type, Reduce Motion, Reduce Transparency fallbacks, 44pt minimum touch targets, and non-attributive demo handles/likes.

## Direction contract

- **THESIS:** Put the first full-bleed 4:5 pose photo immediately below a compact top bar by splitting `For you` and `Saved` into a native segmented glass pill, refusing the cluttered vertical stack of an oversized carousel + search bubble + inset 1:1 squares.
- **OWN-WORLD:** Poser's established dark `#090A0E` photo canvas, native Liquid Glass capsules (`poserGlass`), solid monochrome white primary pills (`#FFFFFF` ink on `#090A0E` text), continuous 24pt rounded photo corners, SF Rounded wordmark, and SF Pro metadata.
- **STORY:** The user opens Home, sees a full-bleed 4:5 reference pose immediately, taps a quick-filter chip or expands Search to narrow by setting/pose, double-taps or taps heart to like, or taps the photo / `Try pose` pill to launch the guided camera shoot; switching to `Saved` opens a clean 3-column edge-to-edge Instagram-style grid of imported references with `+` import and bulk Edit/Delete.
- **FIRST VIEWPORT:** Sticky translucent gradient header (`poser` left, centered `For you | Saved` segmented glass pill, circular Search glass button on `For you` / `+` import glass button on `Saved`), compact horizontal quick-filter chip rail (`All`, settings/poses), compact post header (`avatar` + demo handle + `setting · pose` subtitle + photo count), and a near-full-bleed 4:5 rounded-24pt portrait card (6pt side inset) with a bottom overlay bar (36pt Liquid Glass heart + count left; crisp white 36pt `Try pose` pill right) and the next card peeking below before the floating bottom glass nav.
- **FORM:** Dual-Tab Full-Bleed Feed (candidate 5 of 7, dealt third, chosen by user), `seed:3efed898bd27f8fa`. Signature interaction: animated matched-geometry `For you | Saved` pill transition + double-tap-to-like spring heart burst on full-bleed 4:5 cards + collapsible top Liquid Glass search sheet that hides bottom nav while typing.
- **FINISH:** unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance.
