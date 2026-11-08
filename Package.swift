// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VirtManager",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "VirtManager", targets: ["VirtManager"])],
    targets: [
        // Loads UTM's spice-client-glib at run time; no headers or link-time dependency.
        .target(name: "CSpiceBridge", path: "Sources/CSpiceBridge", linkerSettings: [.linkedFramework("IOSurface")]),
        .executableTarget(
            name: "VirtManager",
            dependencies: ["CSpiceBridge"],
            path: "Sources/VirtManager",
            // UTM's frameworks are copied into the app; resolve all @rpath links inside its Frameworks folder.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]) ]
        )
    ]
)
