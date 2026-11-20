// How a message went, and traces (version 18), in the user's words: the line under each message,
// the details behind it, what a trace found and where one is. Routing ids are named as the app
// knows them: this node, a contact, a name the user gave on this device, or a card's claim. The
// Android app says the same, word for word.

/// What the app calls each routing id: worked out once from the records, as a screen needs it.
public struct RouteNames: Sendable {
    /// The node's own routing id, if it has said its address.
    public let mine: UInt32?
    /// What the user calls each contact, by its routing id.
    public let contacts: [UInt32: String]
    /// The names the user gave routing ids no contact has, on this device alone.
    public let given: [UInt32: String]
    /// The cards held, by routing id, for an id no contact has.
    public let cards: [UInt32: Card]

    public init(_ records: Records, given: [UInt32: String] = [:]) {
        mine = records.me.map { records.routingId(of: $0.address) }
        contacts = records.routingNames
        self.given = given
        cards = records.routingCards
    }

    /// "your node" for its own, the contact with it, the name the user gave it, or the name a card
    /// held from it claims, in quotes; nil for none.
    public func name(_ id: UInt32) -> String? {
        if id == mine { return "your node" }
        if let name = contacts[id] { return name }
        if let name = given[id] { return name }
        if let card = cards[id], !card.name.isEmpty { return Words.cardName(card.name) }
        return nil
    }

    /// `name(_:)`, or the id itself, eight hex digits in one word.
    public func label(_ id: UInt32) -> String { name(id) ?? Words.routingId(id) }

    /// Whether the user may give `id` a name of their own: neither this node, nor a contact's.
    public func isNameable(_ id: UInt32) -> Bool { id != mine && contacts[id] == nil }
}

/// A trace the user began to the routing id `to` (version 18), from the request until it ends:
/// `id` once the node took it, where it is on the air from its `STATE` (`state`, `reason` and
/// `wait`, as a message's), and how it ended, `traced`; or `failed`, when the node did not take it.
public struct TraceRun: Equatable, Sendable {
    public var to: UInt32
    public var id: UInt32?
    public var state: UInt8?
    public var reason: UInt8 = 0
    public var wait: UInt16 = 0
    public var traced: Traced?
    public var failed: RequestFailure?

    public init(
        to: UInt32, id: UInt32? = nil, state: UInt8? = nil, reason: UInt8 = 0, wait: UInt16 = 0, traced: Traced? = nil,
        failed: RequestFailure? = nil
    ) {
        self.to = to
        self.id = id
        self.state = state
        self.reason = reason
        self.wait = wait
        self.traced = traced
        self.failed = failed
    }

    /// Still on its way: neither ended nor refused.
    public var isRunning: Bool { traced == nil && failed == nil }
}

extension Records {
    /// Whether the node with routing id `id` is a neighbour the node hears as a leaf.
    public func isLeaf(_ id: UInt32) -> Bool { neighbours[id]?.role == 0 }

    /// Whether the node with routing id `id` is one a trace from this node will not be answered by:
    /// a neighbour that is a leaf, which answers traces only from a node it shares a session with,
    /// and shares none with this one. A leaf that is not a neighbour is not known to be one.
    public func isLeafWithoutSession(_ id: UInt32) -> Bool {
        isLeaf(id) && contact(routingId: id).flatMap { contacts[$0]?.session } != 1
    }

    /// The routing id of where `item` was sent: its contact's; nil for a group message.
    func destination(of item: Item) -> UInt32? {
        switch item {
        case let .message(m): routingId(of: m.contact)
        case let .invite(i): routingId(of: i.contact)
        case .groupMessage: nil
        }
    }
}

public enum RouteWords {
    /// Said where a trace is shown: what it can and cannot tell.
    public static let disclaimer =
        "A trace shows the way frames went just then; the next message may go another way. Relays on the "
        + "way can misreport it, and nothing checks what they add."
    /// Said to a user whose node is of version 17.
    public static let needsUpdate = "Update the node's firmware to trace"
    /// Said before a trace to a leaf that shares no session with this node, and after one unanswered.
    public static let leafHint = "Handhelds (leaves) answer traces only from nodes they have a secure session with."
    /// Said under a trace with a node in it that the user may name.
    public static let nameHint = "Tap a node with no name to give it one on this device."
    public static let nameExplained = "Only this device shows the name. Nothing is sent, and a contact's name comes first."

