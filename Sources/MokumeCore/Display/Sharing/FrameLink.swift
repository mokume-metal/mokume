// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import IOSurface

/// 送り手と受け手のあいだのメッセージ ([ADR-0049] 決定 3・4・[#3920])。
///
/// 受け手は送り手の名前 (目録の `serviceName`) を `bootstrap_look_up` で引き、自分の受信の port と、自分で作った面を
/// 1 通で送って繋ぐ (connect)。送り手は面を検めて受け入れる (accepted) か断る (refused)。繋がっている間、送り手は
/// 面へ書いて GPU の完了を確かめてから知らせ (frame)、受け手は読み終えた面を返す (release)。
///
/// | id | 向き | 中身 (inline) |
/// | --- | --- | --- |
/// | 1 connect | 受け手 → 送り手 | 版。port の記述子は [受け手の port, 面 ×N] |
/// | 2 accepted | 送り手 → 受け手 | 受け手の番号・幅・高さ |
/// | 3 refused | 送り手 → 受け手 | 理由 (``Refusal``) |
/// | 4 frame | 送り手 → 受け手 | 受け手の番号・面の番号・フレームの番号・書いた回数・host time |
/// | 5 release | 受け手 → 送り手 | 受け手の番号・面の番号 |
/// | 6 resized | 送り手 → 受け手 | 幅・高さ |
/// | 7 disconnect | 受け手 → 送り手 | 受け手の番号 |
///
/// 数は little-endian で、`UInt32` と `Int64`/`UInt64` を並べる。**送り手は待たない** — 送りは待ち時間 0 で行い、
/// 受け手が読まずに待ち行列が埋まっていれば `MACH_SEND_TIMED_OUT` で戻る。受け手が消えたことは、送り手が受け手の
/// port に頼んだ dead-name の知らせ (id 72) で知る。
///
/// [ADR-0049]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0049-share-frames-to-other-processes.md
/// [#3920]: https://github.com/mokume-metal/mokume/issues/3920
package nonisolated enum FrameLink {
    /// 約束の版。目録の版 (``FrameListing/schemaVersion``) と同じ数で上げる。
    package static let version: UInt32 = 1

    /// メッセージの種類 (`msgh_id`)。
    package enum Kind: Int32, Sendable {
        case connect = 1
        case accepted = 2
        case refused = 3
        case frame = 4
        case release = 5
        case resized = 6
        case disconnect = 7
    }

    /// 受け手の port が死んだ知らせの `msgh_id` (`MACH_NOTIFY_DEAD_NAME`)。
    static let deadNameID = Int32(MACH_NOTIFY_DEAD_NAME)

    /// 断った理由。
    package enum Refusal: UInt32, Sendable, CustomStringConvertible {
        /// 版が違う。
        case version = 1
        /// 面の枚数が範囲 (``surfaceCountRange``) の外。
        case surfaceCount = 2
        /// 面の形式が半精度の RGBA (`RGhA`) でない、または引けない。
        case surfaceFormat = 3
        /// 面の大きさが描く解像度と違う。
        case surfaceSize = 4
        /// 受け手の数が上限 (``receiverLimit``) に達している。
        case receiverLimit = 5
        /// 形の壊れた頼み。
        case malformed = 6

        package var description: String {
            switch self {
            case .version: "the receiver speaks another version of the hand-over"
            case .surfaceCount:
                "a receiver must hand over \(FrameLink.surfaceCountRange.lowerBound) to \(FrameLink.surfaceCountRange.upperBound) surfaces"
            case .surfaceFormat: "the surfaces are not half-float RGBA ('RGhA')"
            case .surfaceSize: "the surfaces are not the size the sketch draws at"
            case .receiverLimit: "\(FrameLink.receiverLimit) receivers are already connected"
            case .malformed: "the request is malformed"
            }
        }
    }

    /// 同時に繋げる受け手の数の上限。作品のフレームの予算と記憶を、誤った受け手に食わせないため (ADR-0049 決定 4)。
    package static let receiverLimit = 4
    /// 受け手 1 つが渡せる面の枚数。下限 2 は、1 枚を受け手が読んでいる間に次を書くため。
    package static let surfaceCountRange = 2...8
    /// 面の形式 (半精度の RGBA)。
    package static let surfaceFormat: OSType = 0x5247_6841  // 'RGhA'

    /// 面の属性の名前。frame を送る前に載せる。
    package enum Attribute {
        /// フレームの番号 (`mokume.frameCount` と同じもの)。
        package static let frameCount = "mokume.frameCount"
        /// 面へ書いた回数。焼きを見送るとフレームの番号とずれる。
        package static let writes = "mokume.frame"
        /// 描いた時刻 (`mach_absolute_time` の単位)。
        package static let hostTime = "mokume.hostTime"
        /// 色空間の名前 (`CGColorSpace` の名前)。
        package static let colorSpace = "mokume.colorSpace"
        /// alpha の扱い (`premultiplied`)。
        package static let alpha = "mokume.alpha"
    }

    // MARK: - 中身

    /// inline の数を並べる。
    package struct Payload: Equatable, Sendable {
        package private(set) var bytes: [UInt8] = []

        package init() {}
        init(bytes: [UInt8]) { self.bytes = bytes }

        package mutating func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }
        package mutating func append(_ value: Int64) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }
        package mutating func append(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }

        /// 先頭から読む。
        package struct Reader {
            let bytes: [UInt8]
            var offset = 0

            package mutating func uint32() -> UInt32? { read(UInt32.self).map { UInt32(littleEndian: $0) } }
            package mutating func int64() -> Int64? { read(Int64.self).map { Int64(littleEndian: $0) } }
            package mutating func uint64() -> UInt64? { read(UInt64.self).map { UInt64(littleEndian: $0) } }

            private mutating func read<T: FixedWidthInteger>(_: T.Type) -> T? {
                let size = MemoryLayout<T>.size
                guard offset + size <= bytes.count else { return nil }
                var value: T = 0
                withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: bytes[offset..<offset + size]) }
                offset += size
                return value
            }
        }

        package var reader: Reader { Reader(bytes: bytes) }
    }

    /// 受け取った 1 通。
    package struct Received {
        package var kind: Int32
        /// port の記述子で届いた名前 (並びのまま)。**受け取った側が手放す。**
        package var ports: [mach_port_t]
        package var payload: Payload
    }

    // MARK: - 送る

    private static let headerSize = MemoryLayout<mach_msg_header_t>.size  // 24
    private static let bodySize = MemoryLayout<mach_msg_body_t>.size  // 4
    private static let descriptorSize = MemoryLayout<mach_msg_port_descriptor_t>.size  // 12

    /// 単純なメッセージを送る。**待たない** (待ち時間 0)。送れなければ戻り値で言う。
    @discardableResult
    package static func send(_ kind: Kind, to port: mach_port_t, payload: Payload = Payload()) -> kern_return_t {
        send(id: kind.rawValue, to: port, ports: [], payload: payload)
    }

    /// 受け手から送り手へ繋ぐ。`reply` は受け手の受信の port (送信の権利を作って渡す)、面は送信の権利ごと渡す。
    ///
    /// **待たない。** 面の port は送れても送れなくても手放される (送れなければこの関数が手放す)。
    @discardableResult
    package static func connect(
        to service: mach_port_t, reply: mach_port_t, surfaces: [IOSurfaceRef], version: UInt32 = version
    ) -> kern_return_t {
        var payload = Payload()
        payload.append(version)
        var ports: [(mach_port_t, mach_msg_type_name_t)] = [(reply, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))]
        for surface in surfaces {
            ports.append((IOSurfaceCreateMachPort(surface), mach_msg_type_name_t(MACH_MSG_TYPE_MOVE_SEND)))
        }
        return send(id: Kind.connect.rawValue, to: service, ports: ports, payload: payload)
    }

    private static func send(
        id: Int32, to port: mach_port_t, ports: [(mach_port_t, mach_msg_type_name_t)], payload: Payload
    ) -> kern_return_t {
        let complex = !ports.isEmpty
        let size = headerSize + (complex ? bodySize + descriptorSize * ports.count : 0) + payload.bytes.count
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let header = buffer.assumingMemoryBound(to: mach_msg_header_t.self)
        header.pointee.msgh_bits = UInt32(MACH_MSG_TYPE_COPY_SEND) | (complex ? MACH_MSGH_BITS_COMPLEX : 0)
        header.pointee.msgh_size = mach_msg_size_t(size)
        header.pointee.msgh_remote_port = port
        header.pointee.msgh_local_port = mach_port_t(MACH_PORT_NULL)
        header.pointee.msgh_id = id
        var offset = headerSize
        if complex {
            buffer.storeBytes(of: UInt32(ports.count), toByteOffset: offset, as: UInt32.self)
            offset += bodySize
            for (name, disposition) in ports {
                buffer.storeBytes(of: name, toByteOffset: offset, as: UInt32.self)
                // pad1 (32 bit)・pad2 (16 bit)・disposition (8 bit)・type (8 bit, MACH_MSG_PORT_DESCRIPTOR = 0)
                buffer.storeBytes(of: disposition << 16, toByteOffset: offset + 8, as: UInt32.self)
                offset += descriptorSize
            }
        }
        payload.bytes.withUnsafeBytes { buffer.advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        let result = mach_msg(header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, mach_msg_size_t(size), 0, 0, 0, 0)
        if result != KERN_SUCCESS, complex {
            // 送れなかった記述子の権利は、まだこちらに在る。作るはずだった送信の権利 (MAKE_SEND) は作られていない
            for (name, disposition) in ports where disposition == mach_msg_type_name_t(MACH_MSG_TYPE_MOVE_SEND) {
                mach_port_deallocate(mach_task_self_, name)
            }
        }
        return result
    }

    // MARK: - 受ける

    /// 受信の port から 1 通受ける。**来ていなければ待たずに `nil`** (`timeout` ミリ秒まで待つ)。
    ///
    /// port の記述子以外の記述子 (out-of-line など) を含む、形の壊れた 1 通は、中身ごと捨てて次を見る。
    package static func receive(on port: mach_port_t, timeout: mach_msg_timeout_t = 0) -> Received? {
        let capacity = 4096
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { buffer.deallocate() }
        while true {
            let header = buffer.assumingMemoryBound(to: mach_msg_header_t.self)
            let result = mach_msg(
                header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, mach_msg_size_t(capacity), port, timeout, 0)
            // 大きすぎる 1 通は、MACH_RCV_LARGE を立てていないのでカーネルが捨てている
            if result == MACH_RCV_TOO_LARGE { continue }
            guard result == KERN_SUCCESS else { return nil }
            let size = Int(header.pointee.msgh_size)
            var offset = headerSize
            var ports: [mach_port_t] = []
            if header.pointee.msgh_bits & MACH_MSGH_BITS_COMPLEX != 0 {
                let count = Int(buffer.load(fromByteOffset: offset, as: UInt32.self))
                offset += bodySize
                var wellFormed = offset + count * descriptorSize <= size
                for index in 0..<count where wellFormed {
                    let at = offset + index * descriptorSize
                    let type = buffer.load(fromByteOffset: at + 11, as: UInt8.self)
                    guard type == UInt8(MACH_MSG_PORT_DESCRIPTOR) else {
                        wellFormed = false
                        break
                    }
                    ports.append(buffer.load(fromByteOffset: at, as: UInt32.self))
                }
                guard wellFormed else {
                    mach_msg_destroy(header)
                    continue
                }
                offset += count * descriptorSize
            }
            let payload = Payload(
                bytes: offset < size
                    ? Array(UnsafeRawBufferPointer(start: buffer.advanced(by: offset), count: size - offset)) : [])
            return Received(kind: header.pointee.msgh_id, ports: ports, payload: payload)
        }
    }

    /// 送信の権利 (と、死んだ名前の参照) を手放す。
    package static func releaseName(_ name: mach_port_t) {
        guard name != mach_port_t(MACH_PORT_NULL) else { return }
        var refs: mach_port_urefs_t = 0
        if mach_port_get_refs(mach_task_self_, name, MACH_PORT_RIGHT_DEAD_NAME, &refs) == KERN_SUCCESS, refs > 0 {
            mach_port_mod_refs(mach_task_self_, name, MACH_PORT_RIGHT_DEAD_NAME, -mach_port_delta_t(refs))
        }
        if mach_port_get_refs(mach_task_self_, name, MACH_PORT_RIGHT_SEND, &refs) == KERN_SUCCESS, refs > 0 {
            mach_port_mod_refs(mach_task_self_, name, MACH_PORT_RIGHT_SEND, -mach_port_delta_t(refs))
        }
    }

    /// 送信の権利の参照を 1 つだけ手放す。同じ port の権利をもう 1 つ受け取ったとき (名前は重なる) に使う。
    static func releaseOneSend(_ name: mach_port_t) {
        mach_port_mod_refs(mach_task_self_, name, MACH_PORT_RIGHT_SEND, -1)
    }

    /// dead-name の知らせから、死んだ名前を読む (知らせの本体は NDR の 8 バイトの後に名前)。
    static func deadName(in received: Received) -> mach_port_t? {
        var reader = received.payload.reader
        _ = reader.uint64()  // NDR
        return reader.uint32()
    }
}
