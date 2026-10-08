// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeCore
import MokumeDiagnostics

/// 1 つのスケッチの合成した音を束ねる入り口。スケッチごとに 1 つ、最初に合成した音を作った
/// ときに足される (``Sketch/createSinOsc()`` ほか)。
///
/// 合成した音は 1 つずつ入り口にはしない。標本を作るのは 1 つの ``SynthRack`` で、このステージが
/// フレームごとに 1 度だけ進め、各音の解析の値を更新する。**ステージが無ければ合成した音は
/// 解析できない。**
///
/// ## 実際に鳴らす・鳴らさない
///
/// 開くときに ``Sketch/clock`` を読み、``SoundFile`` と同じ区別をする。
///
/// - **実時間** (窓に出しながら動かす) では、ラックを音の流れ (``RackPlayer``) へ入れて実際に鳴らす。
///   標本は音の側のスレッドが作る
/// - **フレームの数え方** (書き出し・検査) では**鳴らさず**、ラックの標本を「フレームの番号 ×
///   標本化率 ÷ fps」まで進める。窓がフレームの番号だけで決まるので、同じ設定から何度書き出しても
///   同じ値になる ([ADR-0028] 決定 7・[ADR-0025] の水準 2)
/// - 出力が開けないときは、鳴らさずに実時間で進め、そのことを 1 度だけ知らせる
///
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
final class SynthStage: Inlet {
    /// 標本化率 (Hz)。実機の出力と違えば、混ぜる節が変換する。
    static let sampleRate = 48_000.0

    /// スケッチごとのステージ。**弱く持つ** — ステージを持つのは走っているスケッチ (入り口の並び)
    /// で、ここではない。スケッチが終わっても閉じられなかったとき (検査が閉じずに捨てるとき) に、
    /// 手放された後の同じ番地の別のスケッチが、前のステージを引き継がないようにするため、
    /// 持ち主も照らし合わせる。
    private static var stages: [ObjectIdentifier: Weak] = [:]

    private struct Weak {
        weak var stage: SynthStage?
    }

    let rack: SynthRack
    private weak var owner: (any Sketch)?
    private let injectedFlow: SoundFlow?
    private let now: () -> TimeInterval
    private let warn: (String) -> Void
    private var pace: Pace?
    private var frame = 0
    /// 解析を更新する音。**弱く持つ** — 音そのものはラックの節として終わりまで残るので、使う側が
    /// 手放した音の解析は要らない (手放した音は鳴り続ける)。
    private var sounds: [WeakSound] = []
    private var noticed: Set<Notice> = []
    /// 閉じた (スケッチが終わった)。以後の操作は捨てる。
    private(set) var isClosed = false

    private struct WeakSound {
        weak var sound: SynthSound?
    }

    /// ラックの標本を進める時計。
    private enum Pace {
        /// フレームの数え方 (固定の時計)。鳴らさない。`origin` は始めたフレーム。
        case frames(perSecond: Int, origin: Int)
        /// 実時間。出力が開けないとき。`base` は始めたときにラックが作っていた標本の数。
        case realTime(origin: TimeInterval, base: Int)
        /// 実際に鳴らしている。標本は音の側のスレッドが作る。
        case speaker(RackPlayer)
    }

    /// 1 度だけ言う知らせ。
    private enum Notice: Hashable {
        case noOutput
        case capacity
    }

    private init(
        owner: any Sketch, flow: SoundFlow?, now: @escaping () -> TimeInterval,
        warn: @escaping (String) -> Void
    ) {
        self.owner = owner
        injectedFlow = flow
        self.now = now
        self.warn = warn
        rack = SynthRack(sampleRate: flow?.synthesisRate ?? Self.sampleRate)
    }

    /// `sketch` のステージ。まだ無ければ作って、走っているスケッチへ足す。
    ///
    /// - Parameter flow: 鳴らす流れを差し替える (検査)。最初に作るときだけ効く。
    static func stage(
        for sketch: any Sketch, flow: SoundFlow? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        warn: @escaping (String) -> Void = Diagnostics.warn
    ) -> SynthStage {
        let key = ObjectIdentifier(sketch)
        if let existing = stages[key]?.stage, !existing.isClosed, existing.owner === sketch {
            return existing
        }
        stages = stages.filter { $0.value.stage != nil }
        let stage = SynthStage(owner: sketch, flow: flow, now: now, warn: warn)
        stages[key] = Weak(stage: stage)
        // 走っていなければ足せない (足す口が診断に出す)。次に呼ばれたとき作り直す
        if !sketch.attach(stage) { stages[key] = nil }
        return stage
    }

