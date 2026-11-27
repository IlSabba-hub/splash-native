// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SplashDeck",
    defaultLocalization: "en",
    platforms: [.macOS("26.4")],
    products: [
        .executable(name: "SplashDeck", targets: ["SplashDeck"]),
    ],
    targets: [
        .target(
            name: "DeckCore",
            path: "Sources/DeckCore",
            resources: [.copy("Resources/splash_probe.py"), .copy("Resources/splash_models.py"), .process("Resources/Localizable.xcstrings")]
        ),
        .target(name: "DeckUI", path: "Sources/DeckUI", resources: [.process("Resources")]),
        .executableTarget(name: "SplashDeck", dependencies: ["DeckCore", "DeckUI"], path: "Sources/SplashDeck"),
        .testTarget(name: "DeckUITests", dependencies: ["DeckUI"], path: "Tests/DeckUITests"),
    ]
)
