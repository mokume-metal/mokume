// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeAudio

/// 構成の変化の知らせを受けて始め直す道 ([#2529](https://github.com/mokume-metal/mokume/issues/2529))。
/// 実機のマイクも `AVAudioEngine` も要らない。
///
/// ``MicrophoneSource`` は知らせを受けた糸で知らせに載ったエンジンを控え、操作の列へ 1 段送って
/// から今のエンジンと比べる。同じエンジンの知らせが 2 本たまると、1 本目の始め直しが古いエンジンを
/// 手放して新しいエンジンを作り、新しいエンジンが古いエンジンの番地 (`ObjectIdentifier`) を
/// 引き継ぎうる。番地で控えていた頃は、2 本目 (古いエンジンの知らせ) で新しいエンジンを止め直していた。
///
/// 検査は ``MicrophoneSource`` が使うのと同じ口 (``MicrophoneSource/observeConfigurationChanges(center:name:on:_:)``)
/// に、検査専用の知らせの中継所と偽のエンジンを渡す。比べ方 (``NotedObject/refers(to:)``) も
/// ``MicrophoneSource`` と同じものを使う。
@Suite("マイクの構成の変化の知らせ")
struct MicrophoneConfigurationChangeTests {
    /// 偽のエンジン。中身は要らない — 見るのは同一性と番地だけである。
    nonisolated final class FakeEngine {}

    /// 番地を引き継ぐまで作り直す回数の上限。
    nonisolated static let reuseAttempts = 256

    /// 今のエンジンを持ち、知らせが今のエンジンについてのものなら「止めて作り直す」持ち主。
    /// ``MicrophoneSource`` の `configurationChanged` と同じ比べ方をする。操作の列の上でだけ触る。
    nonisolated final class Holder: @unchecked Sendable {
        var engine: FakeEngine? = FakeEngine()
        private(set) var restarts = 0
        /// 作り直したエンジンが、手放したエンジンの番地を引き継いだか。
        private(set) var reusedAddress = false
        /// 番地の一致を探す間に作って捨てなかったエンジン (同じ番地を返させないために生かしておく)。
        private var held: [FakeEngine] = []

        func changed(_ noted: NotedObject) {
            // 今のエンジンを手元の定数に束ねない — 束ねると、手放した後も関数の終わりまで
            // 古いエンジンが生き、作り直したエンジンが番地を引き継げない
            guard let gone = engine.map(ObjectIdentifier.init), engine.map(noted.refers(to:)) == true
            else { return }
            restarts += 1
            engine = nil  // 止めて手放す (`stopEngine`)
            // 作り直す (`startEngine`)。手放したエンジンの番地を引き継ぐまで作り直す
            var made = FakeEngine()
            while ObjectIdentifier(made) != gone, held.count < MicrophoneConfigurationChangeTests.reuseAttempts {
                held.append(made)
                made = FakeEngine()
            }
            reusedAddress = ObjectIdentifier(made) == gone
            engine = made
        }
    }

    /// 知らせを `notes` 本続けて送り、すべて操作の列で処理し終えてから持ち主を返す。
    ///
    /// 列を止めておき、知らせが全部たまってから流す — 窓で起きるのは、知らせを受けた糸が先に
    /// 走って、列が後から追い付く形である。
    private func send(
        _ notes: Int, about engine: (Holder) -> FakeEngine?
    ) -> Holder {
        let center = NotificationCenter()
        let name = Notification.Name("org.mokume.test.configurationChange.\(UUID().uuidString)")
        let queue = DispatchQueue(label: "org.mokume.test.audio.control")
        let holder = Holder()
        let observer = MicrophoneSource.observeConfigurationChanges(
            center: center, name: name, on: queue
        ) { noted in holder.changed(noted) }
        defer { center.removeObserver(observer) }

        queue.suspend()
        // 知らせに載るのは、知らせを送った時点の今のエンジン。送り終えたら手元の参照は落とす。
        // 知らせ (`NSNotification`) は自動解放の池に残ってエンジンを掴み続けるので、池ごと捨てる
        autoreleasepool {
            let about = engine(holder)
            for _ in 0..<notes { center.post(name: name, object: about) }
        }
        queue.resume()
        queue.sync {}
        return holder
    }

    @Test("同じエンジンの知らせが 2 本たまっても、始め直すのは 1 回で、作り直したエンジンを止め直さない")
    func aSecondNoticeAboutTheReplacedEngineDoesNotRestartTheNewOne() throws {
        let holder = send(2) { $0.engine }

        try #require(
            holder.reusedAddress,
            "手放したエンジンの番地を引き継ぐエンジンを、\(Self.reuseAttempts) 回作り直しても作れなかった (この検査は何も確かめていない)")
        // 1 本目で始め直し、2 本目 (古いエンジンの知らせ) では新しいエンジンを止め直さない
        #expect(holder.restarts == 1)
    }

    @Test("今のエンジンの知らせでは 1 回始め直し、どのエンジンも載らない知らせでは始め直さない")
    func aNoticeAboutTheCurrentEngineRestartsOnce() {
        #expect(send(1) { $0.engine }.restarts == 1)
        #expect(send(1) { _ in nil }.restarts == 0)
        // 別のエンジン (今のエンジンではない) の知らせでも始め直さない
        let other = FakeEngine()
        #expect(send(1) { _ in other }.restarts == 0)
    }
}
