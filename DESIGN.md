# Poser design system

Poser is a camera-first photography tool. The live image or a reference photo is the visual focus; controls stay quiet until they help someone take the next shot. The interface pairs a dark, photo-focused canvas with native Liquid Glass controls, continuous rounded corners, and floating navigation. Typography stays unchanged.

## Foundations

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

`PoserType` contains the wordmark, display, title, body, action, supporting, and caption roles. Use semantic SwiftUI font styles for content so Dynamic Type can scale. Keep the wordmark as the only strongly styled text treatment. Use SF Symbols for simple controls and avoid adding ornament to photo surfaces.

`PoserSpace` follows a 4-point rhythm: 4, 8, 12, 16, 24, and 32 points. `PoserRadius` uses 22-point controls, 28-point grouped surfaces, and 24-point photo corners. Category chips and floating navigation use capsule shapes. Feed and selection tiles use a 1:1 crop. The live camera remains edge-to-edge.

## Components

- `PrimaryButton`: white filled action for the next step. Use one per screen or section.
- `SecondaryButton`: interactive Liquid Glass action for an alternative.
- `poserGlass`: native regular Liquid Glass for navigation, controls, and floating camera guidance. Uses an opaque backing when Reduce Transparency is enabled.
- Keep content cards on solid system surfaces; glass belongs above content, not behind every photograph. The Home search expands as one continuous glass bubble, with a text field and category chips on the same surface. Chips use solid selection fills rather than separate glass layers. Search matches the title, setting, and pose; category selection narrows those results.
- `SectionLabel`: quiet supporting label for grouping content.
- `PoserSurface`: a grouped dark surface with a subtle border.

The bottom navigation is a floating glass capsule with Home, Camera, and Profile in swipe order. A rounded selection background identifies the current page. While typing in Home search, navigation fades out and page swipes pause. Navigation returns after keyboard dismissal completes; queries and categories stay selected. Category suggestions can remain open with the keyboard dismissed. The camera opens first. Home is the inspiration feed; the Camera tab holds active shot plans and captured-image review. On the camera screen, the shutter is the strongest control and live guidance appears only when a recipe exists.

Saved inspiration supports long-press context menus for individual deletion. The section header’s Edit action enters selection mode with checkmarks, Select All, and a bulk Delete action. Deletion requires confirmation; Cancel preserves the selection, and Done exits selection mode. Horizontal scrolling within saved inspiration never changes pages.

The pre-shot pose guide uses solid white pedestrian-sign pictograms on a dark surface, with circular heads, thick capsule limbs, and softly rounded torsos. It animates between a neutral stance and detected body landmarks when available; the example pose is labeled when detection is unavailable. Keep its camera distance and subject instructions readable before the user opens the live camera.

## Accessibility

- Keep interactive areas at least 44 by 44 points; the shared buttons have a 52-point minimum height.
- Pair icons with readable labels or accessibility labels. Decorative symbols inside a labeled button are hidden from VoiceOver.
- Preserve readable contrast on photos using regular glass for floating guidance and an opaque fallback for Reduce Transparency.
- Constrain cropped image hit areas to their visible tiles. Gestures that start inside the search bubble stay there; page swipes start elsewhere. Expansion respects Reduce Motion.
- Support Dynamic Type without truncating instructions. Avoid relying on color alone to signal a successful alignment or error.
- Keep motion tied to a user action; respect Reduced Motion if animations are added later.
