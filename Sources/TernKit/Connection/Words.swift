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
        case ErrorCode.notAnImage: "That is not firmware this node runs, or it is not signed by a key this node trusts."
        case ErrorCode.notAContact: "That address is not one of the node's contacts."
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
        case .untrusted:
            "The node refused the image: it is not signed by a key this node trusts. Nothing was sent, and the node runs what it ran before."
        case let .refused(code): error(code)
        case .confused: "The node answered something the update did not expect."
        case .cancelled: "Update cancelled."
        }
    }

    /// A node a client cannot update: flashed over USB, from the site's flash page.
    public static let updateOverUSB =
        "This node can't be updated over Bluetooth. Update it over USB at ternmesh.org/flash."

    /// What is known of who made an image, said before it is sent, nil when it is a release's.
    public static func signature(_ check: ImageSignature.Check) -> String? {
        switch check {
        case .verified: nil
        case .notVerified:
            "This firmware's signature does not match a Tern release key this app holds. It may not be "
                + "the release's: someone may have changed it. Install it only if you know where it came from."
        case .unsigned:
            "This firmware is not signed: it was published before Tern's releases were signed. The app "
                + "cannot tell that it is the release's. Install it only if you trust where it came from."
        }
    }

    /// Why an image that is not signed is not offered to a node that checks signatures.
    public static let unsignedToCheckingNode =
        "This node takes only firmware signed by a Tern release key, and this release was published "
        + "before releases were signed, so the node would refuse it. Update it over USB at ternmesh.org/flash, "
        + "or wait for a signed release."

    /// Said before an update by the bootloader, which checks no signature.
    public static let bootloaderWindow =
        "While the node waits in its bootloader, anyone in Bluetooth range can install firmware on it, "
        + "until the update finishes. The app sends the firmware as soon as the bootloader appears."

    /// When pairing with a node fails: a node takes a passkey it does not show on a screen only for
    /// three minutes after someone has been at it.
    public static let pairingWindow =
        "Pairing failed. Press the node's button, or turn it off and on (on a board with no button, "
        + "press RESET), then pair within 3 minutes. If the node shows a PIN on its screen, type that one."

    /// What `WIPE` does, said before the user confirms it.
    public static let wipeWarning =
        "This erases the node for good: its address, contacts, groups, messages, settings and Bluetooth "
        + "pairings. It starts again as a new node with a new address, and must be paired again. "
        + "No one can undo this, and the people who have this node as a contact will no longer reach it."

    /// What to do once the node has wiped itself: the operating system keeps its bond, which an
    /// app cannot remove.
    public static let wipeForgetBond =
        "The node has been erased, and the app has forgotten it. Remove it from Bluetooth too: in "
        + "Settings, Bluetooth (System Settings on a Mac), choose the node and Forget This Device. "
        + "Then connect to it again as a new node."

    /// How long an update by the bootloader takes, said before it starts.
    public static let bootloaderUpdateTakes =
        "This takes about 5 minutes. Keep your phone near the node, with the app open, until it is done."

    /// Where an update by the bootloader is.
    public static func bootloader(_ phase: BootloaderUpdater.Phase) -> String {
        switch phase {
        case .idle: "Starting…"
        case .asking: "Asking the node to restart into its bootloader…"
        case .looking: "Looking for the node's bootloader…"
        case .transferring(.erasing): "Erasing the old firmware. This takes up to a minute or two…"
        case .transferring(.initializing): "Starting the transfer…"
        case let .transferring(.sending(sent, size)): "Sending: \(sent * 100 / max(size, 1))%"
        case .transferring(.validating): "Checking the firmware…"
        case .transferring(.activating): "Starting the new firmware…"
        case let .finished(outcome): bootloader(outcome)
        }
    }

    /// How an update by the bootloader ended. After any failure past the node's restart, the node
    /// is in its bootloader, which waits for an image: saying so is what tells the user a retry
    /// will work, and that nothing the node held is lost.
    public static func bootloader(_ outcome: BootloaderOutcome) -> String {
        let waiting = "The node is waiting in its bootloader, and keeps everything it held: update again to finish."
        switch outcome {
        case .activated: return "The bootloader has the new firmware, and is starting it."
        case .refused(ErrorCode.noRoom), .unsupported: return updateOverUSB
        case let .refused(code): return error(code)
        case .confused: return "The node answered something the update did not expect."
        case .notFound:
            return "The node's bootloader was not found. Keep your phone near the node and update again; "
                + "if the node is running as before, it did not restart."
        case .failed(.refused(_, DFU.operationFailed)):
            return "The bootloader stopped part of the way. " + waiting
        case .failed(.refused(_, DFU.crcError)):
            return "The firmware did not arrive intact. " + waiting
        case .failed(.noAnswer):
            return "The bootloader stopped answering. " + waiting
        case .failed(.wasMidSession):
            return "The bootloader was busy with an earlier transfer, and has restarted. " + waiting
        case .failed:
            return "The update was cut off. " + waiting
        case .cancelled:
            return "Update stopped. " + waiting
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

    /// A group message's sender: this node for 0, else the contact `names` has for its routing id
    /// (`Records.routingNames`), said to be claimed, else the id's eight hex digits. Any member can
    /// write any routing id, so a name it matches is never shown as a contact's is
    /// (draft/groups.md, Receiving).
    public static func sender(_ id: UInt32, names: [UInt32: String] = [:]) -> String {
        if id == 0 { return "You" }
        return names[id].map { "\($0) (claimed)" } ?? routingId(id)
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

    /// What a node's sleeping does now, as one line: its keeper, or the relay it will try again,
    /// named from `names` (`Records.routingNames`) where it can be, else in hex.
    public static func sleep(_ s: Sleep, names: [UInt32: String] = [:]) -> String {
        let relay = names[s.keeper] ?? routingId(s.keeper)
        switch s.state {
        case Sleep.awake: return "Awake"
        case Sleep.asleep: return "Asleep — kept by \(relay)"
        case Sleep.waiting: return "Waiting for a relay to keep its messages"
        case Sleep.resting:
            return "No relay answers; trying \(relay) again in \(duration(UInt32(s.retry)))"
        default: return "Sleep state \(s.state)"
        }
    }

    /// A contact that sleeps, waking at least every `seconds`.
    public static func wakes(_ seconds: Int) -> String {
        "Sleeps, wakes every \(duration(UInt32(seconds)))"
    }

    /// Said of a message sent, not yet delivered, to a contact that sleeps.
    public static func heldUntilWake(_ seconds: Int) -> String {
        "Held by its relay until it wakes, within \(duration(UInt32(seconds)))"
    }

    /// What sleeping costs, said when the user turns it on.
    public static let sleepTradeoff =
        "Sleeping turns the node's radio off between check-ins, so its battery lasts far longer. A relay "
        + "nearby holds its messages meanwhile: messages to it wait until it next wakes, up to the interval "
        + "you choose."

    /// Said to a relay's user: the setting is kept, and used once it is a leaf.
    public static let relaysNeverSleep =
        "Relays never sleep: they keep messages for the leaves that do. This setting applies when the "
        + "node is a leaf."

    /// The bytes of `text` as `SEND` counts them, against the 128 a message may have.
    public static func textBytes(_ text: String) -> Int { text.utf8.count }
}
