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
/// 開くときに ``SketchPart/clock`` を読み、``SoundFile`` と同じ区別をする。
///
/// - **実時間** (窓に出しながら動かす) では、ラックを音の流れ (``RackPlayer``) へ入れて実際に鳴らす。
///   標本は音の側のスレッドが作る
/// - **フレームの数え方** (書き出し・検査) では、ふだんは**鳴らさず**、ラックの標本を「絶対のフレーム番号 ×
///   標本化率 ÷ fps」の位置まで進める。区間がフレームの番号だけで決まるので、同じ設定から何度書き出しても
///   同じ値になる ([ADR-0028] 決定 7・[ADR-0025] の水準 2)。**`.mov` を録り始めて音声トラックが付くと**
///   (``SoundTrackMixer``・[#3125])、ラックを機材に出さない音の流れ (``RackPlayer``) へ入れ、窓ごとに描いて動画へ
///   載せる。位置は今の位置から続くので、解析の値は途切れない
/// - 出力が開けないときは、鳴らさずに実時間で進め、そのことを 1 度だけ知らせる
///
/// [#3125]: https://github.com/mokume-metal/mokume/issues/3125
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
final class SynthStage: Inlet, RealtimeSound {
    /// 標本化率 (Hz)。実機の出力と違えば、混ぜる節が変換する。
    static let sampleRate = 48_000.0

    /// スケッチごとのステージ。**弱く持つ** — ステージを持つのは走っているスケッチ (入り口の並び)
    /// で、ここではない。スケッチが終わっても閉じられなかったとき (検査が閉じずに捨てるとき) に、
    /// 手放された後の同じ番地の別のスケッチが、前のステージを引き継がないようにするため、
    /// 持ち主も照らし合わせる。
    ///
    /// **`private` にしないのは検査のため** ([#2711])。番地の引き継ぎは割り当て器しだいで、待っても
    /// 起きない機械がある。検査は、別のスケッチのステージを同じ鍵の下へ置いて、引き継いだ状態を
    /// 直接作る。ここを書き換えてよいのはこの型と検査だけである。
    ///
    /// [#2711]: https://github.com/mokume-metal/mokume/issues/2711
    static var stages: [ObjectIdentifier: Weak] = [:]

    struct Weak {
        weak var stage: SynthStage?
    }

    let rack: SynthRack
    private weak var owner: (any Sketch)?
    private let injectedFlow: SoundFlow?
    private let now: () -> TimeInterval
    private let warn: (String) -> Void
    /// **検査が差し込む** (``init(owner:flow:now:warn:)``)。持ち主のいないステージは、検査が時計を決める。
    var pace: Pace?
    /// 持ち主が数えているフレーム。持ち主がいるときは `supply()` が読み直す。
    var frame = 0
    /// 解析を更新する音。**弱く持つ** — 使う側が手放した音の解析は要らない。手放した音源の節は、
    /// 鳴り終えるまでラックに残り、鳴り終えてから置き場が戻る (``SynthRack`` の「置き場は、手放して
    /// 鳴り終えた音源のぶんだけ戻る」)。
    private var sounds: [WeakSound] = []
    private var noticed: Set<Notice> = []
    /// 実時間で、ラックを進めたフレーム (``advanceClock()``)。
    private var clockAdvancedFrame: Int?
    /// 閉じた (スケッチが終わった)。以後の操作は捨てる。
    private(set) var isClosed = false

    private struct WeakSound {
        weak var sound: SynthSound?
        /// 音源なら、その節の置き場の番号。手放されたとき、ラックへ伝える (エフェクトは返さない)。
        let source: Int?
    }

    /// ラックの標本を進める時計。
    enum Pace {
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
        case cannotCarry
        case reservationFull
    }

