// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Seven",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Seven", targets: ["Seven"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.7.3")
    ],
    targets: [
        .target(name: "ScrollRegistrationCore", cSettings: [.unsafeFlags(["-O2"])]),
        .executableTarget(
            name: "Seven",
            dependencies: [
                "ScrollRegistrationCore",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Markdown", package: "swift-markdown")
            ],
            resources: [.process("Localization"), .copy("Art/Shiba.usdz")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "SevenTests", dependencies: ["Seven"])
    ]
)
