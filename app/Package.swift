// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpotifyWallpaper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SpotifyWallpaper", targets: ["SpotifyWallpaper"]),
        .library(name: "LiricaMediaRemoteBridge", type: .dynamic, targets: ["MediaRemoteBridge"]),
    ],
    targets: [
        .executableTarget(
            name: "SpotifyWallpaper",
            path: "Sources/SpotifyWallpaper",
            linkerSettings: [.linkedFramework("WebKit"), .linkedFramework("ServiceManagement")]
        ),
        .target(
            name: "MediaRemoteBridge",
            path: "Sources/MediaRemoteBridge",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(
            name: "SpotifyWallpaperTests",
            dependencies: ["SpotifyWallpaper"],
            path: "Tests/SpotifyWallpaperTests"
        ),
    ]
)
