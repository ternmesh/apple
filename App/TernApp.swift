// The app: one window of the node's conversations, contacts and settings, over one model.

import SwiftUI
import TernKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@main
struct TernApp: App {
    @StateObject private var model = NodeModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        #if os(macOS)
        // One window: the model knows one conversation on screen, which two windows would fight over.
        // iPad is held to one scene by Info.plist.
        Window("Tern", id: "main") {
            RootView()
                .environmentObject(model)
        }
        .onChange(of: scenePhase) { phase in
            model.isActive = phase == .active
        }
        #else
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
        .onChange(of: scenePhase) { phase in
            model.isActive = phase == .active
        }
        #endif
    }
}

/// Tabs on iPhone and iPad, a sidebar on a Mac.
struct RootView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case chats = "Chats"
        case contacts = "Contacts"
        case node = "Node"
        case connect = "Connect"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .chats: "bubble.left.and.bubble.right"
            case .contacts: "person.2"
            case .node: "antenna.radiowaves.left.and.right"
            case .connect: "dot.radiowaves.left.and.right"
            }
        }
    }

    @EnvironmentObject private var model: NodeModel
    @State private var section: Pane?

    var body: some View {
        panes
            // Over every screen, until it is done or skipped; it closes itself when the link drops.
            .sheet(isPresented: Binding(get: { model.needsSetup }, set: { _ in })) {
                SetupView().environmentObject(model)
            }
    }

    @ViewBuilder
    private var panes: some View {
        #if os(macOS)
        NavigationSplitView {
            List(Pane.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon)
                    .badge(s == .chats ? model.unread : 0)
                    .tag(s)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            screen(section ?? .chats)
                .id(section ?? .chats)
        }
        .onAppear { if section == nil { section = model.remembered == nil ? .connect : .chats } }
        #else
        TabView(selection: Binding(get: { section ?? .chats }, set: { section = $0 })) {
            ForEach(Pane.allCases) { s in
                screen(s)
                    .tabItem { Label(s.rawValue, systemImage: s.icon) }
                    .badge(s == .chats ? model.unread : 0)
                    .tag(s)
            }
        }
        .onAppear { if section == nil { section = model.remembered == nil ? .connect : .chats } }
        #endif
    }

    /// Each screen holds its own navigation stack.
    @ViewBuilder
    private func screen(_ s: Pane) -> some View {
        switch s {
        case .chats: ChatsView()
        case .contacts: ContactsView()
        case .node: NodeView()
        case .connect: ConnectView()
        }
    }
}

/// A refusal from the node, shown once.
struct ProblemAlert: ViewModifier {
    @EnvironmentObject private var model: NodeModel

    func body(content: Content) -> some View {
        content.alert(
            "Could not do that",
            isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
    }
}

extension View {
    func showsProblems() -> some View { modifier(ProblemAlert()) }
}

/// Copies text to the clipboard.
func copyToClipboard(_ text: String) {
    #if os(iOS)
    UIPasteboard.general.string = text
    #else
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}

/// What the link is doing, in words.
func words(_ state: BluetoothLink.State) -> String {
    switch state {
    case .starting: return "Starting Bluetooth…"
    case .unsupported: return "This device has no Bluetooth LE."
    case .unauthorized: return "Tern is not allowed to use Bluetooth."
    case .poweredOff: return "Bluetooth is off."
    case .idle: return "Not connected."
    case .disconnected: return "Disconnected. Tern stays off the node until you connect. Messages wait for you on the node."
    case .scanning: return "Looking for nodes…"
    case .connecting: return "Connecting…"
    case .pairing: return "Pairing. If asked, type the passkey the node shows."
    case .opening: return "Saying hello…"
    case .syncing: return "Syncing…"
    case .ready: return "Connected."
    case .failed(.pairing):
        return "Pairing failed. Check the passkey and try again. If the node's bonds were cleared, "
            + "forget it in the system's Bluetooth settings first."
    case let .failed(.mtu(maximum)):
        return "The Bluetooth link carries at most \(maximum) bytes, less than the node's frames need."
    case let .failed(.refused(code)):
        return "The node refused the connection. \(Words.error(code))"
    case .failed(.notTern):
        return "That device does not offer Tern's service."
    }
}
