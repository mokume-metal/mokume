// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeCore
import MokumeDiagnostics

/// 音を受けて解析する入り口。``Sketch/createAudioIn(device:)`` が作り、走っているスケッチへ足す。
///
/// 毎フレーム呼ぶ口は無い。`draw()` の前に、そのフレームの音を解析した値が入っている
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
/// | 生の値 | 0〜1 へ写した値 |
/// | --- | --- |
/// | ``rms`` (振幅) と ``decibels`` (dBFS) | ``level`` |
/// | ``spectrum`` (帯域ごとの振幅) | ``spectrumLevels`` |
///
/// 0〜1 の値は、-60 dBFS を 0、0 dBFS を 1 として dB で線形に写し、外は丸める。履歴に
/// 依らないので、同じ音はいつも同じ値になる。生の値をそのまま 0〜1 として使うと、普通の
/// 音量では小さいところに張り付く (全振幅の正弦波でも ``rms`` は約 0.707 にしかならない)。
/// 区間の最大の振幅 ``peak`` は生の値だけを持ち、0〜1 へ写した値は足さない (全振幅で 1 になる)。
///
/// ## 解析するのは、前のフレーム以後の全標本
///
/// 各フレームでは、**前のフレームの区間の終わりからこのフレームの区間の終わりまでの全標本**を解析する
/// (24 fps なら 2000 標本。窓 1 つしか見ないと、立ち上がりの鋭い音を見落とす)。マイクの標本は、出どころ
/// が届けた単位 (チャンクの長さ) ではなく、最初に受け取った標本を 0 とした通し番号で数える。
///
/// - ``rms``・``decibels``・``level``・``peak`` は区間全体の値
/// - ``spectrum`` は、標本 0 から 512 標本ごとに置いた 1024 標本の窓 (Hann の窓を掛ける。48 kHz で約 21 ミリ秒)
///   のうち、終わりが区間に入るものの平均。``spectrumLevels`` はその平均を写したもの。区間が 512 標本より短い
///   (48 kHz で 93.75 fps より速い) ときは、区間の終わりまでに終わった最後の窓を使う
/// - 帯域は 512 本で、帯域 `k` の真ん中は `k × sampleRate ÷ 1024` Hz である
/// - 新しい標本が届かなかったフレームは、値が前のまま (``isNewFrame`` が false)
/// - 長く止まった後は、区間の終わりから 6144 標本 (48 kHz で約 0.128 秒) までを解析する
///
/// ## 来ないことには理由がある
///
/// 音が来ないとき、``state`` がその理由を名乗る — 許可を待っている・拒まれた・機材が
/// 無い・抜かれた。動いていない間の値は無音 (``level`` が 0) になる。観測の応答の `inputs` にも
/// 同じものが載る ([ADR-0028] 決定 4)。許可を待ったまま 3 秒経っても何も来ないときと、
/// 許可を拒まれたときは、どのアプリの許可を見ればよいかを 1 度だけ知らせる。
///
/// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
public final class AudioIn: Inlet {
    /// 選んだ機材。既定の入力を使っている・ファイルや標本列を流しているなら `nil`。
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
    private var levels = AudioLevels.silence
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

    /// 区間の二乗平均の平方根 (振幅の単位)。無音で 0、全振幅の正弦波で約 0.707。
    public var rms: Float { levels.rms }
    /// ``rms`` を dBFS にしたもの。0 が最大で、無音は -160 (∞ にはしない)。
    public var decibels: Float { levels.decibels }
    /// 区間の標本の絶対値の最大 (振幅の単位)。無音で 0、全振幅の音で 1。
    ///
    /// 立ち上がりの鋭い音 (キックなど) が、区間のどこにあっても拾う。``rms`` は区間の長さで薄まるが、これは薄まらない。
    public var peak: Float { levels.peak }
    /// 帯域ごとの大きさ (振幅の単位)。512 本で、帯域の真ん中にある全振幅の正弦波で 1。区間に終わりが入る
    /// 窓の平均。
    public var spectrum: [Float] { levels.spectrum }

    // MARK: - 0〜1 へ写した値

    /// 音の大きさを 0〜1 にしたもの。-60 dBFS 以下で 0、0 dBFS で 1。
    public var level: Float { levels.level }
    /// ``spectrum`` を帯域ごとに 0〜1 にしたもの。写し方は ``level`` と同じ。
    public var spectrumLevels: [Float] { levels.spectrumLevels }

    // MARK: - 出どころ

    /// 標本化率 (Hz)。マイクは機材が開くまで 0。
    public var sampleRate: Float { source.sampleRate }
    /// 出どころの状態。
    public var state: SourceState { input.state }
    /// 最後に音が届いたフレーム。まだ何も届いていなければ `nil`。
    public var lastArrival: Arrival? { input.lastArrival }

    /// 止める。機材を閉じ、以後の値は無音になる。
    ///
    /// **利用者が止めたものは、足し直しても止まったままである。** ``SketchPart/attach(_:)-(Inlet)`` で足し直しても、
    /// 機材を開かず値は無音のままで、``state`` は ``SourceState/stopped`` のまま (止めたのは利用者の意思なので、
    /// 足し直しで戻さない)。受け始めるには、新しく作る。
    ///
    /// **ランタイムが外した場合は別である。** ``SketchPart/detach(_:)-(Inlet)`` で外しただけ (``stop()`` は呼んで
    /// いない) なら、``SketchPart/attach(_:)-(Inlet)`` で足し直せば、機材を開き直してまた受け取る。実行が終わった
    /// ものは足し直す先が無い。
    ///
    /// `setup()`・`draw()`・入力のコールバックの中から呼ぶ (``SketchPart/detach(_:)-(Inlet)`` と同じ)。
    /// 走っている実行の中で起こした `Task` からも止まる。外 (初期化子の中・後片付けの後) で呼ぶと何もせず、`AudioIn.stop()` のように型を付けた名前で 1 度だけ警告する。
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
        source.start(into: input, at: Double(owner?.authorTime ?? 0))
    }

    public func supply() {
        source.pump(into: input, at: Double(owner?.time ?? 0))
        if let span = input.take() {
            levels = AudioAnalyzer.shared.analyze(span)
            isNewFrame = true
        } else {
            isNewFrame = false
        }
        if state != .running { levels = .silence }
        noticeIfStuck()
    }

    public func close() {
        source.stop()
        input.setState(.stopped)
        // 届いて読まれなかった音は捨てる。足し直した最初の ``supply()`` に、外す前の音を出さない
        input.discardWaiting()
        levels = .silence
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
