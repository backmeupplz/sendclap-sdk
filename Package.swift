// swift-tools-version:5.7
// Lives at the repo root because SwiftPM only resolves git packages from there; the code is in swift/.
import PackageDescription

let package = Package(
    name: "Sendclap",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [.library(name: "Sendclap", targets: ["Sendclap"])],
    targets: [
        .target(name: "Sendclap", path: "swift/Sources/Sendclap"),
        .testTarget(name: "SendclapTests", dependencies: ["Sendclap"], path: "swift/Tests/SendclapTests"),
    ]
)
