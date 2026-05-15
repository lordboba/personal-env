// swift-tools-version: 6.0

import PackageDescription

let sparkleUpdatesEnabled = Context.environment["PERSONAL_ENV_ENABLE_SPARKLE_UPDATES"] == "1"

let packageDependencies: [Package.Dependency] = sparkleUpdatesEnabled
    ? [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0")]
    : []

let appDependencies: [Target.Dependency] = sparkleUpdatesEnabled
    ? [
        "PersonalEnvCore",
        .product(name: "Sparkle", package: "Sparkle")
    ]
    : ["PersonalEnvCore"]

let appSwiftSettings: [SwiftSetting] = sparkleUpdatesEnabled
    ? [.define("ENABLE_SPARKLE_UPDATES")]
    : []

let package = Package(
    name: "PersonalEnv",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .executable(name: "PersonalEnv", targets: ["PersonalEnvApp"]),
        .executable(name: "penv", targets: ["penv"]),
        .library(name: "PersonalEnvCore", targets: ["PersonalEnvCore"])
    ],
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "PersonalEnvCore",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication")
            ]
        ),
        .executableTarget(
            name: "PersonalEnvApp",
            dependencies: appDependencies,
            resources: [
                .process("Assets.xcassets")
            ],
            swiftSettings: appSwiftSettings
        ),
        .executableTarget(
            name: "penv",
            dependencies: ["PersonalEnvCore"]
        ),
        .testTarget(
            name: "PersonalEnvCoreTests",
            dependencies: ["PersonalEnvCore"]
        )
    ]
)
