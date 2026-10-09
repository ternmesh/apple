# Tern for iPhone, iPad and Mac

The Apple app for **Tern**, a LoRa mesh protocol that treats airtime as a
shared, metered resource. It drives a Tern node over Bluetooth LE through
the [companion protocol](https://github.com/ternmesh/spec/blob/main/draft/companion.md),
in Swift and SwiftUI.

What the app is, and why it is native, is in
[decisions/phone-apps.md](https://github.com/ternmesh/spec/blob/main/decisions/phone-apps.md).
It finds a node over Bluetooth LE, pairs with it by passkey, and from then on keeps it connected
whenever it is in range, in the background too: chats with contacts and groups, invites, contacts
and the addresses the node refused, the node's battery, airtime, neighbours and settings,
positions shared with the node on a map and sharing the user's own, and updates to its firmware
from [ternmesh.org](https://ternmesh.org/firmware/).

```bash
brew install xcodegen && xcodegen && open Tern.xcodeproj   # the app, for iPhone, iPad and Mac
swift test        # TernKit: the protocol, the connection, the records and updates, against the specification's vectors
```

The app needs Xcode 15 or later, and runs on iOS 16 and macOS 13 or later. `xcodegen` writes
`Tern.xcodeproj` from `project.yml`; the project file is not committed. Choose a team under
Signing to run it on a device.

TernKit needs Swift 5.9 or later. Everything in it but the Bluetooth link uses only the standard
library, so the tests run on Linux too. Open `Package.swift` in Xcode to work on it alone.

## Where things are

| Path | |
|---|---|
| `Sources/TernKit/Companion/Frame.swift` | Every frame of the protocol's version 6, as Swift types, and its numbers. |
| `Sources/TernKit/Companion/Codec.swift` | A frame built into bytes, and read back from them. |
| `Sources/TernKit/Companion/ByteStream.swift` | Frames on a byte stream (USB serial, TCP), with the node's console text between them. Bluetooth does not need it. |
| `Sources/TernKit/Connection/Connection.swift` | One connection, the client's half: `HELLO` and the version both speak, one request at a time, counted news, syncing again, and the `PING` that keeps a node from taking the app for gone. No I/O and no clock of its own: a link hands it frames and calls `tick()`. |
| `Sources/TernKit/Connection/Records.swift` | What the node has said it holds, as news leaves it, positions, sharing and cards included, and the `after` the next sync asks from. |
| `Sources/TernKit/Connection/RecordsFile.swift` | The records on disk: a short header, then each record as the frame that carried it, but for positions, sharing and cards, which every sync sends again. The Android app writes the same bytes. |
| `Sources/TernKit/Connection/Conversations.swift` | The records as conversations, with what is unread; the `through` a `READ` may go to without marking another conversation's; and what is new enough to notify of. |
| `Sources/TernKit/Connection/RoutingNames.swift` | An address's routing id, and the contacts' names by theirs: what a neighbour or a group message's writer shows as, when it is a contact. |
| `Sources/TernKit/Connection/Words.swift` | The protocol's numbers in words: states, reasons, refusals, roles, how an update ended. |
| `Sources/TernKit/Update/Updater.swift` | One firmware image sent to a node: `UPDATE_BEGIN`, on from the offset the node gives, `UPDATE_DATA` a chunk at a time, `UPDATE_END`, and going on after the link drops. Through the connection, with no I/O of its own. |
| `Sources/TernKit/Update/Release.swift` | The release manifest at `ternmesh.org/firmware/latest.json`, the image in it for a node's board and region, and Semantic Versioning's order, with the little JSON it needs. |
| `Sources/TernKit/Update/SHA256.swift` | SHA-256, for an image's digest: TernKit's own, so that it keeps to the standard library. |
| `Sources/TernKit/Bluetooth/BluetoothLink.swift` | Core Bluetooth: scanning, connecting, pairing, the MTU, a frame to each write and notification, reconnecting to the remembered node, and restoring in the background. Built only where Core Bluetooth is. |
| `App/` | The app in SwiftUI: `NodeModel` (the link, the connection and the records, kept on disk, the firmware it downloads and sends, and the phone's position given to the node while it shares, from `LocationFeed`), `Notifications` (a tap or a reply on one), and the Connect, Chats, chat, Contacts, Map and Node screens, with the share sheet. The map is MapKit's own view (`PositionMap`), which draws a cell before iOS 17 and macOS 14. |
| `project.yml` | The Xcode project, for XcodeGen: one target for iOS and macOS. |
| `Tests/TernKitTests/` | The conformance section of the specification, as a client: the codec against every vector, the connection as the client in `exchange` and `older`, frames of later versions in `unknown_to_older`, and the updater as the client in `update`. The records file, conversations and `READ`'s rule, routing ids against routing.md's vectors; SHA-256 against FIPS 180-4, the manifest and Semantic Versioning. |

The vectors' `group_ids` are not run here. A client never holds a group's secret, since no frame
carries one, so working out an id from it is the node's part. Nor is `refusals` run as a
conversation: it is a client that breaks the rules on purpose, to see a node refuse, so its frames
are only read and built back, and the updater's answers to each refusal are tested against a node
played by hand.

The release manifest is ternmesh.org's, not the specification's, which says only that a client
finds an image by `INFO`'s `board` and `release`. The app downloads the image named for the node's
board and region, checks its size and SHA-256 against the manifest, and sends it. A node with no
board cannot be updated over Bluetooth, and is flashed once over USB at
[ternmesh.org/flash](https://ternmesh.org/flash).

`Tests/TernKitTests/vectors/companion.json` is a copy of the specification's
[`vectors/companion.json`](https://github.com/ternmesh/spec/blob/main/vectors/companion.json).
CI runs the tests against the copy, and against the specification's own as it is on `main`, which
also runs once a week: if the specification changes, that job fails or warns. Copy the new file
here in the pull request that changes the code to match.

Positions are per [draft/positions.md](https://github.com/ternmesh/spec/blob/main/draft/positions.md),
with a node of version 5 or later. The Map tab shows each position the node holds at the centre of
its cell, and the cell itself when it is coarser than a street; a group member's is under the
group's name and the routing id it claimed. Sharing is turned on only from the share sheet, opened
from a chat's menu or the map. While the node shares with anyone, the app gives it the phone's
location, at most every 15 seconds and in the background too, and asks for the permission only
when the user first shares.

Addresses are shared per [draft/sharing.md](https://github.com/ternmesh/spec/blob/main/draft/sharing.md),
which is still a strawman: the Node screen shows the node's as a QR code, a link and the short code
to compare aloud, and a contact is added by scanning a code, pasting a link or an address, or
opening a link. A link `https://ternmesh.org/a/…` opened on the phone opens the app at Add Contact
with the address in it, through the Associated Domains entitlement in `App/Tern-iOS.entitlements`
and the `apple-app-site-association` file ternmesh.org serves for `/a/*` and `/A/*`. The App ID
`org.ternmesh.tern` must have Associated Domains to sign it for a device; a personal team cannot,
so to run the app under one, take `CODE_SIGN_ENTITLEMENTS[sdk=iphone*]` out of `project.yml`. The
release's iOS archive is unsigned, which leaves the entitlement out of its TestFlight builds for
now, and the Mac app does not have it yet.

Tapping a notification of a message opens its conversation, and its Reply action sends from it.
While the app is in front, only messages to a conversation not on screen are notified.

CI builds the app for the iOS simulator and for the Mac, unsigned, as well as testing TernKit.

## Still to come

* [Cards](https://github.com/ternmesh/spec/blob/main/draft/cards.md) in the app: TernKit speaks
  version 6 and holds the cards a node reports, but no screen turns a node's cards on, names them
  or shows who is about.
* Links that open the app from a TestFlight build, and on the Mac: the release's iOS archive signed,
  and the Mac's entitlements given Associated Domains.
* USB serial on the Mac, over `ByteStream`.
* Tests of the app's screens, and of the Bluetooth link against a node.

* [CONTRIBUTING.md](CONTRIBUTING.md) — DCO sign-off, and the specification first
* [Governance](https://github.com/ternmesh/spec/blob/main/GOVERNANCE.md)
