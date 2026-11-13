// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Mistral",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "SMCCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "Probe",
            dependencies: ["SMCCore"]
        ),
        .executableTarget(
            name: "Mistral",
            dependencies: ["SMCCore"]
        ),
        .executableTarget(
            name: "Mistrald",
            dependencies: ["SMCCore"]
        )
    ]
)