    /// - Parameter owner: 持ち主のスケッチ。**検査だけが `nil` で作る** (スケッチを走らせずに、`pace` と
    ///   `frame` を自分で決めて回す — GPU が要らない)。
    init(
        owner: (any Sketch)?, flow: SoundFlow?, now: @escaping () -> TimeInterval,
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
    /// 足せない所 (`setup()`・`draw()`・入力のコールバックの外) なら、`call` の名前で 1 度だけ警告し、
    /// 足されていない (鳴らない) ステージを返す ([#2740])。
    ///
    /// - Parameters:
    ///   - flow: 鳴らす流れを差し替える (検査)。最初に作るときだけ効く。
    ///   - call: 警告に載せる作る口の名前。呼ぶ側の `#function` が入る (`"createSinOsc()"` など)。
    ///
    /// [#2740]: https://github.com/mokume-metal/mokume/issues/2740
    static func stage(
        for sketch: any Sketch, flow: SoundFlow? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        warn: @escaping (String) -> Void = Diagnostics.warn, calledAs call: String = #function
    ) -> SynthStage {
        let key = ObjectIdentifier(sketch)
        if let existing = stages[key]?.stage, !existing.isClosed, existing.owner === sketch {
            return existing
        }
        stages = stages.filter { $0.value.stage != nil }
        let stage = SynthStage(owner: sketch, flow: flow, now: now, warn: warn)
        stages[key] = Weak(stage: stage)
        // 足せない所なら、作る口の名前で 1 度だけ警告する (`attach()` を名乗らない)。次に呼ばれたとき作り直す
        if !sketch.attach(stage, calledAs: call, returning: "a sound that is never heard") {
            stages[key] = nil
        }
        return stage
    }

    /// ファイルの節が位置を決めるとき、ファイルの側が**ラックをこのフレームまで進めてから**位置を
    /// 読めるように、先にステージの時計を進める。
    ///
    /// ステージと ``SoundFile`` のどちらが先に ``supply()`` を受けるかは、作った順で決まる。ステージの
    /// 進みが後だと、ファイルは 1 フレーム前のラックから位置を読んでしまう。控えていた操作
    /// (``SynthRack/retryHeld()``) も、ここで載せ直す。ここで進めれば、後から来る
    /// ステージ自身の ``supply()`` の進みは同じ目的地になり、足されない (固定の時計では 0 標本、実時間では
    /// 数マイクロ秒ぶん)。実機の流れ (``Pace/speaker``) は音の側が進めているので、何もしない。
    func catchUpForFiles() {
        guard !isClosed else { return }
        if let owner { frame = Self.frameIndex(of: owner) }
        rack.retryHeld()
        advanceClock()
        // 進めて列が空いたぶんを、すぐ載せ直す (このフレームの後の描き出しで音の側へ届く)
        rack.retryHeld()
    }

    /// `sketch` のステージ。**作らない** — まだ無い (合成した音を 1 つも作っていない) か、閉じていれば `nil`。
    static func existing(for sketch: any Sketch) -> SynthStage? {
        guard let stage = stages[ObjectIdentifier(sketch)]?.stage, !stage.isClosed,
            stage.owner === sketch
        else { return nil }
        return stage
    }

    /// 音の時計 (秒)。ラックが作った標本の数を標本化率で割ったもの。**フレームの数え方 (書き出し・検査) では
    /// フレームの番号から決まり、実機では音の側が実際に作った標本から読む** (``SynthRack/rendered``)。
    /// ``SketchPart/time`` ではなく、``SketchPart/pauseTime()``・``SketchPart/jumpTime(_:)`` に動かされない。
    var soundSeconds: Double {
        Double(rack.rendered) / rack.sampleRate
    }

    /// 予約の秒 `seconds` (音の時計) を、ラックの標本の位置にする。数でない値・無限の値は `nil`。
    /// 負の値と今より前の値は、そのまま過去の位置になり、次に作る標本の頭で適用される。
    func samplePosition(ofSeconds seconds: Double) -> Int? {
        guard seconds.isFinite else { return nil }
        // 大きな値は丸めて、整数に収まらないまま掛け算で溢れないようにする
        let position = (seconds * rack.sampleRate).rounded()
        return Int(min(max(position, 0), 1e15))
    }

    /// このステージが、`sketch` のものか。
    func isOwned(by sketch: any Sketch) -> Bool {
        owner === sketch
    }

    /// 音を数に入れる。フレームごとに解析の値を更新する。
    func register(_ sound: SynthSound) {
        let source = sound.node.flatMap { $0.isSource ? $0.id : nil }
        sounds.append(WeakSound(sound: sound, source: source))
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
                + "\(SynthRack.capacity) oscillators, noises, effects and sound files passed to "
                + "effects alive together. An oscillator or noise you no longer hold stops counting "
                + "once it has finished sounding; a sound file stops counting once it is detached; "
                + "effects stay until the sketch ends. Create them once in setup() "
                + "and reuse them instead of creating new ones in draw()")
    }

    /// 予約が置き場に入らず捨てられたことを 1 度だけ知らせる。
    private func noticeReservationFull() {
        notice(
            .reservationFull,
            "Too many sounds are reserved ahead with at: (a sketch keeps at most "
                + "\(SynthRack.reservationCapacity) reserved operations waiting; one Env.play(…, at:) uses 6, "
                + "play(…, at:) with values up to 5), so some reservations were dropped. Reserve only the "
                + "next few notes ahead of soundTime instead of the whole song at once, and check that at: "
                + "is in seconds of soundTime: a time far in the future (a typo, or milliseconds given as "
                + "seconds) keeps its reservation waiting and fills the store")
    }

