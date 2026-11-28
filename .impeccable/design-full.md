# Poser design system

Poser is a camera-first photography tool. The live image or a reference photo is the visual focus; controls stay quiet until they help someone take the next shot. The interface pairs a dark, photo-focused canvas with native Liquid Glass controls, continuous rounded corners, and floating navigation. Typography stays unchanged.

## Colors

| Role | Swift token | Value | Use |
| --- | --- | --- | --- |
| Background | `Palette.background` | `#090A0E` | Main app and camera backdrop |
| Surface | `Palette.surface` | System secondary grouped background | Grouped actions and guidance |
| Elevated | `Palette.elevated` | System tertiary grouped background | Pressed or raised controls |
| Border | `Palette.border` | White at 12% opacity | Quiet separation only where needed |
| Primary text | `Palette.primaryText` | `#FFFFFF` | Titles and actions |
| Secondary text | `Palette.secondaryText` | `#ADADAD` | Supporting copy |
| Tertiary text | `Palette.tertiaryText` | `#7A7A7A` | Low-emphasis metadata |

The compatibility names `ink`, `panel`, `raised`, `cyan`, `cream`, and `muted` remain in `Palette` while existing screens migrate to semantic names. `cyan` now resolves to white.

## Typography

`PoserType` contains the wordmark, display, title, body, action, supporting, and caption roles. Use semantic SwiftUI font styles for content so Dynamic Type can scale. Keep the wordmark as the only strongly styled text treatment. Use SF Symbols for simple controls and avoid adding ornament to photo surfaces.

## Spacing & Layout

`PoserSpace` follows a 4-point rhythm: 4, 8, 12, 16, 24, and 32 points. `PoserRadius` uses 22-point controls, 28-point grouped surfaces, and 24-point photo corners. Category chips and floating navigation use capsule shapes. Selection tiles use a 1:1 crop; Home `For you` posts use near-full-bleed 4:5 portrait cards (6-point side inset, 24-point continuous rounded corners) with a compact post header above (monogram avatar, demo handle, and setting/pose subtitle) and a bottom overlay bar (36-point Liquid Glass heart control at bottom-left and solid white `Try pose` pill at bottom-right over a subtle bottom scrim). Tapping a photo or `Try pose` opens the guided shoot; double-tapping a photo likes it with a spring heart burst (fade-only when Reduce Motion is enabled). Liking adds one to the mock base count, fills and bounces the heart, and animates the numeric count. Like state persists locally by reference ID and survives page resets. Reduce Motion removes the symbol animation. Handles use the demo prefix, and values are stable per reference; they are not source attribution or live social engagement. Feed cards asynchronously load the original bundled image at its available resolution, using small thumbnails only as placeholders and for scene matching. The live camera remains edge-to-edge.

## Components

- `PrimaryButton`: white filled action for the next step. Use one per screen or section.
- `SecondaryButton`: interactive Liquid Glass action for an alternative.
- `poserGlass`: native regular Liquid Glass for navigation, controls, and floating camera guidance. Uses an opaque backing when Reduce Transparency is enabled.
- Keep content cards on solid system surfaces; glass belongs above content, not behind every photograph. The Home search expands as one continuous glass bubble, with a text field and category chips on the same surface. Chips use solid selection fills rather than separate glass layers. Search matches the title, setting, and pose. Category chips support multiple selections: places match any selected place, poses match any selected pose, and the two groups combine. Search text further narrows results. Tapping a selected chip removes it; All clears category selections. Collapsed search shows individually removable active filters.
- `PhotoTagPills`: shared compact setting/pose overlays for For you and Choose your shots. Place inside the bottom-left of the rounded image; narrow tiles stack pills without truncation. Photo tags never intercept taps or replace the accessible photo label.
- `SectionLabel`: quiet supporting label for grouping content.
- `PoserSurface`: a grouped dark surface with a subtle border.

The bottom navigation is a floating glass capsule with Home, Camera, and Profile in swipe order. A rounded selection background identifies the current page. While typing in Home search, navigation fades out and page swipes pause. Navigation returns after keyboard dismissal completes; queries and categories stay selected. Category suggestions can remain open with the keyboard dismissed. The camera opens first. Home is the inspiration feed; the Camera tab holds active shot plans and captured-image review. On the camera screen, the shutter is the strongest control and live guidance appears only when a recipe exists.

The live camera pose outline supports dragging to reposition and pinching to resize, with double-tap to restore its original placement. While dragging, its edges and center magnetically align to the preview margins and centerlines, with cyan guide lines, a light haptic, and a wider release threshold to prevent jitter. Adjustments update alignment guidance and frame-overlap scoring, persist for a retake, and reset for a new reference. A back arrow sits immediately before the reference thumbnail; tapping the thumbnail opens the larger reference preview. Outline gestures do not trigger page navigation.

