---
version: 1
slug: "poser-profileview-swift"
primary_target: "Poser/ProfileView.swift"
related_targets: []
---

# Profile Surface Brief

- **Scope:** Profile tab in `Poser/ProfileView.swift` (Instagram-inspired profile header, `Shots` / `Poses` / `Progress` tabs, edge-to-edge 3:4 grids, tapped-in `ShotFeedView` / `ShotPostCard`, and `EditProfileView`).
- **Mode:** Operate
- **Audience & job:** Solo iPhone photo-takers reviewing their completed recreations, launching saved reference poses, tracking match-score progress, and editing/sharing their local profile.
- **Constraints:** Preserve Poser's dark `#090A0E` canvas, native iOS 26 Liquid Glass (`poserGlass`), SF Rounded display / SF Pro body, floating bottom glass capsule navigation, edge-swipe pager compatibility, Dynamic Type, Reduce Motion, Reduce Transparency fallbacks, 44pt minimum touch targets, and local-first storage (`UserProfileStore`, `ShootStore`, `InspirationStore`).

## Direction contract

- **THESIS:** Bring Instagram's unmistakable profile rhythm — compact avatar + 3-column stats, bio, full-width Liquid Glass Edit/Share pills, and full-bleed 3-column 3:4 portrait grids — into Poser's monochrome Liquid Glass world, refusing the old 24pt-inset rounded square tiles and cluttered BeReal reference insets on the grid.
- **OWN-WORLD:** Poser's established dark `#090A0E` photo canvas, native Liquid Glass capsules (`poserGlass`), solid monochrome white primary pills (`#FFFFFF` fill with `#090A0E` ink), edge-to-edge 2pt-gutter 3:4 portrait grids (matching Home's `Saved` tab), near-full-bleed rounded-24pt post pairs in `ShotFeedView`, and SF Rounded/SF Pro Dynamic Type typography.
- **STORY:** The user swipes to Profile, immediately sees their identity, stats (`Shots`, `Best match`, `Poses tried`), bio, and Liquid Glass `Edit profile` / `Share profile` capsules above a full-width `Shots | Poses | Progress` tab bar; tapping a clean 3:4 shot tile opens the polished Instagram-style `ShotFeedView` with side-by-side `REFERENCE` and `MY SHOT` cards; switching to `Poses` opens a 3:4 grid of saved references with `+ Add pose`; switching to `Progress` shows a unified streak/average strip, match trend chart, and milestones.
- **FIRST VIEWPORT:** Classic Instagram header (16pt side padding: 84pt circular avatar with optional white streak ring on left, 3-column monospaced stats on right; bold rounded display name + optional streak pill and bio underneath; equal-width 44pt Liquid Glass `Edit profile` and `Share profile` capsules), full-width 3-tab bar (`Shots`, `Poses`, `Progress`) with matched-geometry white underline indicator, and an edge-to-edge 3-column 3:4 portrait grid (2pt spacing) showing clean shots with subtle bottom-right match score pills and a top-right pin badge on the best shot, extending down behind the floating bottom glass nav.
- **FORM:** Instagram-Inspired Edge-to-Edge Profile, `seed: none (pinned)` — "keeping the design language and inspiration of the redesigned home page. the profile should draw inspiration from instagram" + confirmed edge-to-edge 3:4 grid with clean shot focus & subtle match badge, 3 tabs + polished post feed/edit sheet, and classic Instagram header rhythm. Signature interaction: matched-geometry spring underline tab switcher + edge-to-edge 3:4 grid opening into full-bleed side-by-side `REFERENCE` / `MY SHOT` post cards with double-tap spring heart burst.
- **FINISH:** unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance.
