// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FilesCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "FilesCore", targets: ["FilesCore"]),
    ],
    dependencies: [
        // zstd is needed for .tar.zst archives (e.g. VKD3D-Proton releases);
        // Apple's Compression framework covers zip/gzip/xz.
        .package(url: "https://github.com/facebook/zstd.git", exact: "1.5.7"),
    ],
    targets: [
        .target(
            name: "FilesCore",
            dependencies: [.product(name: "libzstd", package: "zstd")]
        ),
        .testTarget(name: "FilesCoreTests", dependencies: ["FilesCore"]),
    ]
)
