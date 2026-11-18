// swift-tools-version: 5.9
import PackageDescription

// TernKit is what the app knows of Tern apart from its screens: the companion protocol, the
// connection that speaks it, the records it leaves and how a person reads them, and the firmware
// updates it carries, with the release manifest and SHA-256 they need. All of that uses the
// standard library and libsodium, so `swift test` runs it on Linux as well as on a Mac. libsodium
// does the Ed25519 arithmetic the standard library has nothing for: routing ids made from a key
// blinded from an address (routing.md, companion version 14), and release signatures (companion
// version 13). It comes from swift-sodium, pinned to one commit: on Apple's platforms as the
// xcframework in that package, on Linux as the system's libsodium (`apt-get install
// libsodium-dev`). The one part that cannot run on Linux, the Bluetooth links to a node and to its
// bootloader, is Core Bluetooth's and builds only where that is. The app in App/ depends on it.
let package = Package(
    name: "TernKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TernKit", targets: ["TernKit"]),
    ],
    dependencies: [
        // jedisct1/swift-sodium at "Add streaming signatures and nonce increment", 2026-11-02:
        // libsodium 1.0.22 on Apple's platforms.
        .package(url: "https://github.com/jedisct1/swift-sodium.git", revision: "fbe072d70df9dbe43adbc4f6ae5787ee59fd376e"),
    ],
    targets: [
        .target(name: "TernKit", dependencies: [.product(name: "Clibsodium", package: "swift-sodium")]),
        .testTarget(
            name: "TernKitTests",
            dependencies: ["TernKit"],
            resources: [.copy("vectors"), .copy("fixtures")]
        ),
    ]
)
