# Tern for iPhone, iPad and Mac

The Apple app for **Tern**, a LoRa mesh protocol that treats airtime as a
shared, metered resource. It drives a Tern node over Bluetooth LE through
the [companion protocol](https://github.com/ternmesh/spec/blob/main/draft/companion.md),
in Swift and SwiftUI.

What the app is, and why it is native, is in
[decisions/phone-apps.md](https://github.com/ternmesh/spec/blob/main/decisions/phone-apps.md).
It finds a node over Bluetooth LE, pairs with it by passkey, and from then on keeps it connected
whenever it is in range, in the background too: chats with contacts and groups, invites, contacts
and the addresses the node refused, and the node's battery, airtime, neighbours and settings.

```bash
brew install xcodegen && xcodegen && open Tern.xcodeproj   # the app, for iPhone, iPad and Mac
swift test        # TernKit: the protocol, the connection and the records, against the specification's vectors
```

The app needs Xcode 15 or later, and runs on iOS 16 and macOS 13 or later. `xcodegen` writes
`Tern.xcodeproj` from `project.yml`; the project file is not committed. Choose a team under
Signing to run it on a device.

TernKit needs Swift 5.9 or later. Everything in it but the Bluetooth link uses only the standard
library, so the tests run on Linux too. Open `Package.swift` in Xcode to work on it alone.

## Where things are

| Path | |
|---|---|
| `Sources/TernKit/Companion/Frame.swift` | Every frame of the protocol's version 3, as Swift types, and its numbers. |
| `Sources/TernKit/Companion/Codec.swift` | A frame built into bytes, and read back from them. |
| `Sources/TernKit/Companion/ByteStream.swift` | Frames on a byte stream (USB serial, TCP), with the node's console text between them. Bluetooth does not need it. |
| `Sources/TernKit/Connection/Connection.swift` | One connection, the client's half: `HELLO` and the version both speak, one request at a time, counted news, syncing again, and the `PING` that keeps a node from taking the app for gone. No I/O and no clock of its own: a link hands it frames and calls `tick()`. |
| `Sources/TernKit/Connection/Records.swift` | What the node has said it holds, as news leaves it, and the `after` the next sync asks from. |
| `Sources/TernKit/Connection/RecordsFile.swift` | The records on disk: a short header, then each record as the frame that carried it. The Android app writes the same bytes. |
| `Sources/TernKit/Connection/Conversations.swift` | The records as conversations, with what is unread; the `through` a `READ` may go to without marking another conversation's; and what is new enough to notify of. |
| `Sources/TernKit/Connection/Words.swift` | The protocol's numbers in words: states, reasons, refusals, roles. |
| `Sources/TernKit/Bluetooth/BluetoothLink.swift` | Core Bluetooth: scanning, connecting, pairing, the MTU, a frame to each write and notification, reconnecting to the remembered node, and restoring in the background. Built only where Core Bluetooth is. |
| `App/` | The app in SwiftUI: `NodeModel` (the link, the connection and the records, kept on disk), and the Connect, Chats, chat, Contacts and Node screens. |
| `project.yml` | The Xcode project, for XcodeGen: one target for iOS and macOS. |
| `Tests/TernKitTests/` | The conformance section of the specification, as a client: the codec against every vector, and the connection as the client in `exchange` and `older`. The records file, conversations and `READ`'s rule. |

The vectors' `group_ids` are not run here. A client never holds a group's secret, since no frame
carries one, so working out an id from it is the node's part.

`Tests/TernKitTests/vectors/companion.json` is a copy of the specification's
[`vectors/companion.json`](https://github.com/ternmesh/spec/blob/main/vectors/companion.json).
CI runs the tests against the copy, and against the specification's own as it is on `main`, which
also runs once a week: if the specification changes, that job fails or warns. Copy the new file
here in the pull request that changes the code to match.

CI builds the app for the iOS simulator and for the Mac, unsigned, as well as testing TernKit.

## Still to come

* Sharing an address by QR code and link, and its short code to compare aloud, per
  [draft/sharing.md](https://github.com/ternmesh/spec/blob/main/draft/sharing.md), which is still
  a strawman.
* Names for neighbours and group members, by working out the routing id of each address known.
* USB serial on the Mac, over `ByteStream`.
* Tests of the app's screens, and of the Bluetooth link against a node.

* [CONTRIBUTING.md](CONTRIBUTING.md) — DCO sign-off, and the specification first
* [Governance](https://github.com/ternmesh/spec/blob/main/GOVERNANCE.md)
