// swift-tools-version: 6.0
// Built by scripts/build.sh, which first produces the Rust static library,
// the UniFFI header/modulemap and the generated Swift bindings.
import PackageDescription

let package = Package(
    name: "Filofinder",
    platforms: [.macOS(.v13)],
    targets: [
        // C module exposing the UniFFI header for libfilofinder_ffi.a.
        .target(
            name: "filofinder_ffiFFI",
            path: "Sources/FilofinderFFI",
            linkerSettings: [.linkedLibrary("filofinder_ffi")]
        ),
        .executableTarget(
            name: "Filofinder",
            dependencies: ["filofinder_ffiFFI"],
            path: "Sources/Filofinder",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
