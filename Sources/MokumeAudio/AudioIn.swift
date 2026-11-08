// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeCore
import MokumeDiagnostics

/// 音を受け取って解析する入力。``Sketch/createAudioIn(device:)`` が作り、実行中のスケッチへ追加する。
///
/// 毎フレーム呼ぶメソッドは無い。`draw()` の前に、そのフレームの音を解析した値が入っている
/// ([ADR-0024] 決定 6)。
///
/// ```swift
/// final class Pulse: Sketch {
///     var mic: AudioIn?
///     func setup() { mic = createAudioIn() }
///     func draw() {
///         background(0)
///         guard let mic else { return }
///         circle(width / 2, height / 2, 40 + mic.level * 300)
///     }
/// }
/// ```
///
/// ## 生の値と 0〜1 の値
///
/// | 生の値 | 0〜1 へ変換した値 |
/// | --- | --- |
/// | ``rms`` (振幅) と ``decibels`` (dBFS) | ``level`` |
/// | ``spectrum`` (帯域ごとの振幅) | ``spectrumLevels`` |
///
/// 0〜1 の値は、-60 dBFS を 0、0 dBFS を 1 として dB で線形に変換し、範囲の外はクランプする。履歴に
/// 依らないので、同じ音はいつも同じ値になる。生の値をそのまま 0〜1 として使うと、普通の
/// 音量では小さい値に偏る (フルスケールの正弦波でも ``rms`` は約 0.707 にしかならない)。
/// 区間の最大振幅 ``peak`` は生の値だけを持ち、0〜1 へ変換した値は用意しない (フルスケールで 1 になる)。
///
/// ## 解析するのは、前のフレーム以後の全サンプル
///
/// 各フレームでは、**前のフレームの区間の終わりからこのフレームの区間の終わりまでの全サンプル**を解析する
/// (24 fps なら 2000 サンプル。ウィンドウを 1 つしか見ないと、アタックの鋭い音を見落とす)。マイクのサンプルは、入力ソース
/// が届けた単位 (チャンクの長さ) ではなく、最初に受け取ったサンプルを 0 とした通し番号で数える。
///
/// - ``rms``・``decibels``・``level``・``peak`` は区間全体の値
/// - ``spectrum`` は、サンプル 0 から 512 サンプルごとに置いた 1024 サンプルのウィンドウ (Hann 窓を掛ける。48 kHz で約 21 ミリ秒)
///   のうち、終わりが区間に入るものの平均。``spectrumLevels`` はその平均を変換したもの。区間が 512 サンプルより短い
///   (48 kHz で 93.75 fps より速い) ときは、区間の終わりまでに終わった最後のウィンドウを使う
/// - 帯域は 512 本で、帯域 `k` の中心は `k × sampleRate ÷ 1024` Hz である
/// - 新しいサンプルが届かなかったフレームは、値が前のまま (``isNewFrame`` が false)
/// - 長く止まった後は、区間の終わりから 6144 サンプル (48 kHz で約 0.128 秒) までを解析する
/// - **高い fps では区間が短い。** 120 fps なら 1 フレームは 400 サンプルで、低い音 (55 Hz の 1 周期は約 870 サンプル) の
///   ``rms``・``level`` は、区間の中の位相で揺れる。``spectrum`` はウィンドウの平均なので区間の長さに依らず滑らか
///
/// ## 音が届かないときは理由が分かる
///
/// 音が届かないとき、``state`` がその理由を返す — 許可を待っている・拒否された・デバイスが
/// 無い・切断された。動作していない間の値は無音 (``level`` が 0) になる。`observe` の応答の `inputs` にも
/// 同じ状態が載る ([ADR-0028] 決定 4)。許可を待ったまま 3 秒経っても何も届かないときと、
/// 許可を拒否されたときは、どのアプリの許可を確認すればよいかを 1 度だけ警告する。
///
/// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
public final class AudioIn: Inlet {
    /// 選んだデバイス。既定の入力を使っている・ファイルやサンプル列を入力にしているなら `nil`。
    public let device: AudioDevice?
    /// このフレームで新しい音が解析されたか。
    public private(set) var isNewFrame = false