The compact + control in Your inspiration opens an ordered photo picker capped at 10 selections. Review opens before anything is saved. Tapping a preview toggles inclusion; Add N photos confirms and Cancel (or dismissing the sheet) saves nothing. One confirmed photo starts a shoot; multiple confirmed photos stay in the inspiration library. Original photo bytes retain camera metadata.

Saved inspiration supports long-press context menus for individual deletion. The section header’s Edit action enters selection mode with checkmarks, Select All, and a bulk Delete action. Deletion requires confirmation; Cancel preserves the selection, and Done exits selection mode. Horizontal scrolling within saved inspiration never changes pages.

The full-screen pre-shot pose guide has a minimal black canvas, one camera action, and no adjustable setup panel. Dotted measurement guides flow gently toward their targets; the ground stays still, and Reduce Motion stops the flow. It shows available geometry estimates with approximate labels; unavailable height and tilt remain explicitly unmeasured. Face-based distance is labeled as a face estimate. The guide uses solid white pedestrian-sign pictograms on a dark surface, with circular heads, thick capsule limbs, and softly rounded torsos. It animates between a neutral stance and detected body landmarks when available; the example pose is labeled when detection is unavailable. Keep its camera distance and subject instructions readable before the user opens the live camera.

## Accessibility

- Keep interactive areas at least 44 by 44 points; the shared buttons have a 52-point minimum height.
- Pair icons with readable labels or accessibility labels. Decorative symbols inside a labeled button are hidden from VoiceOver.
- Preserve readable contrast on photos using regular glass for floating guidance and an opaque fallback for Reduce Transparency.
- Constrain cropped image hit areas to their visible tiles. Gestures that start inside the search bubble stay there; page swipes start elsewhere. Expansion respects Reduce Motion.
- Support Dynamic Type without truncating instructions. Avoid relying on color alone to signal a successful alignment or error.
- Keep motion tied to a user action; respect Reduced Motion if animations are added later.

## Page navigation

Manual tab changes reset transient page state: Home search, filters, editing selection, and scroll position; the unsaved camera setup; and Profile presentation state. Saved references, completed shots, and profile data persist. Opening a reference is a separate programmatic transition that retains its shoot setup.

Page gestures begin within 28 points of an outside edge and move inward with clear horizontal intent. They must travel at least 28% of the page width (96-point minimum). Search and saved-photo controls include protected margins, and their horizontal scrolling never triggers a page turn. Bottom navigation remains available for direct switching.

For you ordering mixes setting/pose groups once per launch, penalizing recently shown tags and spreading category usage across the feed. Filtering preserves this session order. Every reference remains available; liking a card does not reorder the feed.

Home uses a sticky translucent top bar (`poser` wordmark leading, centered Liquid Glass `For you | Saved` segmented pill, and a trailing 44-point Liquid Glass Search toggle on `For you` or `+` photo-import picker on `Saved`). In `For you`, a horizontal quick-filter chip rail sits directly above the full-bleed 4:5 feed; expanding Search reveals the Liquid Glass search bubble with text input and multi-select category chips. Switching to `Saved` opens an edge-to-edge 3-column 3:4 portrait grid (2-point spacing) with saved count, bulk Edit/Delete selection, long-press deletion, and an empty-state import CTA. The Gemini preparation notice is omitted from the Home section.

Profile follows an Instagram-inspired header rhythm (84-point avatar with optional white streak ring, 3-column monospaced stats for Shots, Best match, and Poses tried, rounded display name with streak chip and bio, and equal-width 44-point Liquid Glass `Edit profile` and `Share profile` capsules) above a full-width `Shots | Poses | Progress` tab bar with a matched-geometry underline indicator. `Shots` and `Poses` use edge-to-edge 3-column 3:4 portrait grids (2-point spacing, matching Home `Saved`); `Shots` tiles keep full focus on the photo with a subtle bottom-right match score badge and a top-right pin on the best shot, opening an expanded single-post view with a translucent Liquid Glass `Post` bar and near-full-bleed side-by-side `REFERENCE` / `MY SHOT` cards. `Progress` groups streak and average match into a unified dark surface above the Match trend chart and Milestones grid.

The live camera keeps the reference thumbnail without a recipe title beside it. Tapping the thumbnail opens an uncropped, large reference-photo sheet with a close control and swipe dismissal. The grid control has a compact 32-point visual surface inside a 44-point tap target. Closing the reference sheet retains the current shoot.
