import Foundation
import Testing

@testable import TinyStatsCore

@Test func cpuTopologyUsesExplicitIDsAndRejectsAmbiguousOrIncompleteInventories() {
  let entries: [CPUCoreTopology.Entry] = [
    .init(id: 3, kind: .performance), .init(id: 0, kind: .efficiency),
    .init(id: 2, kind: .performance),
  ]
  #expect(
    CPUCoreTopology.resolve(entries, count: 4) == [
      .efficiency, .unknown, .performance, .performance,
    ])
  let conflict = entries + [.init(id: 0, kind: .performance), .init(id: 0, kind: .efficiency)]
  #expect(CPUCoreTopology.resolve(conflict, count: 4)[0] == .unknown)
  #expect(CPUCoreTopology.resolve(entries + [.init(id: 9, kind: .efficiency)], count: 4).count == 4)
  #expect(
    CPUCoreTopology.resolve(Array(repeating: entries[0], count: 257), count: 4)
      == Array(repeating: .unknown, count: 4))
  #expect(CPUCoreTopology.resolve(entries, count: 257).isEmpty)
  let cpu = CPUReading(usage: 10, cores: [0, nil], load: [], coreKinds: [.performance])
  #expect(cpu.kind(at: 0) == .unknown && cpu.kind(at: -1) == .unknown)
}

@Test func cpuTopologyRejectsMalformedIDsAndPreservesUnknownClusterTypes() {
  let e = Data([69, 0])
  #expect(CPUCoreTopology.entry(id: 0, cluster: e)?.kind == .efficiency)
  #expect(CPUCoreTopology.entry(id: 1, cluster: Data([80]))?.kind == .performance)
  #expect(CPUCoreTopology.entry(id: Data([3, 0, 0, 0]), cluster: e)?.id == 3)
  #expect(CPUCoreTopology.entry(id: Data([0, 1, 0, 0]), cluster: e) == nil)
  #expect(CPUCoreTopology.entry(id: Data([0]), cluster: e) == nil)
  for value: Any in [true, -1, 256, 0.5, Double.nan, "0"] {
    #expect(CPUCoreTopology.entry(id: value, cluster: e) == nil)
  }
  for value: Any in [Data(), Data([69, 1]), Data([69, 0, 0]), Data([83, 0]), "E"] {
    #expect(CPUCoreTopology.entry(id: 0, cluster: value)?.kind == .unknown)
  }
}

@Test func gpuCoreCountsCannotBecomeUtilizationOrInventMissingCores() {
  #expect(Hardware.gpuCoreCount(10) == 10)
  for value: Any in [true, 0, -1, 1.5, 65537, Double.infinity, Double.nan, "10"] {
    #expect(Hardware.gpuCoreCount(value) == nil)
  }
  #expect(Hardware.gpuCoreCount(nil) == nil)
}

@Test func componentGroupsSeparatePhysicalQuantityFromRecognizedComponent() {
  func sensor(_ key: String, _ kind: SensorReading.Kind, silicon: Bool = true) -> SensorReading {
    .init(key: key, name: SensorCatalog.name(for: key, appleSilicon: silicon), kind: kind, value: 1)
  }
  #expect(sensor("Tp01", .temperature).component == .cpu)
  #expect(sensor("Tp0P", .temperature, silicon: false).component == .other)
  #expect(sensor("Tf04", .temperature).component == .cpu)
  #expect(sensor("Tf14", .temperature).component == .gpu)
  #expect(sensor("TCGC", .temperature).component == .gpu)
  #expect(sensor("TCHP", .temperature, silicon: false).component == .other)
  #expect(sensor("F0Ac", .fan).component == .fans)
  #expect(sensor("ioreport:cpu", .power).component == .cpu)
  #expect(sensor("ioreport:gpu", .power).component == .gpu)
  #expect(sensor("ioreport:dram", .power).component == .memory)
  #expect(sensor("TH0p", .temperature).component == .storage)
  #expect(sensor("TB0T", .temperature).component == .battery)
  #expect(sensor("PSTR", .power).component == .system)
  #expect(sensor("IP5l", .current).component == .other)
  let signed = SensorReading(key: "IC0C", name: "IC0C", kind: .current, value: -2)
  #expect(signed.component == .cpu && signed.formatted(fahrenheit: false) == "-2.00 A")
}