    let input: ExternalInput<AudioSpan>
    private let source: any AudioSource
    private weak var owner: (any Sketch)?
    /// 利用者が ``stop()`` を呼んだ。**足し直しの ``open()`` でも戻さない** (利用者の意思として粘る)。
    private var stoppedByUser = false
    private let now: () -> TimeInterval
    private let warn: (String) -> Void
    /// 通常の枚の続きの最新の値。時刻を指定した観測の枚は、これを動かさない。
    private var levels = AudioLevels.silence
    /// いま見せる値。観測の枚だけ、指定の秒で終わる区間の値で、それ以外は ``levels``。
    private var shown = AudioLevels.silence
    /// 波形と拍 (``SoundTrace``)。``SoundFile``・``SynthSound`` と同じ型を通す。
    private var trace = SoundTrace()
    private var warnedEnergy = false
    private var openedAt: TimeInterval?
    private var warnedWaiting = false
    private var warnedDenied = false

    /// 許可を待ったまま、何秒何も来なければ知らせるか。
    static let patience: TimeInterval = 3

    init(
        device: AudioDevice?, name: String, source: any AudioSource, owner: (any Sketch)?,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        warn: @escaping (String) -> Void = Diagnostics.warn
    ) {
        self.device = device
        self.source = source
        self.owner = owner
        self.now = now
        self.warn = warn
        input = ExternalInput(name: name, state: .waitingForPermission)
    }

    // MARK: - 生の値

    /// 区間の二乗平均平方根 (振幅の単位)。無音で 0、フルスケールの正弦波で約 0.707。
    public var rms: Double { Double(shown.rms) }
    /// ``rms`` を dBFS にしたもの。0 が最大で、無音は -160 (∞ にはしない)。
    public var decibels: Double { Double(shown.decibels) }
    /// 区間のサンプルの絶対値の最大 (振幅の単位)。無音で 0、フルスケールの音で 1。
    ///
    /// アタックの鋭い音 (キックなど) を、区間のどこにあっても拾う。``rms`` は区間の長さで薄まるが、これは薄まらない。
    /// マイク・サンプル列は毎フレーム解析するので、取りこぼしはない。
    public var peak: Double { Double(shown.peak) }
    /// 帯域ごとの大きさ (振幅の単位)。512 本で、帯域の中心にあるフルスケールの正弦波で 1。区間に終わりが入る
    /// ウィンドウの平均。
    public var spectrum: [Float] { shown.spectrum }

    // MARK: - 0〜1 へ写した値

    /// 音の大きさを 0〜1 にしたもの。-60 dBFS 以下で 0、0 dBFS で 1。
    public var level: Double { Double(shown.level) }
    /// ``spectrum`` を帯域ごとに 0〜1 にしたもの。変換の仕方は ``level`` と同じ。
    public var spectrumLevels: [Float] { shown.spectrumLevels }

    // MARK: - 帯域・波形・拍

    /// 周波数の範囲 `low`〜`high` (Hz) の大きさを 0〜1 で返す。低音の脈動を、帯域の番号を計算せずに取得できる。
    ///
    /// <!-- example: 文脈 var mic: AudioIn? -->
    /// ```swift
    /// if let mic { circle(width / 2, height / 2, 100 + mic.energy(from: 20, to: 140) * 300) }
    /// ```
    ///
    /// 区間の ``spectrum`` のうち、中心がその範囲に入る帯域 (帯域 `k` の中心は `k × sampleRate ÷ 1024` Hz) の振幅の
    /// 平均を、``level`` と同じ dB の固定範囲 (-60 dBFS が 0、0 dBFS が 1) で変換した値で、履歴に依らない。別の
    /// 解析は実行しない。p5.sound の `getEnergy` に当たる。
    ///
    /// - 範囲に中心が入る帯域が無ければ、範囲の中点に最も近い 1 帯域の値
    /// - 逆順 (`low` が `high` より大きい) は入れ替える。0 Hz〜サンプルレートの半分からはみ出す分は端にクランプし、
    ///   範囲がすべて外なら 0
    /// - NaN・無限大は 0 を返し、そのことを 1 度だけ警告する (投げない — [ADR-0020] 決定 5)
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func energy(from low: Double, to high: Double) -> Double {
        Double(energyValue(from: Float(low), to: Float(high)))
    }

    func energyValue(from low: Float, to high: Float) -> Float {
        let result = AudioAnalysis.energy(of: shown.spectrum, from: low, to: high, sampleRate: Float(sampleRate))
        if !result.isNumber, !warnedEnergy {
            warnedEnergy = true
            warn("energy() got a value that is not a number, or an infinite one, so it returns 0")
        }
        return result.value
    }

