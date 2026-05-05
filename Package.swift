// swift-tools-version: 6.0

import PackageDescription

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
            dependencies: ["PersonalEnvCore"],
            resources: [
                .process("Assets.xcassets")
            ]
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
