// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeAudio

/// 構成の変化の知らせを受けて始め直す道 ([#2529](https://github.com/mokume-metal/mokume/issues/2529))。
/// 実機のマイクも `AVAudioEngine` も要らない。
///
/// ``MicrophoneSource`` は知らせを受けた糸で知らせに載ったエンジンを控え、操作の列へ 1 段送って
/// から今のエンジンと比べる。列で待つ間に別の口が古いエンジンを手放して新しいエンジンを作ると
/// (一覧の変化の「抜かれた → 挿された」・`stop()` の直後の `start()`・始め直しの途中の失敗)、
/// 新しいエンジンが古いエンジンの番地 (`ObjectIdentifier`) を引き継ぎうる。番地で控えていた頃は、
/// 古いエンジンの知らせで新しいエンジンを止め直しえた。
///
/// 検査は ``MicrophoneSource`` が使うのと同じ 2 つの口 — 知らせを受けて控え列へ渡す
/// ``MicrophoneSource/observeConfigurationChanges(center:name:on:_:)`` と、始め直すかの判定
/// ``MicrophoneSource/restartIfCurrent(_:engine:device:isPresent:running:restart:)`` — に、検査専用の
/// 知らせの中継所と偽のエンジンを渡す。
@Suite("マイクの構成の変化の知らせ")
struct MicrophoneConfigurationChangeTests {
    /// 偽のエンジン。中身は要らない — 見るのは同一性と番地だけである。
    nonisolated final class FakeEngine {}

    /// 1 回の抜き差しで、番地を引き継ぐまで作り直す回数の上限。
    nonisolated static let reuseAttempts = 1024
    /// 番地の引き継ぎが起きるまで、抜き差しの筋書きを繰り返す回数の上限。
    nonisolated static let scenarioAttempts = 16

    /// 今のエンジンを持つ偽の持ち主。操作の列の上でだけ触る。
    nonisolated final class Holder: @unchecked Sendable {
        var engine: FakeEngine? = FakeEngine()
        var running = true
        var devicePresent = true
        private(set) var restarts = 0
        /// 一覧の変化で作り直したエンジンが、手放したエンジンの番地を引き継いだか。
        private(set) var reusedAddress = false
        /// 一覧の変化で手放したエンジンが、作り直す前に解放されていたか (生きていれば番地は
        /// 引き継がれようがない)。
        private(set) var releasedBeforeRemaking = false
        /// 番地の一致を探す間に作って捨てなかったエンジン (同じ番地を返させないために生かしておく)。
        private var held: [FakeEngine] = []

        /// 構成の変化の知らせ。本体の `configurationChanged` と同じく判定の口を通す。
        func configurationChanged(_ noted: NotedObject) {
            MicrophoneSource.restartIfCurrent(
                noted, engine: engine, device: 1, isPresent: { [devicePresent] _ in devicePresent },
                running: running
            ) { _ in
                restarts += 1
                engine = FakeEngine()
            }
        }

        /// 一覧の変化で抜かれて挿された (`devicesChanged` が 1 回の呼び出しで `stopEngine` →
        /// `startEngine` する)。手放したエンジンの番地を引き継ぐまで作り直す。
        func unpluggedAndPluggedBackIn() {
            guard let gone = engine.map(ObjectIdentifier.init) else { return }
            weak var probe = engine
            engine = nil  // `stopEngine`
            releasedBeforeRemaking = probe == nil
            var made = FakeEngine()  // `startEngine`
            while ObjectIdentifier(made) != gone, held.count < MicrophoneConfigurationChangeTests.reuseAttempts {
                held.append(made)
                made = FakeEngine()
            }
            reusedAddress = ObjectIdentifier(made) == gone
            engine = made
        }
    }

