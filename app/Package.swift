// swift-tools-version: 6.0
// Built by scripts/build.sh, which first produces the Rust static library,
// the UniFFI header/modulemap and the generated Swift bindings.
import PackageDescription

let package = Package(
    name: "Filofinder",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Auto-updates from GitHub Releases (EdDSA-signed appcast).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // C module exposing the UniFFI header for libfilofinder_ffi.a.
        .target(
            name: "filofinder_ffiFFI",
            path: "Sources/FilofinderFFI",
            linkerSettings: [.linkedLibrary("filofinder_ffi")]
        ),
        .executableTarget(
            name: "Filofinder",
            dependencies: ["filofinder_ffiFFI", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Filofinder",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Sparkle.framework is embedded in Contents/Frameworks by scripts/build.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
