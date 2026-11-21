// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SenTerm",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")
    ],
    targets: [
        .binaryTarget(name: "GhosttyVt",
                      url: "https://release.files.ghostty.org/libghostty-vt/1.0.0/ghostty-vt-1.0.0.xcframework.zip",
                      checksum: "2c32b7409b2b6c2ef6cfd606526de357762ad458bdc27134ad074e86506a8bc2"),
        .executableTarget(name: "SenTerm", dependencies: ["GhosttyVt", .product(name: "SwiftTerm", package: "SwiftTerm")],
                          path: "sources/senterm",
                          linkerSettings: [.linkedLibrary("c++")])
    ],
    swiftLanguageModes: [.v5]
)
