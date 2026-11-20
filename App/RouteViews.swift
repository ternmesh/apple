// Finding out how frames go (version 18): the details of how a message went; a trace to one node,
// its hops out and back with how well each heard the one before; and a range test, numbered
// messages to a contact while the user moves, each logged with where the phone was and what became
// of it, to export as CSV. The words are TernKit's (RouteWords), the same as the Android app's.

import SwiftUI
import TernKit
#if os(iOS)
import UIKit
#else
import AppKit
import UniformTypeIdentifiers
#endif

// MARK: How a message went

/// Everything the node said of how `item` went, in plain words.
struct RouteDetailsSheet: View {
    let item: Item
    @EnvironmentObject private var model: NodeModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let details = RouteWords.facts(
            item, model.records.routes[item.id], records: model.records, names: model.routeNames)
        NavigationStack {
            Form {
                if !details.facts.isEmpty {
                    SwiftUI.Section {
                        ForEach(details.facts, id: \.label) { fact in
                            LabeledContent(fact.label, value: fact.value)
                        }
                    }
                }
                SwiftUI.Section {
                    ForEach(details.notes, id: \.self) { note in
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("How It Went")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 360)
    }
}

// MARK: Traces

/// A trace to the routing id `to`: begun on opening, unless one to it is already out, and again
/// when asked. While it is out it says where it is; once it ends, how, and each node on the way out
/// and back, by name where the app has one, with how well it heard the one before. A node with no
/// name is given one on tapping it.
struct TraceView: View {
    let to: UInt32
    @EnvironmentObject private var model: NodeModel
    @State private var begun = false
    @State private var naming: UInt32?

    var body: some View {
        let names = model.routeNames
        let target = names.label(to)
        let run = model.traces[to]
        let ready = model.isReady && model.speaksRoutes
        Form {
            SwiftUI.Section {
                if !model.speaksRoutes {
                    Text(RouteWords.needsUpdate).foregroundStyle(.secondary)
                } else {
                    status(run, target: target)
                    Button(run == nil ? "Trace" : "Trace Again") { model.trace(to) }
                        .disabled(!ready || run?.isRunning == true)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(RouteWords.explained(target))
                    // A leaf with no session with this node drops the trace: said before it runs.
                    if model.records.isLeafWithoutSession(to), run?.traced == nil { Text(RouteWords.leafHint) }
                }
            }
            if let traced = run?.traced, traced.wasAnswered {
                SwiftUI.Section("Way out") {
                    hopRow(title: "You", snr: nil)
                    ForEach(Array(traced.wayOut.enumerated()), id: \.offset) { i, hop in
                        hopRow(hop, names: names, answerer: i == traced.wayOut.count - 1)
                    }
                }
                SwiftUI.Section {
                    ForEach(Array(traced.wayBack.enumerated()), id: \.offset) { _, hop in
                        hopRow(hop, names: names, answerer: false)
                    }
                    hopRow(title: "You", snr: traced.snr)
                } header: {
                    Text("Way back")
                } footer: {
                    if traced.hops.contains(where: { names.isNameable($0.routingId) }) { Text(RouteWords.nameHint) }
                }
            }
            SwiftUI.Section {
                Text(RouteWords.disclaimer).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Trace to \(target)")
        .onAppear(perform: begin)
        .onChange(of: ready) { _ in begin() }
        .namesRelay($naming)
        .showsProblems()
    }

    /// The first trace, once the node can be asked: on opening, or when it is ready.
    private func begin() {
        guard !begun, model.isReady, model.speaksRoutes else { return }
        begun = true
        if model.traces[to]?.isRunning != true { model.trace(to) }
    }

    @ViewBuilder
    private func status(_ run: TraceRun?, target: String) -> some View {
        if let run {
            if run.isRunning {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(RouteWords.step(run))
                }
            } else if let failed = run.failed {
                Text("Not traced: \(Words.failure(failed))").foregroundStyle(.red)
            } else if let traced = run.traced {
                VStack(alignment: .leading, spacing: 4) {
                    Text(RouteWords.result(traced, target: target, records: model.records, names: model.routeNames))
                        .font(.headline)
                    if traced.wasAnswered {
                        Text(RouteWords.summary(traced)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// One node a trace passed through, and how well it heard the one before; tapping one no
    /// contact has names it.
    @ViewBuilder
    private func hopRow(_ hop: TraceHop, names: RouteNames, answerer: Bool) -> some View {
        let known = names.name(hop.routingId)
        let row = HopRow(
            title: known ?? Words.routingId(hop.routingId), mono: known == nil, snr: hop.snrQuarterDb,
            tag: answerer ? "answered" : nil)
        if names.isNameable(hop.routingId) {
            Button { naming = hop.routingId } label: { row }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.primary)
                .accessibilityHint("Names this node on this device")
        } else {
            row
        }
    }

    private func hopRow(title: String, snr: Int8?) -> some View {
        HopRow(title: title, mono: false, snr: snr, tag: nil)
    }
}

private struct HopRow: View {
    let title: String
    let mono: Bool
    let snr: Int8?
    let tag: String?

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: title, key: title, unknown: mono, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).fontWeight(.semibold).font(mono ? .body.monospaced() : .body)
                    if let tag { Tag(tag, tint: .good) }
                }
                if let snr {
                    Text("heard at \(RouteWords.snrLine(snr))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let snr { SignalBars(quarterDb: snr) }
        }
        .contentShape(Rectangle())
    }
}

extension View {
    /// Asks for a name for the routing id `id` names, on this device alone: a relay, or any node no
    /// contact names.
    func namesRelay(_ id: Binding<UInt32?>) -> some View { modifier(NameRelayAlert(id: id)) }
}

private struct NameRelayAlert: ViewModifier {
    @EnvironmentObject private var model: NodeModel
    @Binding var id: UInt32?
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert(
                "Name this node",
                isPresented: Binding(get: { id != nil }, set: { if !$0 { id = nil } }),
                presenting: id
            ) { which in
                TextField("Name", text: $name)
                Button("Save") { model.nameRelay(which, name) }
                Button("Cancel", role: .cancel) {}
            } message: { which in
                Text(Words.routingId(which) + "\n\n" + RouteWords.nameExplained)
            }
            .onChange(of: id) { which in name = which.flatMap { model.relayNames[$0] } ?? "" }
    }
}

/// Trace Route, for a menu: disabled, saying why, for a node of version 17.
struct TraceRouteButton: View {
    let address: Address
    let open: () -> Void
    @EnvironmentObject private var model: NodeModel

    var body: some View {
        Button(action: open) {
            if model.speaksRoutes {
                Text("Trace Route")
            } else {
                Text("Trace Route")
                Text(RouteWords.needsUpdate)
            }
        }
        .disabled(!model.speaksRoutes)
    }
}

// MARK: The range test

/// The range test: a contact and how often, Start and Stop, and the log, newest first, each ping
/// with when it went, where the phone was, and what became of it. While it runs, the iPhone's
/// screen stays on. It goes on while the user looks at another tab; leaving its screen ends it,
/// after asking if there is a log. Export saves the log as CSV.
struct RangeTestView: View {
    /// The contact to begin with, or nil for the user to choose.
    let initial: Address?
    @EnvironmentObject private var model: NodeModel
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Address?
    @State private var seconds = RangeTest.defaultInterval
    @State private var leaving = false
    @State private var now = Date()

    var body: some View {
        let range = model.range
        let running = model.rangeRunning
        // While it runs, the contact it pings; stopped, the one chosen next, or the last.
        let to = running ? range?.to : chosen ?? initial ?? range?.to
        let logged = !(range?.pings.isEmpty ?? true)
        let rows = range?.rows(model.records) ?? []
        let names = model.routeNames
        Form {
            SwiftUI.Section {
                Picker("To", selection: Binding(get: { to }, set: { chosen = $0 })) {
                    if to == nil { Text("Choose a contact").tag(Address?.none) }
                    ForEach(choices(to), id: \.self) { a in
                        Text(model.records.name(of: .contact(a))).tag(Address?.some(a))
                    }
                }
                .disabled(running)
                VStack(alignment: .leading) {
                    Text("Every \(Int(seconds)) s")
                    Slider(value: $seconds, in: RangeTest.intervals, step: 5)
                }
                .disabled(running)
            } footer: {
                Text("Sends \(to.map { model.records.name(of: .contact($0)) } ?? "a contact") a numbered message every so "
                    + "often, and logs each: where this \(deviceWord) was, whether it was delivered and how. Keep this screen "
                    + "open while you move" + (isPhone ? "; the screen stays on." : "."))
            }
            SwiftUI.Section {
                if running {
                    Button("Stop") { model.stopRangeTest() }
                } else {
                    Button("Start") { if let to { model.startRangeTest(to: to, interval: seconds) } }
                        .disabled(to == nil || !model.isConnected)
                }
                if logged { Button("Export CSV…") { export() } }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if logged || running {
                        let tally = RangeTest.tally(rows)
                        Text([
                            running ? "Running: next in \(max(0, Int(((range?.nextAt ?? 0) - now.timeIntervalSince1970).rounded(.up)))) s"
                                : "Stopped",
                            "Delivered: \(tally.delivered) of \(tally.sent)",
                        ].joined(separator: " · "))
                        .fontWeight(.semibold)
                    }
                    if !model.rangeCanLocate {
                        HStack {
                            Text("No location: the log won't say where you were.")
                            Button("Allow Location") { model.allowRangeLocation() }.buttonStyle(.borderless)
                        }
                    }
                    if model.agreed != nil && !model.speaksRoutes {
                        Text("This node's firmware says only whether each was delivered. Update it for hops, signal and round trip.")
                    }
                }
            }
            if !rows.isEmpty {
                SwiftUI.Section("Log") {
                    ForEach(rows.reversed()) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("#\(row.ping.n) · \(Date(timeIntervalSince1970: row.ping.at).formatted(date: .omitted, time: .standard))")
                                .font(.subheadline.weight(.semibold))
                            Text(RouteWords.rangeRow(row, names: names)).font(.subheadline)
                            Text(fixText(row.ping.fix)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Range Test")
        .navigationBarBackButtonHidden(logged)
        .toolbar {
            if logged {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { leaving = true }
                }
            }
        }
        .confirmationDialog("Stop the range test?", isPresented: $leaving, titleVisibility: .visible) {
            Button("Leave", role: .destructive) {
                model.closeRangeTest()
                dismiss()
            }
            // After the dialog has gone: the share sheet cannot come up over it.
            Button("Export CSV…") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { export() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its log goes when you leave. Export it first to keep it.")
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
        .showsProblems()
    }

    /// The contacts, and the address chosen if it is none of them: a chat with an address not saved.
    private func choices(_ to: Address?) -> [Address] {
        let contacts = sortedContacts(model.records).map(\.address)
        guard let to, !contacts.contains(to) else { return contacts }
        return [to] + contacts
    }

    private var isPhone: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    private var deviceWord: String { isPhone ? "phone" : "computer" }

    private func fixText(_ fix: PhoneFix?) -> String {
        guard let f = fix else { return "no fix" }
        let at = String(format: "%.5f, %.5f", f.lat, f.lon)
        return f.accuracy.map { at + " ±\(Int($0.rounded())) m" } ?? at
    }

    /// The log as a CSV file: shared from the iPhone, saved where the user chooses on a Mac.
    private func export() {
        guard let range = model.range else { return }
        let names = model.routeNames
        let time = ISO8601DateFormatter()
        time.timeZone = .current
        let csv = range.csv(range.rows(model.records), time: { time.string(from: Date(timeIntervalSince1970: $0)) }) {
            names.name($0)
        }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let file = "tern-range-\(stamp.string(from: Date(timeIntervalSince1970: range.startedAt))).csv"
        #if os(iOS)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(file)
        do {
            try Data(csv.utf8).write(to: url, options: .atomic)
        } catch {
            model.problem = "The log could not be written: \(error.localizedDescription)"
            return
        }
        share(url)
        #else
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(csv.utf8).write(to: url, options: .atomic)
        } catch {
            model.problem = "The log could not be saved: \(error.localizedDescription)"
        }
        #endif
    }

    #if os(iOS)
    /// The share sheet, over whatever is on screen.
    private func share(_ url: URL) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let shown = top.presentedViewController { top = shown }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // On an iPad it is a popover, which needs somewhere to point.
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(
            x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        sheet.popoverPresentationController?.permittedArrowDirections = []
        top.present(sheet, animated: true)
    }
    #endif
}