    /// 区間の終わりの 1024 サンプル (古い順)。波形を描くのに使う。
    ///
    /// <!-- example: 文脈 var mic: AudioIn? -->
    /// ```swift
    /// if let mic {
    ///     noFill()
    ///     stroke(255)
    ///     beginShape()
    ///     for (i, s) in mic.waveform.enumerated() { vertex(Float(i) / 1024 * width, height * 0.8 + s * 100) }
    ///     endShape()
    /// }
    /// ```
    ///
    /// サンプルは解析と同じもの (チャンネルを平均したもの。音量を掛けた後)。サンプル 0 より前は 0。サンプルが進まな
    /// かったフレームは前のまま。何も再生されていなければ 1024 個の 0。p5.sound の `waveform()` と
    /// Processing Sound の `Waveform` に当たる。
    public var waveform: [Float] { trace.waveform() }

    /// このフレームの区間にビートがあったか。区間にビートが 1 つ以上あれば `true` (複数あっても 1 回にまとめる)。
    ///
    /// <!-- example: 文脈 var mic: AudioIn?; var flash: Float = 0 -->
    /// ```swift
    /// if mic?.isBeat == true { flash = 1 }
    /// flash *= 0.9
    /// background(30 + flash * 200, 30, 40)
    /// ```
    ///
    /// ビートは、ブロックごとのエネルギーが直近の平均を急に上回ったところ。ブロックは音源のサンプル 0 から 512 サンプルごと
    /// に区切った固定の並びで、**判定は届いた単位ではなくこの並びの順にだけ進む**。同じサンプル列からは、fps や
    /// 届くチャンクの長さが違っても同じサンプル位置でビートが出る (``AudioIn`` のマイクを除く — 到着が実時間で決まる
    /// ので、固定クロックの書き出しで水準 2 を満たせるのはファイル・サンプル列・合成音)。Minim の `BeatDetect`、
    /// p5.sound の `PeakDetect`、Processing Sound の `BeatDetector` に当たる。感度を設定する API は持たない。
    ///
    /// **音が届き始めたときから**履歴を蓄積し、読まないフレームの区間も届くたびに処理する。どのフレームから読み始めても
    /// ビートの有無は変わらず、読む間隔を変えてもビートの位置は同じ (コストはサンプルあたり二乗和 1 回で、1 フレームに数 µs)。
    /// ストリームの最初から始まる音は、最初のアタックもビートになる (途中から始まるときは約 85 ミリ秒はビートが出ない)。
    /// サンプルを取りこぼしたとき (区間の上限を越えたとき) は、履歴を捨ててやり直し、取りこぼした区間ではビートを出さない。
    /// 区間の上限があるので、約 7.8 fps (48 kHz) より遅いフレームでは区間の先頭が切り捨てられ続け、ビートは fps に依存する。
    ///
    /// 時刻を指定した `observe` のフレームは、指定の秒で終わる 1 フレームぶんの区間にビートがあったかを返す (通常の進行は変えない)。
    /// スケッチの時刻より先の区間のビートは、まだ処理していないので分からず `false`。
    public var isBeat: Bool { trace.isBeat }

    /// 拍の状態が区間を処理した回数。検査が読む — 区間を置くたびに 1 回ずつ増える。
    var beatSteps: Int { trace.beatSteps }

    // MARK: - 出どころ

    /// サンプルレート (Hz)。マイクはデバイスが開くまで 0。
    public var sampleRate: Double { Double(source.sampleRate) }
    /// 入力ソースの状態。
    public var state: SourceState { input.state }
    /// 最後に音が届いたフレーム。まだ何も届いていなければ `nil`。
    public var lastArrival: Arrival? { input.lastArrival }

    /// 停止する。デバイスを閉じ、以後の値は無音になる。
    ///
    /// **利用者が停止したものは、追加し直しても停止したままである。** ``SketchPart/attach(_:)-(Inlet)`` で追加し直しても、
    /// デバイスを開かず値は無音のままで、``state`` は ``SourceState/stopped`` のまま (停止は利用者の意思なので、
    /// 追加し直しても戻さない)。受け取りを再開するには、新しく作る。
    ///
    /// **ランタイムが外した場合は別である。** ``SketchPart/detach(_:)-(Inlet)`` で外しただけ (``stop()`` は呼んで
    /// いない) なら、``SketchPart/attach(_:)-(Inlet)`` で追加し直せば、デバイスを開き直して再び受け取る。実行が終了した
    /// スケッチには追加し直せない。
    ///
    /// `setup()`・`draw()`・入力のコールバックの中から呼ぶ (``SketchPart/detach(_:)-(Inlet)`` と同じ)。
    /// 実行中のスケッチの中で生成した `Task` からも停止できる。それ以外 (初期化子の中・終了処理の後) で呼ぶと何もせず、`AudioIn.stop()` のように型名を付けた名前で 1 度だけ警告する。
    public func stop() {
        // 印は、外す頼みが実行に届いたときだけ立てる。外で呼んで警告だけ出した回に立てると、走っている機材が止まる
        if owner?.detach(self, calledAs: "AudioIn.stop()") == true { stoppedByUser = true }
    }

