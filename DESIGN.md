# Poser design system

Poser is a camera-first photography tool. The live image or a reference photo is the visual focus; controls stay quiet until they help someone take the next shot. The interface uses black chrome, white type, restrained gray structure, and no decorative accent color.

## Foundations

| Role | Swift token | Value | Use |
| --- | --- | --- | --- |
| Background | `Palette.background` | `#000000` | Main app and camera backdrop |
| Surface | `Palette.surface` | `#131313` | Grouped actions and guidance |
| Elevated | `Palette.elevated` | `#242424` | Pressed or raised controls |
| Border | `Palette.border` | `#383838` | Quiet separation only where needed |
| Primary text | `Palette.primaryText` | `#FFFFFF` | Titles and actions |
| Secondary text | `Palette.secondaryText` | `#ADADAD` | Supporting copy |
| Tertiary text | `Palette.tertiaryText` | `#7A7A7A` | Low-emphasis metadata |

The compatibility names `ink`, `panel`, `raised`, `cyan`, `cream`, and `muted` remain in `Palette` while existing screens migrate to semantic names. `cyan` now resolves to white.

`PoserType` contains the wordmark, display, title, body, action, supporting, and caption roles. Use semantic SwiftUI font styles for content so Dynamic Type can scale. Keep the wordmark as the only strongly styled text treatment. Use SF Symbols for simple controls and avoid adding ornament to photo surfaces.

`PoserSpace` follows a 4-point rhythm: 4, 8, 12, 16, 24, and 32 points. `PoserRadius` has separate sizes for controls (12), images (14), and grouped surfaces (18). A camera image can be edge-to-edge; do not force every image into a card.

## Components

- `PrimaryButton`: white filled action for the next step. Use one per screen or section.
- `SecondaryButton`: outlined dark action for an alternative.
- `SectionLabel`: quiet supporting label for grouping content.
- `PoserSurface`: a grouped dark surface with a subtle border.

The bottom navigation contains Home and a prominent camera control. The camera opens first. Home holds references, inspiration, shot plans, and captured images. On the camera screen, the shutter is the strongest control and live guidance appears only when a recipe exists.

The pre-shot pose guide uses a white line figure on a dark surface. It animates between a neutral stance and detected body landmarks when available; the example pose is labeled when detection is unavailable. Keep its camera distance and subject instructions readable before the user opens the live camera.

## Accessibility

- Keep interactive areas at least 44 by 44 points; the shared buttons have a 52-point minimum height.
- Pair icons with readable labels or accessibility labels. Decorative symbols inside a labeled button are hidden from VoiceOver.
- Preserve readable contrast on photos with a dark backing behind live text.
- Support Dynamic Type without truncating instructions. Avoid relying on color alone to signal a successful alignment or error.
- Keep motion tied to a user action; respect Reduced Motion if animations are added later.
