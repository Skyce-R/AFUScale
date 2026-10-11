// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "AFUScaleCore", platforms: [.macOS(.v13)], products: [], targets: [
    .target(name: "AFUScaleCore", path: "App", exclude: ["AFUScaleApp.swift", "ScaleController.swift", "ContentView.swift", "ConsoleView.swift", "ConsoleRecorder.swift", "HealthWriter.swift", "Assets.xcassets", "Info.plist", "AFUScale.entitlements"], sources: ["BodyMetrics.swift", "ScalePacketParser.swift", "DiagnosticsCore"]),
    .testTarget(name: "AFUScaleCoreTests", dependencies: ["AFUScaleCore"], path: "CoreTests")
])