    /// 列を止めた間に、`first` を列へ積んでから `about` が選ぶエンジンの知らせを送る。全部
    /// たまってから列を流し、処理し終えた持ち主を返す。
    ///
    /// 窓で起きるのは、知らせを受けた糸が先に走って、列が後から追い付く形である。
    private func run(
        _ holder: Holder = Holder(),
        first: (@Sendable () -> Void)? = nil,
        notice about: (Holder) -> FakeEngine?
    ) -> Holder {
        let center = NotificationCenter()
        let name = Notification.Name("org.mokume.test.configurationChange.\(UUID().uuidString)")
        let queue = DispatchQueue(label: "org.mokume.test.audio.control")
        let observer = MicrophoneSource.observeConfigurationChanges(
            center: center, name: name, on: queue
        ) { noted in holder.configurationChanged(noted) }
        defer { center.removeObserver(observer) }

        queue.suspend()
        if let first { queue.async(execute: first) }
        // 知らせ (`NSNotification`) は自動解放の池に残ってエンジンを掴み続けるので、池ごと捨てる
        autoreleasepool {
            center.post(name: name, object: about(holder))
        }
        queue.resume()
        queue.sync {}
        return holder
    }

    /// 構成の変化の知らせ (古いエンジン A) が列で待つ間に、一覧の変化が A を止めて B を作る。
    /// 列には一覧の変化が先に乗っている (機材の抜き差しでは両方の知らせが出る)。
    ///
    /// **主張の強さは、B が A の番地を引き継いだかで変わる。番地の引き継ぎは合否の条件にしない。**
    ///
    /// - 引き継いだ回 (強い主張): 直す前に取り違えた回そのもので、控えを `ObjectIdentifier` に
    ///   戻すと、ここで B を始め直して赤になる
    /// - 引き継がなかった回 (弱い主張): 番地で控えても取り違えは起きないので、古い知らせで B を
    ///   始め直さないことだけを見る。引き継がなかったことは期待の文面で名乗る
    ///
    /// 引き継ぐかは malloc 次第で、手元では毎回引き継いだが、専用機で 3302 本を並べた後の実行では
    /// 引き継がなかった (#2585 の queue)。確率を上げるため、1 回の抜き差しで最大
    /// ``reuseAttempts`` 回作り直し、引き継ぐまで筋書きを最大 ``scenarioAttempts`` 回繰り返す。
    /// 判定そのもの (知らせが今のエンジンについてか) は、番地に依らない
    /// ``aNoticeAboutTheCurrentEngineRestartsOnce()`` が見る。
    @Test("知らせが列で待つ間に抜き差しでエンジンを作り直すと、古いエンジンの知らせでは新しいエンジンを止め直さない")
    func aNoticeAboutAnEngineReplacedMeanwhileDoesNotRestartTheNewOne() {
        for attempt in 1...Self.scenarioAttempts {
            let holder = Holder()
            _ = run(holder, first: { holder.unpluggedAndPluggedBackIn() }, notice: { $0.engine })
            let reuse: Comment =
                holder.reusedAddress
                ? "B は A の番地を引き継いだ (強い主張・\(attempt) 回目)"
                : holder.releasedBeforeRemaking
                    ? "B は A の番地を引き継がなかった (弱い主張・\(attempt) 回目・\(Self.reuseAttempts) 回作り直した)"
                    : "A が作り直す前に解放されず、番地は引き継がれようがなかった (弱い主張・\(attempt) 回目)"
            #expect(holder.restarts == 0, "古いエンジンの知らせで新しいエンジンを止め直した — \(reuse)")
            if holder.reusedAddress { return }
        }
    }

    /// **判定を見る主の検査。番地の使い回しに依らない。** 判定 (知らせが今のエンジンについてか) を
    /// 消すと、物の載らない知らせ・別の物の知らせで始め直して赤になる。
    @Test("今のエンジンの知らせでは 1 回始め直し、どのエンジンも載らない・別のエンジンの知らせでは始め直さない")
    func aNoticeAboutTheCurrentEngineRestartsOnce() {
        #expect(run(notice: { $0.engine }).restarts == 1)
        #expect(run(notice: { _ in nil }).restarts == 0)
        let other = FakeEngine()
        #expect(run(notice: { _ in other }).restarts == 0)
    }

    @Test("今のエンジンの知らせでも、機材が消えた・動いていないときは始め直さない")
    func aNoticeAboutTheCurrentEngineNeedsTheDeviceAndARunningState() {
        let gone = Holder()
        gone.devicePresent = false
        #expect(run(gone, notice: { $0.engine }).restarts == 0)
        let stopped = Holder()
        stopped.running = false
        #expect(run(stopped, notice: { $0.engine }).restarts == 0)
    }
}
