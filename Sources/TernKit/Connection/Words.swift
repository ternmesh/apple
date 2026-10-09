// The protocol's numbers in words a person reads: a message's state and why it waits, a node's
// refusals, its role. Here rather than in the screens so that they are checked with the rest, and
// so that each screen says the same thing.

public enum Words {
    /// A message's, group message's or invite's state.
    public static func state(_ state: UInt8) -> String {
        switch state {
        case MessageState.waiting: "Waiting"
        case MessageState.sent: "Sent"
        case MessageState.delivered: "Delivered"
        case MessageState.notDelivered: "Not delivered"
        case MessageState.received: "Received"
        default: "Unknown state \(state)"
        }
    }

    /// Why a waiting message waits.
    public static func reason(_ reason: UInt8) -> String {
        switch reason {
        case 0: "nothing the node can name"
        case 1: "looking for a route"
        case 2: "setting up a secure session"
        case 3: "the region's transmit limit"
        case 4: "the airtime budget"
        case 5: "the radio is busy"
        default: "reason \(reason)"
        }
    }

    /// A waiting message's state, why it waits and for how long the node thinks, as one line.
    public static func waiting(reason: UInt8, wait: UInt16) -> String {
        var line = state(MessageState.waiting)
        if reason != 0 { line += ": " + self.reason(reason) }
        if wait != 0 { line += ", about " + duration(UInt32(wait)) }
        return line
    }

    /// Seconds, as a person says them: `45 s`, `3 min`, `2 h`.
    public static func duration(_ seconds: UInt32) -> String {
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        if seconds < 86400 { return "\(seconds / 3600) h" }
        return "\(seconds / 86400) d"
    }

    /// An `ERROR`'s code. One this client does not know is a refusal it cannot name.
    public static func error(_ code: UInt8) -> String {
        switch code {
        case ErrorCode.undefined: "The node does not support this."
        case ErrorCode.malformed: "The node could not read the request."
        case ErrorCode.refused: "The node refused that value."
        case ErrorCode.badAddress: "That is not a valid address, or it is the node's own."
        case ErrorCode.noRoom: "The node has no room for another."
        case ErrorCode.helloFirst: "The node had taken the app for gone."
        case ErrorCode.mtu: "The Bluetooth link is too small for the node's frames."
        case ErrorCode.notNow: "The node is busy. Try again in a moment."
        case ErrorCode.notHeld: "The node does not hold that group or invite."
        case ErrorCode.notThere: "The node is not where the update was."
        case ErrorCode.notAnImage: "That is not firmware this node runs."
        default: "The node refused (\(code))."
        }
    }

    /// How an update ended, as it is known when it ends. The node's next `INFO` says the rest.
    public static func update(_ outcome: UpdateOutcome) -> String {
        switch outcome {
        case .restarting: "The node has the new firmware, and is restarting into it."
        case .unconfirmed: "The node did not answer at the end. It may be restarting into the new firmware."
        case .refused(ErrorCode.noRoom), .unsupported:
            "This node can't be updated over Bluetooth. Flash it once over USB at ternmesh.org/flash."
        case .refused(ErrorCode.notAnImage):
            "The node refused the image: it is not firmware this node runs. It discarded it, and runs what it ran before."
        case let .refused(code): error(code)
        case .confused: "The node answered something the update did not expect."
        case .cancelled: "Update cancelled."
        }
    }

    /// A request that came to nothing.
    public static func failure(_ failure: RequestFailure) -> String {
        switch failure {
        case let .refused(code): error(code)
        case .unsupported: "The node's version does not support this."
        case .noAnswer: "The node did not answer."
        case .closed: "Not connected."
        case .invalid: "Too long."
        }
    }

    /// `ASKED`'s `why`.
    public static func asked(_ why: UInt8) -> String {
        switch why {
        case 1: "Not in your contacts"
        case 2: "The node has no room for another session"
        default: "Refused"
        }
    }

    /// `role` in `SELF` and `NEIGHBOUR`.
    public static func role(_ role: UInt8) -> String {
        switch role {
        case 0: "Leaf"
        case 1: "Relay"
        default: "Role \(role)"
        }
    }

    /// A routing id, as the eight hex digits a group message's sender is known by; 0 is this node.
    public static func sender(_ id: UInt32) -> String {
        id == 0 ? "You" : routingId(id)
    }

    /// A routing id in hex, all eight digits.
    public static func routingId(_ id: UInt32) -> String {
        Hex.encode([UInt8(id >> 24), UInt8(id >> 16 & 0xFF), UInt8(id >> 8 & 0xFF), UInt8(id & 0xFF)])
    }

    /// A neighbour's SNR, from quarters of a dB.
    public static func snr(_ quarterDb: Int8) -> String {
        let q = Int(quarterDb)
        let whole = abs(q) / 4
        let frac = ["", ".25", ".5", ".75"][abs(q) % 4]
        return "\(q < 0 ? "-" : "")\(whole)\(frac) dB"
    }

    /// The bytes of `text` as `SEND` counts them, against the 128 a message may have.
    public static func textBytes(_ text: String) -> Int { text.utf8.count }
}
