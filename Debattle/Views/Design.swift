import SwiftUI

// The app uses semantic surfaces so light and dark appearances stay readable.
enum Design {
    static let purple = Color(red: 0.43, green: 0.28, blue: 0.88)
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.72, green: 0.62, blue: 1, alpha: 1)
            : UIColor(red: 0.43, green: 0.28, blue: 0.88, alpha: 1)
    })
    static let lavender = Color(red: 0.89, green: 0.86, blue: 1)
    static let green = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.37, green: 0.83, blue: 0.65, alpha: 1)
            : UIColor(red: 0.06, green: 0.42, blue: 0.30, alpha: 1)
    })
    static let orange = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 0.66, blue: 0.40, alpha: 1)
            : UIColor(red: 0.70, green: 0.27, blue: 0.08, alpha: 1)
    })
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let muted = Color.secondary
    static let radius: CGFloat = 24
}

struct BrandMark: View {
    var size: CGFloat = 38
    var body: some View {
        Image("BrandMark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.26))
            .accessibilityHidden(true)
    }
}

struct Pill: View {
    let title: String
    var icon: String? = nil
    var color: Color = Design.accent
    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon) }
            Text(title)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .foregroundStyle(color).background(color.opacity(0.10), in: Capsule())
    }
}

struct PrimaryButton: View {
    let title: String
    var icon: String? = nil
    var busy = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if busy { ProgressView().tint(.white) }
                else if let icon { Image(systemName: icon) }
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 17)
            .foregroundStyle(.white).background(Design.purple, in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain).disabled(busy)
    }
}

struct SectionHeading: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title3.bold())
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InfoBanner: View {
    let text: String
    var icon = "info.circle"
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Design.accent)
            Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .background(Design.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct EmptyCard: View {
    let icon: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 30, weight: .medium)).foregroundStyle(Design.accent)
                .frame(width: 68, height: 68).background(Design.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 23))
            Text(title).font(.title3.bold())
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(30).frame(maxWidth: .infinity).background(Design.surface, in: RoundedRectangle(cornerRadius: Design.radius))
    }
}

extension View {
    func cardStyle() -> some View { frame(maxWidth: .infinity, alignment: .leading).padding(20).background(Design.surface, in: RoundedRectangle(cornerRadius: Design.radius)) }
}

let debateLanguages = ["English", "Russian", "Spanish", "Kazakh", "French", "German", "Arabic", "Chinese", "Japanese", "Portuguese", "Hindi", "Turkish"]

func durationLabel(_ seconds: Int) -> String {
    if seconds % 60 == 0 { return "\(seconds / 60) min" }
    return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
}
