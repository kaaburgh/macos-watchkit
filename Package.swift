// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [
    .library(name: "WatchCore", targets: ["WatchCore"])
]

var targets: [Target] = [
    .target(name: "WatchCore"),
    .testTarget(name: "WatchCoreTests", dependencies: ["WatchCore"])
]

#if os(macOS)
products.append(.executable(name: "MacOSWatchKit", targets: ["MacOSWatchKit"]))
targets.append(.executableTarget(name: "MacOSWatchKit", dependencies: ["WatchCore"]))
#endif

let package = Package(
    name: "macos-watchkit",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
