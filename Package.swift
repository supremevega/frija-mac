// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FrijaMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FrijaMac", targets: ["FrijaMac"]),
        .executable(name: "FrijaFlash", targets: ["FrijaFlash"]),
        .executable(name: "frija", targets: ["FrijaCLI"])
    ],
    targets: [
        .target(name: "FrijaCore"),
        .executableTarget(name: "FrijaMac", dependencies: ["FrijaCore"],
                          swiftSettings: [.defaultIsolation(MainActor.self)]),
        .executableTarget(name: "FrijaCLI", dependencies: ["FrijaCore"]),
        .executableTarget(name: "FrijaFlash", dependencies: ["FrijaCore"],
                          swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "FrijaCoreTests", dependencies: ["FrijaCore"])
    ]
)