    /// A signal-to-noise ratio in quarters of a dB, in dB to a tenth: "5.5 dB", "-2.3 dB".
    public static func snr(_ quarters: Int8) -> String {
        let q = Int(quarters)
        // Tenths, rounded half away from zero: q / 4 * 10 = q * 2.5.
        let tenths = (abs(q) * 25 + 5) / 10
        return "\(q < 0 && tenths != 0 ? "-" : "")\(tenths / 10).\(tenths % 10) dB"
    }

    /// "SNR 5.5 dB".
    public static func snrLine(_ quarters: Int8) -> String { "SNR " + snr(quarters) }

    /// Milliseconds as seconds, to a tenth: "3.1 s".
    public static func took(_ ms: UInt32) -> String {
        let tenths = (UInt64(ms) + 50) / 100
        return "\(tenths / 10).\(tenths % 10) s"
    }

    /// How many hops: "Direct" for one, else "3 hops".
    public static func hops(_ hops: UInt8) -> String {
        hops == 1 ? "Direct" : plural(Int(hops), "hop")
    }

    /// How many hops a sent message's acknowledgement came back: "reply direct", "reply 2 hops".
    static func reply(_ hops: UInt8) -> String {
        hops == 1 ? "reply direct" : "reply " + plural(Int(hops), "hop")
    }