    /// 音を数に入れる。フレームごとに解析の値を更新する。
    func register(_ sound: SynthSound) {
        sounds.append(WeakSound(sound: sound))
    }

    /// 知らせを診断へ出す。同じ種類を 1 度だけ言うのは呼ぶ側の仕事。
    func warning(_ message: String) {
        warn(message)
    }

    /// ラックの節の置き場が埋まったことを 1 度だけ知らせる。
    func noticeCapacity() {
        notice(
            .capacity,
            "No more synthesized sounds can be created: a sketch holds at most "
                + "\(SynthRack.capacity) oscillators, noises and effects together, and they "
                + "stay until the sketch ends. Create them once in setup() and reuse them "
                + "instead of creating new ones in draw()")
    }

    // MARK: - Inlet

    func open() throws {
        guard let owner else { return }
        frame = Self.frameIndex(of: owner)
        if let injectedFlow {
            speak(through: injectedFlow)
        } else {
            switch owner.clock {
            case .frameIndex(let frameRate):
                pace = .frames(perSecond: max(1, frameRate), origin: frame)
            case .wallClock:
                speak(through: .speakers)
            }
        }
    }

    func supply() {
        if let owner { frame = Self.frameIndex(of: owner) }
        switch pace {
        case .frames(let frameRate, let origin):
            // 整数のフレーム数から掛けて割る。秒を足し込まないので、何フレーム目でも丸めがずれない
            advance(
                to: Int(
                    (Double(frame - origin) * rack.sampleRate / Double(frameRate)).rounded(.down)))
        case .realTime(let origin, let base):
            advance(to: base + Int(((now() - origin) * rack.sampleRate).rounded(.down)))
        case .speaker(let player):
            resumeIfStopped(player)
        case nil:
            break
        }
        sounds.removeAll { $0.sound == nil }
        for entry in sounds { entry.sound?.refresh() }
    }

    func close() {
        isClosed = true
        if case .speaker(let player) = pace { player.leave() }
        pace = nil
        for entry in sounds { entry.sound?.silence() }
        sounds.removeAll()
        Self.stages = Self.stages.filter { $0.value.stage != nil && $0.value.stage !== self }
    }

    // MARK: - 時計

    /// `sketch` のいまのフレームが、時計の上で何フレーム目に並ぶか (``SoundFile`` と同じ数え方)。
    private static func frameIndex(of sketch: any Sketch) -> Int {
        max(0, sketch.frameCount - 1)
    }

    /// 実際に鳴らす。出力が開けなければ、鳴らさずに実時間で進める。
    private func speak(through flow: SoundFlow) {
        if let player = RackPlayer(flow: flow, rack: rack) {
            pace = .speaker(player)
            return
        }
        pace = .realTime(origin: now(), base: rack.rendered)
        notice(
            .noOutput,
            "No audio output could be opened, so synthesized sounds are not heard. Their analysis "
                + "keeps working")
    }

    /// ラックの標本を `total` まで進める (鳴らさない)。
    ///
    /// 実時間で進めるとき、止まっていた間 (デバッガなど) のぶんは長くても 2 秒で打ち切る。
    private func advance(to total: Int) {
        let missing = min(total - rack.rendered, Int(rack.sampleRate) * 2)
        guard missing > 0 else { return }
        rack.advance(frames: missing)
    }

    /// 出力の機材が替わると、流れは自分で止まる。始め直せなければ、鳴らさずに実時間で進める。
    private func resumeIfStopped(_ player: RackPlayer) {
        guard !player.flow.isRunning, !player.flow.start() else { return }
        player.leave()
        pace = .realTime(origin: now(), base: rack.rendered)
        notice(
            .noOutput,
            "The audio output stopped and could not be restarted, so synthesized sounds are no "
                + "longer heard. Their analysis keeps working")
    }

    private func notice(_ kind: Notice, _ message: String) {
        guard noticed.insert(kind).inserted else { return }
        warn(message)
    }
}
