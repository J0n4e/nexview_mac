// Nexview look for the SwiftUI windows: colours and shared components (Card, NXButton, ...).
import Cocoa
import SwiftUI

// MARK: Nexview look (colours from Nexview's styles/index.css, dark theme)

enum NX {
    static func hex(_ h: UInt32) -> Color {
        Color(red: Double((h >> 16) & 0xff) / 255, green: Double((h >> 8) & 0xff) / 255, blue: Double(h & 0xff) / 255)
    }
    static let ink950 = hex(0x0b0b0f), ink900 = hex(0x101016), ink850 = hex(0x16161d), ink800 = hex(0x1d1d26)
    static let ink700 = hex(0x26262f), ink600 = hex(0x3a3a46)
    static let mist100 = hex(0xf2f2f5), mist300 = hex(0xc3c3ce), mist500 = hex(0x9a9aa8), mist600 = hex(0x6f6f80)
    static let accent300 = hex(0xff6b7a), accent400 = hex(0xff3b4e), accent500 = hex(0xe11d2f), accent700 = hex(0x8f0f1c)
    static let ok = hex(0x22c55e), bad = hex(0xf87171)
    static let gradient = LinearGradient(colors: [accent400, accent500, accent700], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct Wordmark: View {
    var size: CGFloat = 17
    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: size * 1.7, height: size * 1.7)
            (Text("NEX").foregroundColor(NX.mist100) + Text("VIEW").foregroundColor(NX.accent400))
                .font(.system(size: size, weight: .heavy)).tracking(0.3)
        }
    }
}

struct Card<Content: View>: View {
    var title: String? = nil
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundColor(NX.mist500)
                    if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundColor(NX.mist600) }
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(NX.ink850))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(NX.ink700, lineWidth: 1))
    }
}

struct NXButton: ButtonStyle {
    enum Kind { case primary, secondary, danger }
    var kind: Kind = .secondary
    func makeBody(configuration c: Configuration) -> some View {
        c.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundColor(kind == .primary ? .white : (kind == .danger ? NX.bad : NX.mist100))
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(kind == .primary ? AnyShapeStyle(NX.gradient) : AnyShapeStyle(NX.ink800))
            )
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(kind == .primary ? Color.clear : (kind == .danger ? NX.bad.opacity(0.35) : NX.ink700), lineWidth: 1))
            .opacity(c.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

struct NXToggleRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundColor(NX.mist100)
                if let detail { Text(detail).font(.system(size: 12)).foregroundColor(NX.mist500) }
            }
            Spacer()
            Toggle("", isOn: $isOn).toggleStyle(.switch).tint(NX.accent500).labelsHidden()
        }
    }
}

struct NXField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundColor(NX.mist500)
            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(NX.mist600))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(NX.mist100)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9).fill(NX.ink900))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(NX.ink700, lineWidth: 1))
        }
    }
}

struct StatusDot: View {
    let health: Health
    var body: some View {
        switch health {
        case .checking: HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Checking…") }.font(.system(size: 11)).foregroundColor(NX.mist500)
        case .online(let v): dot(NX.ok, "Online · Nexview \(v)")
        case .offline: dot(NX.bad, "Unreachable")
        case .unknown: EmptyView()
        }
    }
    func dot(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 6) { Circle().fill(c).frame(width: 7, height: 7).shadow(color: c.opacity(0.7), radius: 3); Text(t) }
            .font(.system(size: 11, weight: .medium)).foregroundColor(NX.mist500)
    }
}
