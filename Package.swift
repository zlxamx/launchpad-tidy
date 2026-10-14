// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LaunchpadTidy",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LaunchpadTidy", targets: ["LaunchpadTidy"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "LaunchpadCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "LaunchpadTidy", dependencies: ["LaunchpadCore"]),
        .testTarget(name: "LaunchpadCoreTests", dependencies: ["LaunchpadCore", "CSQLite"]),
        .testTarget(name: "LaunchpadTidyTests", dependencies: ["LaunchpadTidy", "LaunchpadCore"])
    ]
)
