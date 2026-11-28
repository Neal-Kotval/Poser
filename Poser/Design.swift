import SwiftUI

// MARK: - Foundations

enum Palette {
    static let background = Color(red: 0.035, green: 0.04, blue: 0.055)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let elevated = Color(uiColor: .tertiarySystemGroupedBackground)
    static let border = Color.white.opacity(0.12)
    static let primaryText = Color.white
    static let secondaryText = Color(red: 0.68, green: 0.68, blue: 0.68)
    static let tertiaryText = Color(red: 0.48, green: 0.48, blue: 0.48)
}

enum PoserSpace {
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let regular: CGFloat = 16
    static let large: CGFloat = 24
    static let xLarge: CGFloat = 32
}

enum PoserRadius {
    static let control: CGFloat = 22
    static let image: CGFloat = 24
    static let surface: CGFloat = 28
}

private struct PoserGlassModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let cornerRadius: CGFloat
    let interactive: Bool
    let tint: Color

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content
                .background(tint == .clear ? Palette.elevated : tint, in: shape)
                .overlay(shape.stroke(Palette.border, lineWidth: 1))
        } else {
            content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        }
    }
}

extension View {
    func poserGlass(cornerRadius: CGFloat = PoserRadius.control,
                    interactive: Bool = false, tint: Color = .clear) -> some View {
        modifier(PoserGlassModifier(cornerRadius: cornerRadius, interactive: interactive, tint: tint))
    }
}

enum PoserType {
    static let wordmark = Font.system(size: 25, weight: .bold, design: .rounded)
    static let title = Font.system(.title2, design: .rounded, weight: .semibold)
    static let body = Font.system(.body)
    static let action = Font.system(.body, weight: .semibold)
    static let supporting = Font.system(.subheadline)
    static let caption = Font.system(.caption, weight: .medium)
}

// MARK: - Components

/// A shared photo overlay. Narrow grid tiles stack pills rather than truncate.
struct PhotoTagPills: View {
    let tags: [ReferenceTag]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { pills }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 4) { pills }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var pills: some View {
        ForEach(tags) { tag in
            Text(tag.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .fixedSize()
        }
    }
}
