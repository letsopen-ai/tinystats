import Foundation
import Testing

@testable import TinyStatsCore

@Test func deviceIdentityDecodesOnlyBoundedNonemptyUTF8() {
  #expect(DeviceIdentity.text(Data("Mac mini\0ignored".utf8)) == "Mac mini")
  #expect(DeviceIdentity.text(Data(" Apple M4 \n".utf8)) == "Apple M4")
  #expect(DeviceIdentity.text(Data()) == nil)
  #expect(DeviceIdentity.text(Data(" \0".utf8)) == nil)
  #expect(DeviceIdentity.text(Data([0xFF])) == nil)
  #expect(DeviceIdentity.text(Data(repeating: 65, count: 1025)) == nil)
  let empty = Snapshot().device
  #expect(empty.model == nil && empty.chip == nil && empty.operatingSystem == nil)
}
