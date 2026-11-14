import SwiftUI

// MARK: - Foundations

enum Palette {
    static let background = Color.black
    static let surface = Color(red: 0.075, green: 0.075, blue: 0.075)
    static let elevated = Color(red: 0.14, green: 0.14, blue: 0.14)
    static let border = Color(red: 0.22, green: 0.22, blue: 0.22)
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
    static let control: CGFloat = 4
    static let image: CGFloat = 0
    static let surface: CGFloat = 4
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
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: PoserRadius.control))
                .overlay(RoundedRectangle(cornerRadius: PoserRadius.control).stroke(Palette.border))
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
