import SwiftUI

/// Instrument-panel design language: a camera top plate, not a web page.
/// Charcoal ground, warm engraved off-white, one red accent used sparingly.
enum Theme {
    static let bg = Color(red: 0.086, green: 0.086, blue: 0.094)
    static let panel = Color(red: 0.125, green: 0.125, blue: 0.137)
    static let panelEdge = Color(white: 0.22)
    static let engraved = Color(red: 0.92, green: 0.91, blue: 0.87)
    static let dim = Color(white: 0.55)
    static let faint = Color(white: 0.35)
    static let accent = Color(red: 0.878, green: 0.106, blue: 0.141) // Leica red
    static let ok = Color(red: 0.55, green: 0.78, blue: 0.45)

    static func code(_ size: CGFloat = 22) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }

    static func mono(_ size: CGFloat = 12) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
}

/// Small-caps tracked label, like engraving on an instrument.
struct EngravedLabel: View {
    let text: String
    var color: Color = Theme.dim

    init(_ text: String, color: Color = Theme.dim) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.8)
            .foregroundStyle(color)
    }
}

/// The 6-bit code as the pit fields on the M bayonet flange:
/// filled = black paint (1), hollow = bare metal (0).
struct BitPatternView: View {
    let code: String
    var dotSize: CGFloat = 9

    var body: some View {
        HStack(spacing: dotSize * 0.55) {
            ForEach(Array(code.enumerated()), id: \.offset) { _, ch in
                Circle()
                    .strokeBorder(Theme.engraved.opacity(0.75), lineWidth: 1)
                    .background(Circle().fill(ch == "1" ? Theme.engraved : .clear))
                    .frame(width: dotSize, height: dotSize)
            }
        }
        .accessibilityLabel("6-bit code \(code)")
    }
}

/// Card chrome shared by codes and lenses.
struct InstrumentCard: ViewModifier {
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(highlighted ? Theme.accent.opacity(0.8) : Theme.panelEdge, lineWidth: 1)
                    )
            )
    }
}

extension View {
    func instrumentCard(highlighted: Bool = false) -> some View {
        modifier(InstrumentCard(highlighted: highlighted))
    }
}
