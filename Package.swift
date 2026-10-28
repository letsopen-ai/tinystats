// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TinyStats",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "TinyStats", targets: ["TinyStats"]),
    .library(name: "TinyStatsCore", targets: ["TinyStatsCore"]),
    .executable(name: "TinyStatsTrafficService", targets: ["TinyStatsTrafficService"]),
  ],
  targets: [
    .target(
      name: "CTinyStats",
      linkerSettings: [
        .linkedFramework("IOKit"), .linkedFramework("CoreFoundation"),
        .linkedFramework("SystemConfiguration"),
      ]),
    .target(name: "CTinyStatsTraffic"),
    .target(name: "TinyStatsTraffic", dependencies: ["CTinyStatsTraffic"]),
    .target(name: "TinyStatsFanControl"),
    .testTarget(name: "TinyStatsFanControlTests", dependencies: ["TinyStatsFanControl"]),
    .target(name: "TinyStatsCore", dependencies: ["CTinyStats", "TinyStatsTraffic"]),
    .executableTarget(name: "TinyStats", dependencies: ["TinyStatsCore"]),
    .target(name: "TinyStatsTrafficIPC", dependencies: ["TinyStatsTraffic"]),
    .target(
      name: "TinyStatsTrafficClient", dependencies: ["TinyStatsTrafficIPC", "TinyStatsTraffic"]),
    .target(
      name: "TinyStatsTrafficServiceCore",
      dependencies: ["TinyStatsTraffic", "TinyStatsTrafficIPC"]),
    .executableTarget(
      name: "TinyStatsTrafficService",
      dependencies: ["TinyStatsTrafficServiceCore", "TinyStatsTrafficIPC"]),
    .testTarget(
      name: "TinyStatsTrafficServiceTests",
      dependencies: ["TinyStatsTrafficServiceCore", "TinyStatsTraffic", "TinyStatsTrafficIPC"]),
    .testTarget(
      name: "TinyStatsTrafficClientTests",
      dependencies: ["TinyStatsTrafficClient", "TinyStatsTrafficIPC", "TinyStatsTraffic"]),
    .testTarget(
      name: "TinyStatsTrafficTests", dependencies: ["TinyStatsTraffic", "CTinyStatsTraffic"]),
    .target(
      name: "TinyStatsTestSupport", path: "Tests/TinyStatsTestSupport",
      resources: [.copy("Fixtures")]),
    .testTarget(
      name: "TinyStatsCoreTests",
      dependencies: ["TinyStatsCore", "CTinyStats", "TinyStatsTestSupport"]),
    .testTarget(
      name: "TinyStatsUITests",
      dependencies: ["TinyStats", "TinyStatsCore", "TinyStatsTestSupport"]),
  ]
)