    // MARK: - Inlet

    func open() throws {
        guard let owner else { return }
        frame = Self.frameIndex(of: owner)
        // **音を出す入り口が居ることを、録りが載せるかどうかに依らず混ぜ役に名乗らせる** (載せない録りが、音源が
        // 居ることを 1 度だけ名乗れる・[#3125])
        let mixer = SoundTrackMixer.mixer(for: owner)
        if let injectedFlow {
            speak(through: injectedFlow)
        } else if let frameRate = owner.clock.soundFrameRate(onScreen: owner.isOnScreen) {
            // 書き出しの経路。鳴らさずに、フレームの数から位置を決める
            pace = .frames(perSecond: max(1, frameRate), origin: frame)
            // 音声トラックを載せる録りのために、混ぜ役へ名乗る。音声トラックが始まっていれば、最初からその流れで鳴る
            mixer?.register(stage: self)
            if let flow = mixer?.flow { joinTrack(flow) }
        } else {
            // 画面へ出している経路は、時計によらず鳴らす (フレームの時計の窓も・#2601)
            speak(through: .speakers)
        }
    }

    /// 音声トラックが始まった ([#3125])。鳴らさずに数で進めていたラックを、機材に出さない流れへ入れる。
    ///
    /// ラックが作った標本の数 (``SynthRack/rendered``) はそのまま続くので、位置も解析の値も途切れない。操作の列に
    /// 溜まっている頼みは、流れが描く最初の窓の先頭から効く。
    ///
    /// **入れられなくても、位置は数で進め続ける** (``Pace/frames``)。鳴らさずに実時間へ落とすと、その録りの間だけ
    /// 解析の位置が壁時計で進み、同じ設定から同じ値にならない。音が動画に入らないことを、事情どおりに 1 度だけ
    /// 知らせる。
    ///
    /// [#3125]: https://github.com/mokume-metal/mokume/issues/3125
    func joinTrack(_ flow: SoundFlow) {
        guard !isClosed, case .frames = pace else { return }
        guard let player = RackPlayer(flow: flow, rack: rack) else {
            notice(
                .cannotCarry,
                "The synthesized sounds could not be put in the recording: the audio flow of the recording "
                    + "could not take them, so they are not in the movie. Their position still follows the "
                    + "frames, and their analysis keeps working")
            return
        }
        pace = .speaker(player)
    }

    func supply() {
        if let owner { frame = Self.frameIndex(of: owner) }
        rack.retryHeld()
        advanceClock()
        rack.retryHeld()
        if case .speaker(let player) = pace { resumeIfStopped(player) }
        reapReleasedSources()
        if rack.droppedReservations > 0 { noticeReservationFull() }
        for entry in sounds { entry.sound?.refresh() }
    }

    /// 固定の時計と実時間で、ラックの標本を今のフレームの目的地まで進める。実機の流れでは何もしない。
    private func advanceClock() {
        switch pace {
        case .frames(let frameRate, let origin):
            // 絶対のフレーム番号から掛けて割った位置の差。秒を足し込まないので、何フレーム目でも丸めがずれず、
            // 窓の継ぎ目 (``FrameSamples``) とも揃う
            advance(
                to: FrameSamples.count(
                    from: origin, to: frame, perSecond: frameRate, sampleRate: rack.sampleRate))
        case .realTime(let origin, let base):
            // **1 フレームに 1 回だけ。** ファイルの側からも呼ばれる (``catchUpForFiles()``) ので、数えないと
            // 1 回の進みを 2 秒で打ち切る約束 (``advance(to:)``) が、1 フレームに 2 回ぶんになる
            guard clockAdvancedFrame != frame else { break }
            clockAdvancedFrame = frame
            advance(to: base + Int(((now() - origin) * rack.sampleRate).rounded(.down)))
        case .speaker, nil:
            break
        }
    }

    /// 手放された音をやめる。音源なら、ラックへ手放したことを伝える (鳴り終えたら置き場が戻る)。
    ///
    /// ラックが返した置き場は、先に受け取る。伝えられなければ (操作の列が満杯) 次のフレームへ持ち越す。
    private func reapReleasedSources() {
        rack.collectFreed()
        sounds.removeAll { entry in
            guard entry.sound == nil else { return false }
            guard let source = entry.source else { return true }
            return rack.release(source)
        }
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
