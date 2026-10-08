// swift-tools-version: 5.9
import PackageDescription

// TernKit is what the app knows of Tern apart from its screens: today, the companion protocol's
// frames. It uses nothing past the standard library, so `swift test` runs it on Linux as well as
// on a Mac, and the app target (to come) depends on it.
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
