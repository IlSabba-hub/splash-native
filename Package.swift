// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SplashNative",
    defaultLocalization: "en",
    platforms: [.macOS("26.4")],
    products: [
        .executable(name: "SplashNative", targets: ["SplashNative"]),
    ],
    targets: [
        .target(
            name: "NativeCore",
            path: "Sources/NativeCore",
            resources: [.copy("Resources/splash_probe.py"), .copy("Resources/splash_models.py"), .process("Resources/Localizable.xcstrings")]
        ),
        .target(name: "NativeUI", path: "Sources/NativeUI", resources: [.process("Resources")]),
        .executableTarget(name: "SplashNative", dependencies: ["NativeCore", "NativeUI"], path: "Sources/SplashNative"),
        .testTarget(name: "NativeUITests", dependencies: ["NativeUI"], path: "Tests/NativeUITests"),
    ]
)
