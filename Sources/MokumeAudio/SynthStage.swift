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
    /// ファイルの節へ頼まれて、まだ列へ載せていない操作 (``sendToFile(_:frame:)``)。頼まれた順。
    private var heldForFiles: [(frame: Int, command: SynthCommand)] = []
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

    /// ファイルの節 (``FileNode``) へ頼む操作。**ラックを実際に鳴らしているなら、すぐ列へ載せる。**
    /// フレームの数え方 (書き出し・検査) と実時間では、頼んだフレームの次のフレームの頭 (``supply()``) まで
    /// 預かり、ラックを進める前に載せる。
    ///
    /// 預かるのは、ラックを進めるのがこのステージの ``supply()`` で、ファイルの側の ``SoundFile/supply()``
    /// と前後どちらが先に呼ばれるかに依らず、頼んだ操作が同じフレームの区切りで効くようにするため。
    /// ファイルの位置は、`play()` を呼んだフレームの次のフレームで 1 フレームぶん進んだ数になる。ラックも
    /// その次のフレームの `advance` で、同じ 1 フレームぶんを作る。
    ///
    /// - Parameters:
    ///   - command: 節への操作。
    ///   - frame: 頼んだフレーム (``SoundFile`` の数え方。`draw()` の中でも `supply()` の中でも同じ)。
    func sendToFile(_ command: SynthCommand, frame: Int) {
        guard !isClosed else { return }
        if case .speaker = pace {
            rack.post(command)
        } else {
            heldForFiles.append((frame: frame, command: command))
        }
    }

    /// 預かっていた操作のうち、`frame` より前のフレームで頼まれたものを列へ載せる。
    private func releaseHeldFileCommands() {
        var released = 0
        let everything: Bool
        if case .speaker = pace { everything = true } else { everything = false }
        while released < heldForFiles.count, everything || heldForFiles[released].frame < frame {
            rack.post(heldForFiles[released].command)
            released += 1
        }
        heldForFiles.removeFirst(released)
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
                + "\(SynthRack.capacity) oscillators, noises and effects alive together. "
                + "An oscillator or noise you no longer hold stops counting once it has finished "
                + "sounding; effects stay until the sketch ends. Create them once in setup() "
                + "and reuse them instead of creating new ones in draw()")
    }

    // MARK: - Inlet

    func open() throws {
        guard let owner else { return }
        frame = Self.frameIndex(of: owner)
        if let injectedFlow {
            speak(through: injectedFlow)
        } else if let frameRate = owner.clock.soundFrameRate(onScreen: owner.isOnScreen) {
            // 書き出しの経路。鳴らさずに、フレームの数から位置を決める
            pace = .frames(perSecond: max(1, frameRate), origin: frame)
        } else {
            // 画面へ出している経路は、時計によらず鳴らす (フレームの時計の窓も・#2601)
            speak(through: .speakers)
        }
    }

    func supply() {
        if let owner { frame = Self.frameIndex(of: owner) }
        releaseHeldFileCommands()
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
        reapReleasedSources()
        for entry in sounds { entry.sound?.refresh() }
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
        heldForFiles.removeAll()
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
