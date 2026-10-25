// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FrijaMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FrijaMac", targets: ["FrijaMac"]),
        .executable(name: "frija", targets: ["FrijaCLI"])
    ],
    targets: [
        .target(name: "FrijaCore"),
        .executableTarget(name: "FrijaMac", dependencies: ["FrijaCore"],
                          swiftSettings: [.defaultIsolation(MainActor.self)]),
        .executableTarget(name: "FrijaCLI", dependencies: ["FrijaCore"]),
        .testTarget(name: "FrijaCoreTests", dependencies: ["FrijaCore"])
    ]
)
