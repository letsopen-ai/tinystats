import Foundation

enum TrafficCollectionScope: Sendable {
  case kernelSockets, modernConnections
  var providers: [UInt32] { self == .kernelSockets ? [2, 4] : [9] }
  var providerCount: Int { self == .kernelSockets ? 2 : 1 }
  func accepts(_ provider: UInt32) -> Bool {
    self == .kernelSockets ? provider == 2 || provider == 4 : provider == 9
  }
  func acknowledges(_ context: UInt64) -> Bool {
    self == .kernelSockets ? context == 2 || context == 4 : context == 9
  }
}

struct TrafficOwner: Hashable, Sendable {
  var pid: Int32, uniqueID: UInt64
  var userID: UInt32? = nil
}
struct TrafficFlow: Sendable {
  var source: UInt64, provider: UInt32
  var owner: TrafficOwner
  var name: String
  var started: UInt64, observed: UInt64, received: UInt64, sent: UInt64
}
enum TrafficMessage: Sendable {
  case success(context: UInt64, more: Bool)
  case failure(context: UInt64, code: UInt32)
  case added(source: UInt64, provider: UInt32)
  case removed(source: UInt64, flags: UInt16)
  case update(TrafficFlow, closing: Bool)
}
enum TrafficProtocolError: Error { case invalidFrame, unsupportedLayout, invalidDescriptor }

/// Strict, independently written decoder. Endpoint/address/UUID fields are never decoded,
/// retained or logged. Known TCP trailers are opaque; unknown lengths fail closed.
enum TrafficProtocol {
  static func decode(_ data: Data, scope: TrafficCollectionScope = .kernelSockets) throws
    -> [TrafficMessage]
  {
    try data.withUnsafeBytes { try decode($0, scope: scope) }
  }
  static func decode(
    _ bytes: UnsafeRawBufferPointer, scope: TrafficCollectionScope = .kernelSockets
  ) throws -> [TrafficMessage] {
    guard !bytes.isEmpty, bytes.count <= 65536 else { throw TrafficProtocolError.invalidFrame }
    func u16(_ offset: Int) -> UInt16 {
      UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }
    func u32(_ offset: Int) -> UInt32 {
      UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
    func u64(_ offset: Int) -> UInt64 {
      UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }
    var result: [TrafficMessage] = []
    var offset = 0
    while offset < bytes.count {
      guard bytes.count - offset >= 16 else { throw TrafficProtocolError.invalidFrame }
      let length = Int(u16(offset + 12))
      let flags = u16(offset + 14)
      let context = u64(offset)
      guard length >= 16, length <= bytes.count - offset else {
        throw TrafficProtocolError.invalidFrame
      }
      switch u32(offset + 8) {
      case 0:
        guard length == 16 else { throw TrafficProtocolError.invalidFrame }
        result.append(.success(context: context, more: flags & 2 != 0))
      case 1:
        // XNU may append the rejected request to this fixed error prefix. Do not
        // decode/retain that opaque echo; the outer frame bound still applies.
        guard length >= 24 else { throw TrafficProtocolError.invalidFrame }
        result.append(.failure(context: context, code: u32(offset + 16)))
      case 10001:
        guard length == 32 else { throw TrafficProtocolError.invalidFrame }
        let provider = u32(offset + 24)
        guard scope.accepts(provider) else {
          throw TrafficProtocolError.unsupportedLayout
        }
        result.append(.added(source: u64(offset + 16), provider: provider))
      case 10002:
        guard length == 24 else { throw TrafficProtocolError.invalidFrame }
        result.append(.removed(source: u64(offset + 16), flags: flags))
      case 10006:
        guard length >= 152 else { throw TrafficProtocolError.invalidFrame }
        let provider = u32(offset + 144)
        guard scope.accepts(provider) else {
          throw TrafficProtocolError.unsupportedLayout
        }
        let descriptor = offset + 152
        let pidOffset: Int
        let nameOffset: Int
        let identityOffset: Int
        let startOffset: Int
        let observedOffset: Int
        switch (provider, length - 152) {
        case (2, 344), (2, 360):
          pidOffset = 116
          nameOffset = 196
          identityOffset = 0
          startOffset = 16
          observedOffset = 24
        case (4, 280):
          pidOffset = 128
          nameOffset = 132
          identityOffset = 0
          startOffset = 16
          observedOffset = 24
        case (9, 200):
          pidOffset = 32
          nameOffset = 44
          identityOffset = 16
          startOffset = 0
          observedOffset = 8
        default: throw TrafficProtocolError.unsupportedLayout
        }
        let rawPID = u32(descriptor + pidOffset)
        let upid = u64(descriptor + identityOffset)
        let start = u64(descriptor + startOffset)
        let observed = u64(descriptor + observedOffset)
        guard rawPID <= UInt32(Int32.max), observed >= start else {
          throw TrafficProtocolError.invalidDescriptor
        }
        let nameBytes = UnsafeRawBufferPointer(
          rebasing: bytes[(descriptor + nameOffset)..<(descriptor + nameOffset + 64)])
        guard let end = nameBytes.firstIndex(of: 0) else {
          throw TrafficProtocolError.invalidDescriptor
        }
        let name = String(decoding: nameBytes.prefix(end), as: UTF8.self).unicodeScalars.filter {
          !CharacterSet.controlCharacters.contains($0)
        }.map(String.init).joined()
        let userID = provider == 9 ? u32(descriptor + 192) : nil
        let owner =
          rawPID > 0 && upid > 0
          ? TrafficOwner(pid: Int32(rawPID), uniqueID: upid, userID: userID)
          : TrafficOwner(pid: 0, uniqueID: 0, userID: userID)
        result.append(
          .update(
            .init(
              source: u64(offset + 16), provider: provider,
              owner: owner,
              name: owner.pid == 0
                ? "Unattributed sockets" : name.isEmpty ? "PID \(rawPID)" : name,
              started: start, observed: observed, received: u64(offset + 40),
              sent: u64(offset + 56)),
            closing: flags & 4 != 0))
      default: throw TrafficProtocolError.unsupportedLayout
      }
      offset += length
    }
    return result
  }
}
