// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreMIDI
import Foundation
import MokumeCore
import MokumeDiagnostics
import Synchronization

/// 実機の CoreMIDI。**CoreMIDI に触れるのはこの型だけ**である (継ぎ目 ``MIDIBackend`` の本物)。
///
/// UMP の口 (`MIDIInputPortCreateWithProtocol`・MIDI 1.0 の写像) で受ける。古い口 (`MIDIInputPortCreate`)
/// は使わない。許可は要らない。
///
/// 受け取りの口 (入力ポートのブロック) は CoreMIDI が呼ぶスレッドで走るので、**`@Sendable` にして
/// main actor へ隔離しない** (動的な隔離の検査で落ちない・[ADR-0042] 決定 7)。機材ごとの受け取り先は、
/// 接続のたびに振る番号 (`refCon`) で引く。
///
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
final class CoreMIDIBackend: MIDIBackend {
    typealias Handler = @Sendable (_ words: [UInt32], _ hostTime: UInt64) -> Void

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var ready = false
    /// 接続の番号から受け取り先を引く表。受け取りの口 (任意のスレッド) が読む。
    private let handlers = HandlerTable()
    /// 接続している端点ごとの接続の番号。
    private var tags: [Int32: Int] = [:]
    private var nextTag = 1

    func start(changed: @escaping @Sendable () -> Void) {
        let made = MIDIClientCreateWithBlock("mokume" as CFString, &client) { @Sendable _ in
            // 追加・削除・変更のどれでも、一覧を引き直せば足りる (差は係が取る)
            changed()
        }
        guard made == noErr else {
            Diagnostics.warn("midi: could not start CoreMIDI (error \(made)); no MIDI devices will be listed")
            return
        }
        let table = handlers
        let created = MIDIInputPortCreateWithProtocol(client, "mokume input" as CFString, ._1_0, &port) {
            @Sendable list, refCon in
            let tag = Int(bitPattern: refCon)
            guard let handler = table.handler(for: tag) else { return }
            for packet in list.unsafeSequence() {
                let stamp = packet.pointee.timeStamp
                handler(Array(packet.words()), stamp == 0 ? mach_absolute_time() : stamp)
            }
        }
        guard created == noErr else {
            Diagnostics.warn("midi: could not open an input port (error \(created)); no MIDI will be received")
            return
        }
        ready = true
    }

    func sources() -> [MIDISourceInfo] {
        guard ready else { return [] }
        return (0..<MIDIGetNumberOfSources()).compactMap { index in
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { return nil }
            // 外されている機材 (挿していないが設定には残っているもの) は使えない
            var offline: Int32 = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline)
            guard offline == 0 else { return nil }
            var uniqueID: Int32 = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
            let display = (name?.takeRetainedValue() as String?).flatMap { $0.isEmpty ? nil : $0 }
            return MIDISourceInfo(uniqueID: uniqueID, name: display ?? "MIDI source", endpoint: endpoint)
        }
    }

    func connect(_ source: MIDISourceInfo, handler: @escaping Handler) {
        guard ready else { return }
        let tag = nextTag
        nextTag += 1
        handlers.set(handler, for: tag)
        let status = MIDIPortConnectSource(port, source.endpoint, UnsafeMutableRawPointer(bitPattern: tag))
        if status == noErr {
            tags[source.uniqueID] = tag
        } else {
            handlers.set(nil, for: tag)
            Diagnostics.warn("midi: could not connect \"\(source.name)\" (error \(status))")
        }
    }

    func disconnect(_ source: MIDISourceInfo) {
        guard ready, let tag = tags.removeValue(forKey: source.uniqueID) else { return }
        // 抜かれた端点は既に無いことが多い。失敗しても、受け取り先を外せば届かない
        MIDIPortDisconnectSource(port, source.endpoint)
        handlers.set(nil, for: tag)
    }
}

/// 接続の番号から受け取り先を引く表。CoreMIDI の受け取りの口 (任意のスレッド) が読み、主の側が書く。
private nonisolated final class HandlerTable: Sendable {
    private let table = Mutex<[Int: CoreMIDIBackend.Handler]>([:])

    func handler(for tag: Int) -> CoreMIDIBackend.Handler? { table.withLock { $0[tag] } }

    func set(_ handler: CoreMIDIBackend.Handler?, for tag: Int) { table.withLock { $0[tag] = handler } }
}
