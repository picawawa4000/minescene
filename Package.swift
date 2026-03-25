// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "minescene",
    platforms: [
        .macOS(.v10_15)
    ],
    dependencies: [
        .package(url: "https://github.com/picawawa4000/swift-vulkan-bindings.git", branch: "main"),
        .package(url: "https://github.com/picawawa4000/dpreader-swift.git", branch: "master"),
        .package(url: "https://github.com/KevinVitale/SwiftSDL.git", from: "0.2.0-alpha.28")
    ], 
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "minescene",
            dependencies: [
                .product(name: "VulkanBindings", package: "swift-vulkan-bindings"),
                .product(name: "Vulkan", package: "swift-vulkan-bindings"),
                .product(name: "SwiftSDL", package: "SwiftSDL"),
                .product(name: "DPReader", package: "dpreader-swift")
            ]
        ),
    ]
)
