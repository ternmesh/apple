// A group's join code (draft/groups.md in ternmesh/spec): shown, when the user asks, as a QR code
// and a link to send; and joined from, scanned, pasted or opened from a ternmesh.org/G link. The
// node writes the link and reads it. The app holds it only while the sheet that shows it, or the
// one it was given to, is open.

import SwiftUI
import TernKit

/// A group's join code, once the user has read what showing it means: the node is asked for it
/// only then, and the link is dropped when the sheet closes.
struct JoinCodeSheet: View {
    let group: GroupID
    let name: String
    @EnvironmentObject private var model: NodeModel
    @Environment(\.dismiss) private var dismiss
    @State private var link: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let link {
                    LinkCodeView(link: link)
                    Text("Scan this with Tern to join \(shownName). Anyone who has this code can read the group.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text(link).font(.caption.monospaced()).textSelection(.enabled)
                    HStack {
                        Button("Copy") { copyToClipboard(link) }
                        ShareLink(item: link)
                    }
                } else {
                    Text("Anyone who sees this code, or is sent it, can join \(shownName) and read every message in it, from before as well as after. It can't be taken back, so show it only to people you would invite.")
                        .multilineTextAlignment(.center)
                    Button("Show Code") {
                        model.groupLink(group) { link = $0 }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isConnected)
                }
            }
            .padding()
            .navigationTitle("Join Code")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onDisappear { link = nil }
            .showsProblems()
        }
        .frame(minWidth: 320, minHeight: 420)
    }

    private var shownName: String { name.isEmpty ? "this group" : name }
}

/// Joining a group from its join code: scanned, pasted, or from a link the app was opened with.
/// The code is read here only to name the group before the user says to join; the node is handed
/// the link.
struct JoinGroupSheet: View {
    @EnvironmentObject private var model: NodeModel
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var scanning = false
    let opened: (GroupID) -> Void

    init(text: String = "", opened: @escaping (GroupID) -> Void) {
        _text = State(initialValue: text)
        self.opened = opened
    }

    // Pasted text comes with a line break or a space at either end, which is no part of it.
    private var link: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var code: JoinCode? { JoinCode.read(link) }
    private var held: TernKit.Group? { code.flatMap { model.records.groups[$0.group] } }

    var body: some View {
        NavigationStack {
            Form {
                Text("Scan a group's join code, or paste its link. Only join a group from someone you trust.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                #if os(iOS)
                Button {
                    scanning = true
                } label: {
                    Label("Scan Code", systemImage: "qrcode.viewfinder")
                }
                #endif
                SwiftUI.Section {
                    TextField("Join code link", text: $text, axis: .vertical)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                } footer: {
                    if let held {
                        Text("You are already in \(held.name).")
                    } else if let code {
                        Text(code.name.isEmpty ? "The group has no name. You can name it once you have joined." : "The group is called \(code.name).")
                    } else if !link.isEmpty {
                        Text("Not a join code, or one that was copied wrong.").foregroundStyle(.red)
                    }
                }
                if !model.isConnected {
                    Text(Words.failure(.closed)).foregroundStyle(.secondary)
                } else if !model.speaksJoinCodes {
                    Text("Your node's firmware is too old to join a group from a join code. Update it from the Node screen.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Join a Group")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let held {
                        Button("Open") {
                            dismiss()
                            opened(held.group)
                        }
                    } else {
                        Button("Join") {
                            model.joinLink(link) { group in
                                dismiss()
                                opened(group)
                            }
                        }
                        .disabled(code == nil || !model.canWrite || !model.speaksJoinCodes)
                    }
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $scanning) {
                NavigationStack {
                    ScannerView(accepts: { JoinCode.read($0) != nil }, refusal: "That code is not a Tern join code.") { found in
                        text = found
                        scanning = false
                    }
                    .ignoresSafeArea()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { scanning = false }
                        }
                    }
                }
            }
            #endif
            .showsProblems()
        }
        .frame(minWidth: 360, minHeight: 280)
    }
}
