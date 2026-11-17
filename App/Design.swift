// The pieces the screens share: Tern's colours beyond the accent, avatars, signal bars, the
// node's status pill, and the tinted squares beside a setting. The accent itself, the teal of the
// icon and ternmesh.org, is AccentColor in the asset catalog.

import SwiftUI
import TernKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension Color {
    /// A colour with one value in light appearance and another in dark.
    init(light: UInt32, dark: UInt32) {
        func rgb(_ v: UInt32) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat(v >> 16 & 0xFF) / 255, CGFloat(v >> 8 & 0xFF) / 255, CGFloat(v & 0xFF) / 255)
        }
        let (lr, lg, lb) = rgb(light), (dr, dg, db) = rgb(dark)
        #if canImport(UIKit)
        self.init(uiColor: UIColor { t in
            t.userInterfaceStyle == .dark
                ? UIColor(red: dr, green: dg, blue: db, alpha: 1) : UIColor(red: lr, green: lg, blue: lb, alpha: 1)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: dr, green: dg, blue: db, alpha: 1) : NSColor(srgbRed: lr, green: lg, blue: lb, alpha: 1)
        })
        #endif
    }

    init(hex: UInt32) { self.init(light: hex, dark: hex) }

    /// The user's own messages: the accent, a little deeper in dark appearance so white text stays easy to read.
    static let mine = Color(light: 0x0B4F6C, dark: 0x1F6F92)
    /// Someone else's messages.
    static let theirs = Color(light: 0xECF1F4, dark: 0x1C2930)
    /// Something that is fine: connected, secure, heard well.
    static let good = Color(light: 0x1F8A5B, dark: 0x4CC38A)
    /// Something that wants attention, short of a failure.
    static let warn = Color(light: 0xB7791F, dark: 0xE0A84A)
    /// The node's card on its dashboard, top to bottom.
    static let heroTop = Color(light: 0x0B4F6C, dark: 0x1C5F7D)
    static let heroBottom = Color(light: 0x07364A, dark: 0x103C50)
}

private let avatarHues: [UInt32] = [0x0B4F6C, 0x0F766E, 0x7C3AED, 0xC2410C, 0xB45309, 0xBE185D, 0x4D7C0F, 0x1D4ED8]

/// The letters an avatar shows: the first of each of the first two words, or "?".
func initials(_ name: String) -> String {
    let words = name.split(whereSeparator: { " ()·-_".contains($0) }).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
    let letters = words.prefix(2).compactMap { w in w.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } }
    return letters.isEmpty ? "?" : letters.joined()
}

/// What picks someone's avatar colour, the same on every screen: their address, or the group's id.
func avatarKey(_ peer: Peer) -> String {
    switch peer {
    case let .contact(a): a.description
    case let .group(g): "g" + g.short
    }
}

/// A stable index from a string: Swift's own hash changes from one launch to the next.
private func stableHash(_ s: String) -> Int {
    var h: UInt32 = 2_166_136_261
    for b in s.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
    return Int(h % UInt32(avatarHues.count))
}

/// A round badge of a name's initials, the same colour for the same key on every screen; a group's
/// is a rounded square, so that people and groups differ at a glance.
struct Avatar: View {
    var name: String
    var key: String
    var group = false
    var unknown = false
    var size: CGFloat = 42

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: group ? size * 0.3 : size / 2, style: .continuous)
        Text(unknown ? "?" : initials(name))
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(unknown ? Color.secondary : Color.white)
            .frame(width: size, height: size)
            .background(shape.fill(unknown ? Color.secondary.opacity(0.18) : Color(hex: avatarHues[stableHash(key)])))
            .accessibilityHidden(true)
    }
}

/// How well a neighbour is heard, as one to four bars. The thresholds are SNR in dB: above 5 is
/// strong, 0 comfortable, and below -7 near where the faster spreading factors stop hearing.
func signalBars(_ quarterDb: Int8) -> Int {
    let db = Double(quarterDb) / 4
    if db >= 5 { return 4 }
    if db >= 0 { return 3 }
    if db >= -7 { return 2 }
    return 1
}

struct SignalBars: View {
    let quarterDb: Int8

    var body: some View {
        let on = signalBars(quarterDb)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < on ? (on >= 2 ? Color.good : Color.warn) : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: CGFloat(5 + 3 * i))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Signal: \(on) of 4 bars")
    }
}

/// The node's name, whether the link is up, and its battery: on every tab, so that whether the node
/// is there is never more than a glance away.
struct NodeStatusPill: View {
    @EnvironmentObject private var model: NodeModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 8, height: 8)
                Text(model.nodeName ?? "No node").lineLimit(1)
                if model.isConnected, let p = model.records.power, p.percent <= 100 {
                    Text("· \(p.percent)%").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(model.nodeName ?? "No node"), \(words(model.linkState, turnedOff: model.turnedOff))")
        .accessibilityHint("Shows the node")
    }

    private var dot: Color {
        if model.isConnected { return .good }
        if case .failed = model.linkState { return .red }
        if model.disconnected || [.poweredOff, .unauthorized, .unsupported].contains(model.linkState) { return .red }
        return .warn
    }
}

/// A tinted square behind a setting's symbol, as Settings has, so that each is found by colour as well as by name.
struct IconTile: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint))
    }
}

/// A row that opens a screen: a tile, a name, and what it is set to now.
struct SettingRow: View {
    let title: String
    let symbol: String
    let tint: Color
    var value: String?
    var valueColor: Color = .secondary

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, tint: tint)
            Text(title)
            Spacer()
            if let value {
                Text(value).foregroundStyle(valueColor).lineLimit(1)
            }
        }
    }
}

/// A small rounded label beside a name: "Contact", "Relay".
struct Tag: View {
    let text: String
    var tint: Color = .secondary

    init(_ text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.14)))
    }
}

/// Goes to the Node tab: what the status pill does wherever it is.
private struct ShowNodeKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var showNode: () -> Void {
        get { self[ShowNodeKey.self] }
        set { self[ShowNodeKey.self] = newValue }
    }
}

/// The pill, placed at the leading edge of a tab's bar, going to the Node tab.
private struct NodeStatusItem: ViewModifier {
    @Environment(\.showNode) private var showNode

    func body(content: Content) -> some View {
        content.toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarLeading) { NodeStatusPill(action: showNode) }
            #else
            ToolbarItem(placement: .navigation) { NodeStatusPill(action: showNode) }
            #endif
        }
    }
}

extension View {
    /// The node's status pill at the leading edge of a tab's bar.
    func nodeStatus() -> some View { modifier(NodeStatusItem()) }
}
