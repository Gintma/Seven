// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Seven",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Seven", targets: ["Seven"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")],
    targets: [
        .target(name: "ScrollRegistrationCore", cSettings: [.unsafeFlags(["-O2"])]),
        .executableTarget(
            name: "Seven",
            dependencies: ["ScrollRegistrationCore", .product(name: "Sparkle", package: "Sparkle")],
            resources: [.process("Localization"), .copy("Art/Shiba.usdz")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "SevenTests", dependencies: ["Seven"])
    ]
)
