// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hexeon",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Gen3Save", targets: ["Gen3Save"]),
        .executable(name: "Hexeon", targets: ["Hexeon"]),
    ],
    targets: [
        .target(name: "Gen3Save", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "Hexeon", dependencies: ["Gen3Save"],
                          resources: [.copy("Names")],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "Gen3SaveTests", dependencies: ["Gen3Save"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