    static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n) \(n == 1 ? one : many ?? one + "s")"
    }

    /// The line under a message that says how it went, from its `route`: nil with none, or nothing
    /// to say yet. Received, how many hops it came and how well the last was heard; a group message
    /// came at most that far. Sent, the neighbour it went to and, once delivered, the hops of the
    /// acknowledgement's way back, and the round trip.
    public static func line(_ item: Item, _ route: Route?, records: Records, names: RouteNames) -> String? {
        guard let route else { return nil }
        if item.isReceived {
            guard route.hops != 0 else { return nil }
            let hops: String
            if case .groupMessage = item, route.hops > 1 {
                hops = "≤" + plural(Int(route.hops), "hop")
            } else {
                hops = self.hops(route.hops)
            }
            return hops + " · " + snrLine(route.snr)
        }
        if case .groupMessage = item {
            guard route.goes > 0 else { return nil }
            return route.goes == 1 ? "Went out once" : "Went out \(route.goes) times"
        }
        guard route.via != 0 else { return nil }
        let direct = route.via == records.destination(of: item)
        let via = names.label(route.via)
        var parts: [String] = []
        switch item.state {
        case MessageState.delivered:
            parts.append(direct ? "Delivered direct" : "Delivered via \(via)")
            // The hops are the acknowledgement's, back: not how the message went out.
            if route.hops > 0, !(direct && route.hops == 1) { parts.append(reply(route.hops)) }
            if route.took > 0 { parts.append(took(route.took)) }
        case MessageState.notDelivered:
            parts.append(direct ? "Last tried direct" : "Last tried via \(via)")
            if route.goes > 0 { parts.append(plural(Int(route.goes), "try", "tries")) }
        default:
            parts.append(direct ? "Sent direct" : "Sent via \(via)")
            if route.goes > 1 { parts.append("try \(route.goes)") }
        }
        return parts.joined(separator: " · ")
    }

    /// Every field of `route`, each as a label and what it says, for the details behind a message;
    /// and, after them, what to bear in mind reading them.
    public static func facts(
        _ item: Item, _ route: Route?, records: Records, names: RouteNames
    ) -> (facts: [(label: String, value: String)], notes: [String]) {
        var facts: [(label: String, value: String)] = []
        var notes: [String] = []
        guard let route else {
            notes.append("Your node hasn't said how this one went. It keeps that only for messages since its "
                + "firmware could, and may lose it when it restarts.")
            return (facts, notes)
        }
        func signal() {
            facts.append(("Signal-to-noise of the last hop", snr(route.snr)))
            facts.append(("Signal strength of the last hop", "\(route.rssi) dBm"))
        }
        if item.isReceived {
            var group = false
            if case .groupMessage = item { group = true }
            let came: String
            if route.hops == 0 {
                came = "Not known"
            } else if route.hops == 1 {
                came = "Straight from the other node: 1 hop"
            } else if group {
                came = "At most \(plural(Int(route.hops), "hop")): \(route.hops) or \(route.hops - 1)"
            } else {
                let relays = Int(route.hops) - 1
                came = "\(route.hops) hops: \(plural(relays, "relay")) passed it on"
            }
            facts.append(("Came", came))
            if route.hops > 0 { signal() }
            if group {
                notes.append("A group message's writer hides how far off it is, so it may have come one hop less than this.")
            }
            notes.append("No message names the relays that passed it on. A trace does: Trace Route, in the chat's menu.")
            return (facts, notes)
        }
        if case .groupMessage = item {
            facts.append(("Sent out", route.goes == 1 ? "once" : "\(route.goes) times"))
            return (facts, notes)
        }
        let first: String
        if route.via == 0 {
            first = "Nowhere yet"
        } else if route.via == records.destination(of: item) {
            first = "Straight to \(names.label(route.via))"
        } else {
            first = "\(names.label(route.via)) (\(Words.routingId(route.via)))"
        }
        facts.append(("First went to", first))
        facts.append(("Tries on the air", "\(route.goes)"))
        if item.state == MessageState.delivered, route.hops > 0 {
            facts.append(("Acknowledgement came back", hops(route.hops)))
            signal()
            facts.append(("Round trip", took(route.took)))
            notes.append("The hops and signal are the acknowledgement's, on its way back. The other node sends it by "
                + "its own route: most often through the same relays, but not always.")
        } else {
            notes.append("Hops, signal and round trip come once it's delivered, from the acknowledgement on its way back.")
        }
        return (facts, notes)
    }

    /// What a trace does, said before it runs.
    public static func explained(_ target: String) -> String {
        "A trace goes out to \(target) the way your node's messages would, and comes back. Each node on the way "
            + "adds itself, and how well it heard the one before."
    }

    /// How a trace to `target` ended, in a sentence: who answered, or how far it got, or that it did
    /// not go. The node that answered is the last on the way out.
    public static func result(_ traced: Traced, target: String, records: Records, names: RouteNames) -> String {
        let answerer = traced.wayOut.last.map { names.label($0.routingId) } ?? "a relay"
        switch traced.result {
        case Traced.answered: return "Answered by \(target)"
        case Traced.keeper:
            return "Answered by \(answerer), which keeps \(target)'s messages while it sleeps: that's as far as they go until it wakes"
        case Traced.noRoute: return "Got as far as \(answerer), which has no route to \(target)"
        case Traced.notAnswered:
            // A leaf drops a trace from a node it shares no session with, on purpose: say so, not
            // that it may be out of reach.
            if records.isLeaf(traced.to) { return "No answer from \(target). " + leafHint }
            return "No answer in time. \(target) may be out of reach, or a relay on the way may not pass traces on."
        case Traced.notBegun: return "Not begun: your node has no route to \(target)"
        default: return "Ended (\(traced.result))"
        }
    }

    /// A trace answered, in numbers: "2 hops out · 1 hop back · 3.1 s". The way back counts the
    /// last hop, to this node.
    public static func summary(_ traced: Traced) -> String {
        [
            plural(traced.wayOut.count, "hop") + " out",
            plural(traced.wayBack.count + 1, "hop") + " back",
            took(traced.took),
        ].joined(separator: " · ")
    }

    /// Where a trace is before it ends: asking the node, waiting and what for, or out and waiting
    /// for an answer.
    public static func step(_ run: TraceRun) -> String {
        guard run.id != nil else { return "Handing it to your node…" }
        if run.state == MessageState.sent { return "Out: waiting for the answer…" }
        if run.state == MessageState.waiting, run.reason == 1 { return "Finding a route…" }
        if run.state == MessageState.waiting, run.reason >= 3 {
            let reason = run.reason <= 5 ? Words.reason(run.reason) : Words.reason(5)
            return "Waiting for \(reason)" + (run.wait > 0 ? " · about \(run.wait) s" : "")
        }
        return "Waiting to go…"
    }

    /// One ping of a range test, as its log shows it: what became of it, and how, when the node says.
    public static func rangeRow(_ row: RangeRow, names: RouteNames) -> String {
        let p = row.ping
        var parts: [String] = []
        switch (p.unsent, p.id, row.state) {
        case (.notConnected?, _, _): parts.append("Not sent: node not connected")
        case (.refused?, _, _): parts.append("Not sent: the node refused it")
        case (.unanswered?, _, _): parts.append("The node didn't answer")
        case (nil, nil, _): parts.append("Handing it to your node…")
        case (nil, _, MessageState.delivered?): parts.append("Delivered")
        case (nil, _, MessageState.notDelivered?): parts.append("Not delivered")
        case (nil, _, MessageState.sent?): parts.append("Sent")
        default: parts.append("Waiting")
        }
        if let route = row.route {
            if row.isDelivered, route.hops > 0 {
                parts.append(hops(route.hops))
                parts.append(snrLine(route.snr))
                parts.append("\(route.rssi) dBm")
                if route.took > 0 { parts.append(took(route.took)) }
            }
            if route.via != 0 { parts.append("via \(names.label(route.via))") }
        }
        return parts.joined(separator: " · ")
    }
}
