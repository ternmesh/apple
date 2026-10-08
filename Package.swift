// swift-tools-version: 5.9
import PackageDescription

// TernKit is what the app knows of Tern apart from its screens: the companion protocol, the
// connection that speaks it, the records it leaves and how a person reads them. All of that uses
// nothing past the standard library, so `swift test` runs it on Linux as well as on a Mac. The one
// part that cannot, the Bluetooth link, is Core Bluetooth's and builds only where that is. The app
// in App/ depends on it.
let package = Package(
    name: "TernKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TernKit", targets: ["TernKit"]),
    ],
    targets: [
        .target(name: "TernKit"),
        .testTarget(
            name: "TernKitTests",
            dependencies: ["TernKit"],
            resources: [.copy("vectors")]
        ),
    ]
)
