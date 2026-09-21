// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VesperEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VesperEngine", targets: ["VesperEngine"]),
        .executable(name: "zumbo-cli", targets: ["zumbo-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.7")
    ],
    targets: [
        .target(
            name: "VesperEngine",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            resources: [.copy("Resources/vocab-dev-starter.json")]
        ),
        .executableTarget(
            name: "zumbo-cli",
            dependencies: ["VesperEngine"]
        ),
        .testTarget(
            name: "VesperEngineTests",
            dependencies: ["VesperEngine"]
        ),
    ]
)
