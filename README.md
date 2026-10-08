# Tern for iPhone, iPad and Mac

The Apple app for **Tern**, a LoRa mesh protocol that treats airtime as a
shared, metered resource. It drives a Tern node over Bluetooth LE through
the [companion protocol](https://github.com/ternmesh/spec/blob/main/draft/companion.md),
in Swift and SwiftUI.

What the app is, and why it is native, is in
[decisions/phone-apps.md](https://github.com/ternmesh/spec/blob/main/decisions/phone-apps.md).
So far there is its protocol and the connection that speaks it, and no app around them.

```bash
swift test        # the companion protocol and the connection, against the specification's vectors
```

Swift 5.9 or later (Xcode 15). The package uses only the standard library, so the tests run on
Linux too. Open `Package.swift` in Xcode to work on it there.

## Where things are

| Path | |
|---|---|
| `Sources/TernKit/Companion/Frame.swift` | Every frame of the protocol's version 3, as Swift types, and its numbers. |
| `Sources/TernKit/Companion/Codec.swift` | A frame built into bytes, and read back from them. |
| `Sources/TernKit/Companion/ByteStream.swift` | Frames on a byte stream (USB serial, TCP), with the node's console text between them. Bluetooth does not need it. |
| `Sources/TernKit/Connection/Connection.swift` | One connection, the client's half: `HELLO` and the version both speak, one request at a time, counted news, syncing again, and the `PING` that keeps a node from taking the app for gone. No I/O and no clock of its own: a link hands it frames and calls `tick()`. |
| `Sources/TernKit/Connection/Records.swift` | What the node has said it holds, as news leaves it, and the `after` the next sync asks from. |
| `Tests/TernKitTests/` | The conformance section of the specification, as a client: the codec against every vector, and the connection as the client in `exchange` and `older`. |

The vectors' `group_ids` are not run here. A client never holds a group's secret, since no frame
carries one, so working out an id from it is the node's part.

`Tests/TernKitTests/vectors/companion.json` is a copy of the specification's
[`vectors/companion.json`](https://github.com/ternmesh/spec/blob/main/vectors/companion.json).
CI runs the tests against the copy, and against the specification's own as it is on `main`, which
also runs once a week: if the specification changes, that job fails or warns. Copy the new file
here in the pull request that changes the code to match.

## Still to come

* Bluetooth LE through Core Bluetooth: the service, an MTU of at least 183, and passkey pairing.
* The app itself, in SwiftUI, for iPhone, iPad and Mac.

* [CONTRIBUTING.md](CONTRIBUTING.md) — DCO sign-off, and the specification first
* [Governance](https://github.com/ternmesh/spec/blob/main/GOVERNANCE.md)