    // MARK: - Inlet

    public func open() throws {
        // 足し直しでも呼ばれる (``close()`` の後の 2 度目)。利用者が ``stop()`` したものは開き直さない
        guard !stoppedByUser else { return }
        openedAt = now()
        // **起点は作者の時計の秒** — 時刻を指定した観測の枚の `draw()` で作ったものが、観測の秒を起点として
        // 残さない (#2357)。読む位置 (``supply()``) は見せる時刻で決める
        source.start(into: input, at: clock())
    }

    public func supply() {
        trace.beginFrame()
        source.pump(into: input, at: clock())
        if let span = input.take() {
            // 通常の続きは、観測の枚でも通常の枚と同じに解く。観測の枚で標本が進んでいない (空の区間) ときは前の値のまま
            if !span.isEmpty || span.observation == nil { levels = AudioAnalyzer.shared.analyze(span) }
            // 時刻を指定した観測の枚だけは、指定の秒で終わる区間を別に解いて見せる (通常の続きは動かさない)
            shown = span.observation.map { AudioAnalyzer.shared.analyze($0.span) } ?? levels
            // 波形と拍は、読まれるかどうかに依らず、区間が届くたびに進める。観測の枚は、指定の秒で終わる区間を別に見せる
            trace.hold(span)
            trace.show(span.observation)
            isNewFrame = true
        } else {
            shown = levels
            isNewFrame = false
        }
        if state != .running { forgetSound() }
        noticeIfStuck()
    }

    /// 出どころに渡す、いまの時計の位置。**秒は作者の時計の倍精度の秒**で、止める・飛ぶに従い、観測の秒を状態に積まない。
    /// 固定の時計は、秒に fps を掛けたフレームの位置から区間を整数で数える (``SourceClock``)。時刻を指定した観測の枚は、
    /// 通常の枚と同じ区間を数えたうえで、指定の秒を ``SourceClock/observed`` で渡す。
    private func clock() -> SourceClock {
        guard let owner else { return SourceClock(seconds: 0) }
        return SourceClock(
            seconds: owner.authorSeconds,
            perSecond: owner.clock.soundFrameRate(onScreen: owner.isOnScreen),
            observed: owner.observedSeconds)
    }

    public func close() {
        source.stop()
        input.setState(.stopped)
        // 届いて読まれなかった音は捨てる。足し直した最初の ``supply()`` に、外す前の音を出さない
        input.discardWaiting()
        forgetSound()
    }

    /// 値・波形・拍の履歴を捨てて、無音にする。
    private func forgetSound() {
        levels = .silence
        shown = .silence
        trace.forget()
    }

    public var report: SourceReport? { input.report }

    // MARK: - 知らせ

    /// 許可で止まっているなら、どこを見ればよいかを 1 度だけ言う。
    private func noticeIfStuck() {
        switch state {
        case .waitingForPermission:
            guard !warnedWaiting, lastArrival == nil, let openedAt,
                now() - openedAt >= Self.patience
            else { return }
            warnedWaiting = true
            warn(
                "The microphone has been waiting for permission for \(Int(Self.patience)) seconds "
                    + "and no sound has arrived. macOS asks on behalf of \(Self.responsibleApp()): "
                    + "answer the dialog, or allow it in System Settings > Privacy & Security > "
                    + "Microphone")
        case .denied:
            guard !warnedDenied else { return }
            warnedDenied = true
            warn(
                "Microphone access is denied for \(Self.responsibleApp()), so no sound will arrive. "
                    + "Allow it in System Settings > Privacy & Security > Microphone, then start "
                    + "the sketch again")
        default:
            break
        }
    }

    /// 許可を問われるアプリ。束ねた `.app` ならそれ自身、端末から動かしたなら端末のアプリ
    /// (許可は「責任を負うプロセス」に付く — #1957 の実測)。
    static func responsibleApp(
        bundle: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let bundle { return bundle }
        if let launcher = environment["__CFBundleIdentifier"] { return launcher }
        if let terminal = environment["TERM_PROGRAM"] { return terminal }
        return "the app that started this sketch"
    }
}
