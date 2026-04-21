// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FocusLatch",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "FocusLatch",
            targets: ["FocusLatch"]
        ),
    ],
    targets: [
        .target(
            name: "MultitouchBridge",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "FocusLatch",
            dependencies: ["MultitouchBridge"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
