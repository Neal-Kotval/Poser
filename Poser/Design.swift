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

    // Keep the names used by the first MVP while screens move to semantic tokens.
    static let ink = background
    static let panel = surface
    static let raised = elevated
    static let cyan = primaryText
    static let cream = primaryText
    static let muted = secondaryText
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
    static let display = Font.system(.largeTitle, design: .rounded, weight: .bold)
    static let title = Font.system(.title2, design: .rounded, weight: .semibold)
    static let body = Font.system(.body)
    static let action = Font.system(.body, weight: .semibold)
    static let supporting = Font.system(.subheadline)
    static let caption = Font.system(.caption, weight: .medium)
}

// MARK: - Components

struct PrimaryButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: PoserSpace.medium) {
                Image(systemName: symbol).accessibilityHidden(true)
                Text(title)
                Spacer(minLength: PoserSpace.small)
                Image(systemName: "arrow.right").accessibilityHidden(true)
            }
            .font(PoserType.action)
            .padding(PoserSpace.regular)
            .frame(minHeight: 52)
            .foregroundStyle(Palette.background)
            .background(Palette.primaryText, in: RoundedRectangle(cornerRadius: PoserRadius.control))
        }
        .buttonStyle(PoserPressStyle())
    }
}

struct SecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PoserType.action)
                .foregroundStyle(Palette.primaryText)
                .frame(maxWidth: .infinity, minHeight: 52)
                .poserGlass(interactive: true)
        }
        .buttonStyle(PoserPressStyle())
    }
}

struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(PoserType.caption)
            .foregroundStyle(Palette.secondaryText)
    }
}

struct PoserSurface<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(PoserSpace.regular)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: PoserRadius.surface))
            .overlay(RoundedRectangle(cornerRadius: PoserRadius.surface).stroke(Palette.border))
    }
}

private struct PoserPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.72 : 1)
    }
}
