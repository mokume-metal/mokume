// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeAudio
@testable import MokumeCore

/// 走っている実行へ足せない所 (`setup()`・`draw()`・入力のコールバックの外) から、音の作る口を呼ぶ ([#2740])。
///
/// **呼んだ口の名前で言う。** 以前は作る口の中の ``SketchPart/attach(_:)-(Inlet)`` が黙って `false` を返し、
/// 足されていない (鳴らない・解析されない) ものを成功として返していた。警告は利用者が呼んでいない `attach()` を
/// 名乗り、投げる口 (`loadSound` など) も投げなかった。#2683 (#2741) のカメラの口と同じ形に揃える — 投げる口は
/// 読む前に `notRunning(call:)` を投げ、投げない口は口の名前で 1 度だけ警告して、今までどおりのものを返す。
///
/// 走らせずに投げる・警告することを見るので、GPU は要らない。音も鳴らさず、機材も開かない (足さないので開かない)。
///
/// [#2740]: https://github.com/mokume-metal/mokume/issues/2740
@MainActor
@Suite("走っている実行の外から呼んだ音の作る口")
struct AudioOutsideRunTests {
    /// 走らせないスケッチ。
    final class Bare: Sketch {
        init() {}
        func draw() {}
    }

    /// Issue の例。スケッチの `init()` で音を読む。
    final class Drums: Sketch {
        var kick: SoundFile?
        var failure: AudioFailure?
        init() {
            do { kick = try loadSound("kick.wav") } catch { failure = error }
        }
        func draw() {}
    }

