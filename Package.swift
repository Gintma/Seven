// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Seven",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Seven", targets: ["Seven"])],
    targets: [
        .target(name: "ScrollRegistrationCore", cSettings: [.unsafeFlags(["-O2"])]),
        .executableTarget(name: "Seven", dependencies: ["ScrollRegistrationCore"], resources: [.process("Localization"), .copy("Art/Shiba.usdz")]),
        .testTarget(name: "SevenTests", dependencies: ["Seven"])
    ]
)
