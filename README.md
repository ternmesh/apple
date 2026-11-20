# Tern for iPhone, iPad and Mac

The Apple app for **Tern**, a LoRa mesh protocol that treats airtime as a
shared, metered resource. It drives a Tern node over Bluetooth LE through
the [companion protocol](https://github.com/ternmesh/spec/blob/main/draft/companion.md),
in Swift and SwiftUI.

What the app is, and why it is native, is in
[decisions/phone-apps.md](https://github.com/ternmesh/spec/blob/main/decisions/phone-apps.md).
It finds a node over Bluetooth LE, pairs with it by passkey, and from then on keeps it connected
whenever it is in range, in the background too: chats with contacts and groups, invites, contacts
and the addresses the node refused, who is about, the node's battery, airtime, neighbours and
settings, its presence card and satellite receiver, where the node is, positions shared with the node on a map and sharing the user's own,
updates to its firmware from [ternmesh.org](https://ternmesh.org/firmware/), checked against Tern's
release keys, turning the node off, and erasing it.

```bash
brew install xcodegen && xcodegen && open Tern.xcodeproj   # the app, for iPhone, iPad and Mac
swift test        # TernKit: the protocol, the connection, the records and updates, against the specification's vectors
```

The app needs Xcode 15 or later, and runs on iOS 16 and macOS 13 or later. `xcodegen` writes
`Tern.xcodeproj` from `project.yml`; the project file is not committed. Choose a team under
Signing to run it on a device.

TernKit needs Swift 5.9 or later. Everything in it but the Bluetooth link uses only the standard
library and [libsodium](https://libsodium.org), so the tests run on Linux too. libsodium does the
Ed25519 the standard library has nothing for: routing ids from a key blinded from an address, and
release signatures. It comes from [swift-sodium](https://github.com/jedisct1/swift-sodium), pinned
to one commit in `Package.swift`: on Apple's platforms as the xcframework that package carries, and
on Linux as the system's (`apt-get install libsodium-dev pkg-config`). Open `Package.swift` in Xcode
to work on it alone.

## Where things are

| Path | |
|---|---|
| `Sources/TernKit/Companion/Frame.swift` | Every frame of the protocol's version 17, as Swift types, and its numbers. |
| `Sources/TernKit/Companion/Codec.swift` | A frame built into bytes, and read back from them. |
| `Sources/TernKit/Companion/ByteStream.swift` | Frames on a byte stream (USB serial, TCP), with the node's console text between them. Bluetooth does not need it. |
| `Sources/TernKit/Sharing/` | An address's text, link and short code (draft/sharing.md); a group's join code read, to name the group before the user joins it (draft/groups.md); and the QR encoder the join code is drawn with, alphanumeric either side of its `#`, which Core Image's generator cannot do. |
| `Sources/TernKit/Connection/Connection.swift` | One connection, the client's half: `HELLO` and the version both speak, one request at a time, counted news, syncing again, and the `PING` that keeps a node from taking the app for gone. No I/O and no clock of its own: a link hands it frames and calls `tick()`. |
| `Sources/TernKit/Connection/Remote.swift` | A node managed over the mesh (draft/managing.md): each request in a `MANAGE`, its answer read from `MANAGED`, `HELLO` first and again after the node restarts, a request not delivered tried again, and the `PING` that ends a setting's trial, after a node that restarts to apply it can answer. No I/O and no clock of its own, as the connection. |
| `Sources/TernKit/Connection/Records.swift` | What the node has said it holds, as news leaves it, positions, sharing, cards and the node's own fix included, and the `after` the next sync asks from. |
| `Sources/TernKit/Connection/RecordsFile.swift` | The records on disk: a short header, then each record as the frame that carried it, but for positions, sharing, cards and the node's own fix, which every sync sends again. The Android app writes the same bytes. |
| `Sources/TernKit/Connection/Conversations.swift` | The records as conversations, with what is unread; the `through` a `READ` may go to without marking another conversation's; and what is new enough to notify of. |
| `Sources/TernKit/Connection/RoutingNames.swift` | An address's routing id as the node's version makes it, from the address itself before version 14 and from the key blinded from it after, kept once worked out; and the contacts' names by theirs: what a neighbour or a group message's writer shows as, when it is a contact. |
| `Sources/TernKit/Crypto/Ed25519.swift` | The few calls into libsodium: SHA-512, a scalar mod L, a valid address, a point multiplied, a signature checked. |
| `Sources/TernKit/Connection/Cards.swift` | Who is about as a person reads it: the cards held, most recently heard first, each counted on from when its record came; the name a node's cards may carry; a card's name shown as its sender's claim. |
| `Sources/TernKit/Connection/Words.swift` | The protocol's numbers in words: states, reasons, refusals, roles, how an update ended. |
| `Sources/TernKit/Update/Updater.swift` | One firmware image sent to a node: `UPDATE_BEGIN`, on from the offset the node gives, `UPDATE_DATA` a chunk at a time, `UPDATE_END`, and going on after the link drops. Through the connection, with no I/O of its own. |
| `Sources/TernKit/Update/BootloaderUpdater.swift` | A DFU package given to a node by its bootloader: `UPDATE_BOOTLOADER`, the bootloader found by its service, the package, and once more after a bootloader left mid-session. |
| `Sources/TernKit/Update/DFU.swift` | Nordic's legacy DFU, as an nRF52840 node's bootloader speaks it: the package's init packet and application, and the client, through a transport of three calls (write the control point, write a packet, wait for a notification), so that a bootloader played by hand tests it. |
| `Sources/TernKit/Update/Zip.swift` | Just enough of a .zip to read a DFU package: stored and deflated entries, checked against their CRC-32, with an inflater of TernKit's own. |
| `Sources/TernKit/Update/Release.swift` | The release manifest at `ternmesh.org/firmware/latest.json`, the image in it for a node's board, region and way of being updated, and Semantic Versioning's order, with the little JSON it needs. |
| `Sources/TernKit/Update/ReleaseKeys.swift` | The release keys, the same list as the firmware's `ports/node/release_keys.h`: the one place a key is added. |
| `Sources/TernKit/Update/Signature.swift` | An image's signature checked against them: Ed25519 over `"TERN-FIRMWARE-V1"` and the image's SHA-256. |
| `Sources/TernKit/Update/SHA256.swift` | SHA-256, for an image's digest and routing ids: TernKit's own, so that it needs nothing of Apple's. |
| `Sources/TernKit/Bluetooth/BluetoothLink.swift` | Core Bluetooth: scanning, connecting, pairing, the MTU, a frame to each write and notification, reconnecting to the remembered node, and restoring in the background. Built only where Core Bluetooth is. |
| `Sources/TernKit/Bluetooth/BootloaderLink.swift` | Core Bluetooth for a node's bootloader: found by the DFU service, on a central of its own, and the DFU client's transport, each packet written without a response once the link can take it. |
| `App/` | The app in SwiftUI: `NodeModel` (the link, the connection and the records, kept on disk, the firmware it downloads and sends, and the phone's position given to the node while it shares, from `LocationFeed`), `Notifications` (a tap or a reply on one), and the screens: Connect (the whole window until a node is chosen, then Switch Node), and the Chats, People (contacts, and who is near), Map and Node tabs, the node's dashboard with a screen for each thing about it, with the share sheet. `Design` holds what they share: avatars, signal bars and the node's status pill. The map is MapKit's own view (`PositionMap`), which draws a cell before iOS 17 and macOS 14. |
| `project.yml` | The Xcode project, for XcodeGen: one target for iOS and macOS. |
| `Tests/TernKitTests/` | The conformance section of the specification, as a client: the codec against every vector, the connection as the client in `exchange` and `older`, frames of later versions in `unknown_to_older`, the updater as the client in `update`, and the bootloader's connections, `wipe`, and the client of version 12 refused an unsigned update; the signatures in `signatures`, and the routing ids in routing.json's `ids` and `no_ids`; the DFU client against a bootloader played by hand, and the package against ones `adafruit-nrfutil` made (`fixtures/`). The records file, conversations and `READ`'s rule, routing ids against routing.md's vectors; SHA-256 against FIPS 180-4, the manifest and Semantic Versioning. |

The vectors' `group_ids` are run against the join code reader, which works out the id of the
group a code is for, so that the app can say whether the node holds it already; `groups.json`'s
join codes are run too, and `qr.json`, a copy of the site's, holds the QR encoder to codes made with
segno, module for module. Not `refusals` run as a
conversation: it is a client that breaks the rules on purpose, to see a node refuse, so its frames
are only read and built back, and the updater's answers to each refusal are tested against a node
played by hand.

The release manifest is ternmesh.org's, not the specification's, which says only that a client
finds an image by `INFO`'s `board` and `release`. The app downloads the image named for the node's
board and region, checks its size and SHA-256 against the manifest, and sends it. A node with no
board cannot be updated over Bluetooth, and is flashed once over USB at
[ternmesh.org/flash](https://ternmesh.org/flash).

From a node of version 12, `INFO`'s `update` says how: over the link, as above, or by the node's
bootloader, as an nRF52840 board's is (the Heltec T114 and the Seeed T1000-E), which has room for one
image, not two. For such a node the manifest's entry says `"update": "bootloader"`, and its file is
the release's DFU package, a `.zip` as `adafruit-nrfutil dfu genpkg` makes it; an entry without
`update` is one over the link, so an app from before version 12, which a node never tells of a board
it cannot update over the link, never picks one. The app downloads the package and checks its
SHA-256, asks the node `UPDATE_BOOTLOADER`, and once the node has answered and restarted, looks for
its bootloader by the legacy DFU service (another device to Bluetooth: on iOS it has another
identifier than the node's). It gives the bootloader the package as the firmware's
`tools/ble_dfu.py` does, ten 20-byte packets to each receipt, about 10 ms apart; the erase takes up to
a minute or two, and the whole about five. The bootloader starts the image, and the node, connected
again, says its new release. An update that stops part of the way leaves the bootloader waiting
over Bluetooth, with everything the node held kept, and the app says so: updating again goes straight
to it. A node whose `update` is 0 says it can be updated only over USB, and the app says so.

`Tests/TernKitTests/vectors/companion.json` and `routing.json` are copies of the specification's
[`vectors/companion.json`](https://github.com/ternmesh/spec/blob/main/vectors/companion.json) and
[`vectors/routing.json`](https://github.com/ternmesh/spec/blob/main/vectors/routing.json).
CI runs the tests against the copy, and against the specification's own as it is on `main`, which
also runs once a week: if the specification changes, that job fails or warns. Copy the new file
here in the pull request that changes the code to match.

From a node of version 13, updates are signed ([Signed images](https://github.com/ternmesh/spec/blob/main/draft/companion.md#signed-images)).
Each release's image is signed by a release key, over `"TERN-FIRMWARE-V1"` and the image's SHA-256,
and the manifest carries the signature beside the digest (`"signature"`, 128 hex digits). The app
checks it against its release keys before downloading, and again over the downloaded bytes, and
sends it in `UPDATE_BEGIN` to a node of version 13 or later, which checks it too and refuses with
`ERROR` 11 an image not signed by a key it holds: the app says so. An image that does not verify,
or a release from before releases were signed (0.6.0-alpha.1 and earlier, which have none), is
offered only behind a warning that it may not be the release's, and installed only if the user
chooses Install Anyway. To a node of version 13 or later updated over the link, an image with no
signature is not offered at all: the node would refuse it, so the app says to update it over USB.
An nRF52840 node's package is checked the same way before the node is asked to restart into its
bootloader, which checks nothing itself, and the app says that while the bootloader waits anyone in
Bluetooth range can install an image on it, until the update finishes.

The release keys are in `Sources/TernKit/Update/ReleaseKeys.swift`: release key 1, added
2026-11-18, the key of [ternmesh/firmware#120](https://github.com/ternmesh/firmware/pull/120). To add
a key, add one line there, the key's 64 hex digits under a comment saying when it was added, as the
firmware's `tools/release_key.py public` prints it, once the firmware lists it in
`ports/node/release_keys.h`. The specification's published test key is only ever in the tests.

From a node of version 13, the Node tab also erases the node (`WIPE`), once the user has been told
that its address, contacts, groups and messages go for good and that it must be paired again. Once
the node answers, the app forgets it and everything it kept of it, and asks the user to remove the
node in the system's Bluetooth settings too, which an app cannot do.

It speaks version 17 of the companion protocol, and any earlier version a node speaks. A chat can be
deleted from a node of version 16 or later (`FORGET`, `FORGET_GROUP`), from its menu, or by swiping
it or from its context menu in the list. The app asks first, saying that its messages go from the
node and from every phone or computer connected to it, for good, and that any not yet delivered
will not be sent, and deletes only as far as the last message it showed. Leaving a group and
removing a contact offer to delete the chat too, deleting it first. When any client deletes a chat,
the node tells every client (`FORGOTTEN`, `GROUP_FORGOTTEN`), at once or at its next sync, and each
removes those messages and their notifications. The contact, its session and the group are kept.

From a node of version 17, a contact can be made an owner of the user's node (`OWNER`), from its
menu in People or in its chat, once the app has said that an owner can change the node's settings
and who it takes from anywhere on the mesh; People marks owners. A contact's menu also offers to
manage their node, over the mesh, as one of its owners (`MANAGE`): its state from a sync, the
settings an owner may change there (not its region or its PIN), its Bluetooth lock, which of its
contacts are owners, and restarting it. Each request goes one at a time, is tried again up to three
times 15 s apart if it was not delivered, and is waited on for 2 minutes once it was; the screen says
where it is. A setting changed is on trial for 15 minutes, and the app confirms it with a `PING` at
once, or 45 s later for a role or a power, which restart the node; until then the screen says it is
on trial. When a node's owners change, the node tells them (`OWNER_CHANGED`), and the app says who
was made or is no longer an owner of which node, at the node or over the mesh. The Node tab says
when the node's own Bluetooth is locked, when only USB or its owners can change it.

When pairing fails, the app says to press the node's button, or turn it off and on (RESET on a board
with no button), and pair within 3 minutes, or to type the PIN a node with a screen shows: a node
takes a PIN it does not show only for three minutes after someone has been at it.

From a node of version 14, announces carry a key blinded from each node's address, and the node
gives the app routing ids made from that key. The app works out each contact's the same way
(`h = SHA-512("tern v0 blind" || A || 0) mod L`, `B = [h]A`, the id from `B`) and keeps it, and
matches neighbours, group messages' writers and group members' positions by it; for a node of
version 13 or earlier, by the id made from the address itself.

Positions are per [draft/positions.md](https://github.com/ternmesh/spec/blob/main/draft/positions.md),
with a node of version 5 or later. The Map tab shows each position the node holds at the centre of
its cell, and the cell itself when it is coarser than a street; a group member's is under the
group's name and the routing id it claimed. Sharing is turned on only from the share sheet, opened
from a chat's menu or the map. While the node shares with anyone, the app gives it the phone's
location, at most every 15 seconds and in the background too, and asks for the permission only
when the user first shares.

From a node of version 8, the map also shows where the node itself is, from its own satellite
receiver or from a phone, and the Node tab turns a node's receiver on or off.

From a node of version 9, the Node tab also turns the node off, once the user has been told that
only the node itself, by its button, its reset or its power, turns it on again. Once the node has
answered, the app disconnects and says the node is turned off, and does not connect to it again
until the user does.

From a node of version 10, the Node tab says when the node sends at the most it may, which the node
works out for its board, its antenna and its region, and offers to go back to it once a number has
been set.

From a node of version 11, the Node tab says how the node pairs: a new PIN (the specification's
passkey) on its screen, the default 123456 of a node without a screen, or one the user set. While a
node pairs with 123456, which anyone nearby who knows it can pair with too, an alert over whichever
screen is showing asks the user once each connection to choose their own, and Choose PIN goes to the
Node tab, which asks for it; the PIN is changed later under Node, Bluetooth PIN. Use Default goes back to the node's default.

Cards are per [draft/cards.md](https://github.com/ternmesh/spec/blob/main/draft/cards.md), with a
node of version 6 or later. People's Nearby lists the cards the node holds, the
most recently heard first: each card's name in quotes, as its sender's claim, beside its address's
short code, and never in place of a contact's name. A contact's card opens its conversation, and
anyone else's opens Add Contact with the address and the card's name in it, to keep or change.
The node's own card is turned on and named only under Node, Privacy & Location, which says what that puts on
the air; the app never does either by itself.

Addresses are shared per [draft/sharing.md](https://github.com/ternmesh/spec/blob/main/draft/sharing.md),
which is still a strawman: the Node screen shows the node's as a QR code, a link and the short code
to compare aloud, and a contact is added by scanning a code, pasting a link or an address, or
opening a link. A link `https://ternmesh.org/a/…` opened on the phone opens the app at Add Contact
with the address in it, through the Associated Domains entitlement in `App/Tern-iOS.entitlements`
and the `apple-app-site-association` file ternmesh.org serves for `/a/*` and `/A/*`. The App ID
`org.ternmesh.tern` must have Associated Domains to sign it for a device; a personal team cannot,
so to run the app under one, take `CODE_SIGN_ENTITLEMENTS[sdk=iphone*]` out of `project.yml`. The
release's iOS archive is unsigned, so the release workflow gives it the entitlement before the
export signs it for TestFlight. The Mac app does not have it yet.

A group is handed on by its join code, per [draft/groups.md](https://github.com/ternmesh/spec/blob/main/draft/groups.md#join-codes).
The group's menu has Join Code, which says first that anyone who sees the code can read the group,
and only then asks the node for it and shows the QR code, the link, Copy and Share. Join a Group,
in the Chats screen's menu, takes a code scanned or a link pasted, names the group, and joins it;
a `ternmesh.org/G#…` link opened on the phone opens the same sheet, through the same entitlement
and the file's `/G` and `/g`. The node writes the link and reads it, and the app keeps neither the
link nor the secret in it once the sheet closes.

Tapping a notification of a message opens its conversation, and its Reply action sends from it.
While the app is in front, only messages to a conversation not on screen are notified.

CI builds the app for the iOS simulator and for the Mac, unsigned, as well as testing TernKit.

## Still to come

* Links that open the app on the Mac: its entitlements given Associated Domains.
* USB serial on the Mac, over `ByteStream`.
* Tests of the app's screens, and of the Bluetooth link against a node.

* [CONTRIBUTING.md](CONTRIBUTING.md) — DCO sign-off, and the specification first
* [Governance](https://github.com/ternmesh/spec/blob/main/GOVERNANCE.md)