    /// 音声として読めない中身を書いたファイル。外で呼んだ口がこれを読めば `unreadable` が返る。
    static func garbageFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-audio-outside-\(UUID().uuidString).wav")
        try Data("not audio".utf8).write(to: url)
        return url
    }

    @Test("スケッチの init() で loadSound を呼ぶと、ファイルを読まずに notRunning を投げ、loadSound(_:) を名乗って 1 度だけ警告する")
    func loadSoundInInitThrowsNotRunning() {
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            let drums = Drums()
            _ = Drums()
            #expect(drums.kick == nil)
            // 無いファイルなのに notFound でない — 探しに行く前に断っている
            #expect(drums.failure == .notRunning(call: "loadSound(_:)"))
            #expect(log.messages.count == 1, "2 つ作っても 1 行")
            let message = log.message(for: "loadSound(_:)")
            #expect(message?.hasPrefix("loadSound(_:) only works inside setup()") == true)
            #expect(message?.contains("It threw an error instead of returning anything.") == true)
            #expect(message?.hasSuffix("Call it from setup()") == true)
            // 利用者が呼んでいない attach() を名乗らない
            #expect(log.message(for: "attach") == nil)
            #expect(!log.messages.contains { $0.contains("attach()") })
        }
    }

    @Test("投げる 3 口は、読む前に呼んだ口の名前で notRunning を投げ、口ごとに 1 度だけ警告する")
    func throwingMakersThrowNotRunning() throws {
        let garbage = try Self.garbageFile()
        defer { try? FileManager.default.removeItem(at: garbage) }
        let log = OutsideRun()
        try OutsideRun.$current.withValue(log) {
            let sketch = Bare()
            for _ in 0..<2 {
                // 読めないファイルでも unreadable でない — 読む前に断っている
                #expect(throws: AudioFailure.notRunning(call: "loadSound(_:)")) {
                    try sketch.loadSound(garbage.path)
                }
                #expect(throws: AudioFailure.notRunning(call: "createAudioIn(file:)")) {
                    try sketch.createAudioIn(file: garbage.path)
                }
                #expect(throws: AudioFailure.notRunning(call: "createAudioIn(samples:sampleRate:)")) {
                    try sketch.createAudioIn(samples: [0.1, -0.1], sampleRate: 48_000)
                }
            }
            let calls = ["loadSound(_:)", "createAudioIn(file:)", "createAudioIn(samples:sampleRate:)"]
            #expect(log.messages.count == calls.count, "口ごとに 1 行")
            for call in calls {
                let message = try #require(log.message(for: call), "\(call) が言っていない")
                #expect(message.contains("It threw an error instead of returning anything."))
            }
            #expect(log.message(for: "attach") == nil)
            // 渡した値が使えなければ、走っているかより先にその場合を投げる (値の検めは読みも開きもしない)
            #expect(throws: AudioFailure.empty) { try sketch.createAudioIn(samples: [], sampleRate: 48_000) }
            #expect(throws: AudioFailure.invalidSampleRate(0)) {
                try sketch.createAudioIn(samples: [0], sampleRate: 0)
            }
        }
    }

    /// 投げない口の名前と、作る手続き。
    static let quietMakers: [(call: String, make: (Bare) -> AnyObject)] = [
        ("createSinOsc()", { $0.createSinOsc() }),
        ("createSqrOsc()", { $0.createSqrOsc() }),
        ("createTriOsc()", { $0.createTriOsc() }),
        ("createSawOsc()", { $0.createSawOsc() }),
        ("createWhiteNoise()", { $0.createWhiteNoise() }),
        ("createPinkNoise()", { $0.createPinkNoise() }),
        ("createLowPass()", { $0.createLowPass() }),
        ("createHighPass()", { $0.createHighPass() }),
        ("createBandPass()", { $0.createBandPass() }),
        ("createReverb()", { $0.createReverb() }),
        ("createDelay()", { $0.createDelay() }),
        ("createAudioIn(device:)", { $0.createAudioIn() }),
    ]

    @Test("投げない 12 口は、今までどおり足されていないものを返し、呼んだ口の名前で 1 度だけ警告する")
    func quietMakersWarnByTheirOwnName() {
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            let sketch = Bare()
            for _ in 0..<2 {
                for maker in Self.quietMakers { _ = maker.make(sketch) }
            }
            #expect(log.messages.count == Self.quietMakers.count, "口ごとに 1 行")
            for maker in Self.quietMakers {
                let message = log.message(for: maker.call)
                #expect(message?.hasPrefix("\(maker.call) only works inside setup()") == true, "\(maker.call)")
                #expect(message?.contains("was returned instead") == true, "\(maker.call)")
            }
            #expect(log.message(for: "attach") == nil)
            #expect(!log.messages.contains { $0.contains("attach()") })
            // 合成音のステージは足されず、控えにも残らない (今までどおり。次に走っている所で呼べば作り直す)
            #expect(SynthStage.stages[ObjectIdentifier(sketch)]?.stage == nil)
            // 包絡は音の流れに入らない (足さない) ので、外で作っても何も言わない
            _ = sketch.createEnv()
            #expect(log.message(for: "createEnv()") == nil)
        }
    }

    @Test("外で AudioIn の stop() を呼ぶと、呼んでいない detach() ではなく stop() を名乗り、1 度だけ警告する (#2793)")
    func stopNamesItselfOutsideTheRun() {
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            let sketch = Bare()
            let audio = sketch.createAudioIn()
            audio.stop()
            audio.stop()
            let said = log.messages.filter { $0.hasPrefix("stop()") }
            #expect(said.count == 1, "2 度呼んでも 1 行")
            #expect(said.first?.hasPrefix("stop() only works inside setup()") == true)
            #expect(said.first?.contains("so it did nothing") == true)
            #expect(log.message(for: "detach") == nil)
            #expect(!log.messages.contains { $0.contains("detach()") })
        }
    }

    @Test("notRunning の文面は口の名前と呼べる場所を名乗り、面の話をしない")
    func noticeNamesTheCallAndWhereItWorks() {
        let text = AudioFailure.notRunning(call: "loadSound(_:)").description
        #expect(text == OutsideRun.notAttachedNotice("loadSound(_:)"))
        #expect(text.hasPrefix("loadSound(_:) only works inside setup(), draw() or an input callback"))
        #expect(text.hasSuffix("\nCall it from setup()"))
        #expect(!text.contains("surface"), "面から作る口の文面ではない")
        // 「走っていない」とは言い切らない (#1322)。draw() の最中に Task から呼んでもこの場合になる
        #expect(!text.contains("not running"))
    }
}
