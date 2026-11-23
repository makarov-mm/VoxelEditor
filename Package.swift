// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoxelStudio",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Forma", targets: ["VoxelStudio"])],
    targets: [
        .executableTarget(name: "VoxelStudio"),
        .testTarget(name: "VoxelStudioTests", dependencies: ["VoxelStudio"])
    ]
)
