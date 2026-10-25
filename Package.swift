// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SwiftQuery",
    platforms: [.iOS(.v13), .macOS(.v10_15), .tvOS(.v13), .watchOS(.v6)],
    products: [
        .library(name: "SwiftQuery", targets: ["SwiftQuery"])
    ],
    targets: [
        .target(name: "SwiftQuery"),
        .testTarget(name: "SwiftQueryTests", dependencies: ["SwiftQuery"])
    ]
)
