// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BBoxDesigner",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BBoxDesigner",
            path: "Sources"
        )
    ]
)
