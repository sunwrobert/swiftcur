// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "swiftcur",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Swiftcur", targets: ["Swiftcur"]),
    ],
    targets: [
        .target(name: "Swiftcur"),
        .target(name: "DemoCLI", dependencies: ["Swiftcur"], path: "Examples/DemoCLI"),
        .executableTarget(name: "Demo", dependencies: ["DemoCLI"], path: "Examples/Demo"),
        .testTarget(
            name: "SwiftcurTests",
            dependencies: ["Swiftcur", "DemoCLI"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
