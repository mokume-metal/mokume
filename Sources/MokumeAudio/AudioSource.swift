// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

/// 音の出どころ。**実機もファイルも合成した標本列も、同じ入れ物 (``ExternalInput``) へ
/// 解析する区間を入れる** ([ADR-0028] 決定 6・[ADR-0042] 決定 4 の「供給元を差し替えられる」)。
///
/// 入れ物から先 (``AudioIn``) は出どころを知らない。だから標本列で回した検査が、実機のときの
/// 解析と受け渡しの正しさをそのまま固定する。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
protocol AudioSource: AnyObject {
    /// 標本化率 (Hz)。実機は機材が開くまで 0。
    var sampleRate: Float { get }
    /// 始める。`clock` は開いたときの時計の位置。状態は `input` へ入れる。
    func start(into input: ExternalInput<AudioSpan>, at clock: SourceClock)
    /// フレームごと、取り出す前に呼ばれる。`clock` はそのフレームの時計の位置。
    func pump(into input: ExternalInput<AudioSpan>, at clock: SourceClock)
    /// 止める。
    func stop()
}

/// 出どころが「どこまで進んだか」を決めるための、フレームの時計の位置。
///
/// **秒は作者の時計の秒 (倍精度) で、止める・飛ぶ (``SketchPart/pauseTime()``・``SketchPart/jumpTime(_:)``) に従う。**
/// 固定の時計 (書き出し) では、秒に fps を掛けた「フレームの位置」から標本の位置を整数で数える (``FrameSamples``)。
/// 秒をそのまま標本化率に掛けると、窓の継ぎ目 ([ADR-0042] 決定 6 の「時刻の対応」) と 1 標本ずれるフレームがある
/// (48 kHz・30 fps の 17 フレーム目で 27199 対 27200)。止めも飛びもしない間は、位置がフレームの番号と等しく、
/// 継ぎ目と 1 標本も違わない。
///
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
struct SourceClock: Equatable, Sendable {
    /// 作者の時計の秒。**時刻を指定した観測の枚でも、作者の時計のまま** (観測の秒を状態に積まない・#2357)。
    var seconds: Double
    /// 固定の時計 (鳴らさず数で進める) の fps。実時間 (画面へ出している・実時間の時計) なら `nil`。
    var perSecond: Int?
    /// 時刻を指定した観測の枚の、指定の秒。観測の枚でなければ `nil`。**区間を数える秒には使わない** — 観測の枚は
    /// 通常の枚と同じ区間を数え (通常の続きを歪めない)、この秒で終わる 1 フレームぶんの区間を別に解いて見せる。
    var observed: Double?

    init(seconds: Double, perSecond: Int? = nil, observed: Double? = nil) {
        self.seconds = seconds
        self.perSecond = perSecond
        self.observed = observed
    }
}

extension AudioSource {
    /// 秒だけで始める (実時間の時計。検査の短縮)。
    func start(into input: ExternalInput<AudioSpan>, at time: Double) {
        start(into: input, at: SourceClock(seconds: time))
    }

    /// 秒だけで取り出す (実時間の時計。検査の短縮)。
    func pump(into input: ExternalInput<AudioSpan>, at time: Double) {
        pump(into: input, at: SourceClock(seconds: time))
    }
}

/// 手元にある標本列を、フレームの時刻までの区間で入れる出どころ。**機材も許可も使わず、鳴らさない。**
///
/// 区間の終わりは「開いてからフレームの時刻までの経過」で決まり、始まりは前のフレームの区間の終わり
/// である。時刻は作者の時計の秒で、止める・飛ぶに従う。固定の時計 (時刻がフレームの数え方から決まる) では、
/// 経過を秒に fps を掛けたフレームの位置から整数で数える (``SourceClock``)。同じ列からは何度回しても、
/// ``SoundFile`` と同じ fps なら同じ区間が同じフレームに入る ([ADR-0028] 決定 7・[ADR-0025] の水準 2)。終わりまで
/// 行けば始まりへ戻る (通し番号は戻らず、標本だけが始まりから読み直される)。
///
/// **標本が進まなかったフレームは何も入れない** — マイクで新しい標本が届かなかったときと同じく、値は前の
/// まま (``AudioIn/isNewFrame`` が false)。開いた最初のフレーム (経過が 0)、``SketchPart/pauseTime()``
/// で時間を止めた間、時間を過去へ飛ばした直後 (``SketchPart/jumpTime(_:)``。そこから数え直す) が当たる。
///
/// **時刻を指定した観測の枚** (``SourceClock/observed``) は、通常の枚と同じ区間を数えて続きを進めたうえで、
/// 指定の秒で終わる 1 フレームぶんの区間を別に解いて見せる (``AudioSpan/observation``)。観測の枚の後の通常の枚は、
/// 観測が無かったときと同じ値になる。
///
/// ファイル (``Sketch/createAudioIn(file:)``) も、読み終えた標本列としてここへ来る。
///
/// **外して足し直しても、時刻は最初に開いたときから数える** (時刻どおり・[#3152])。外していた間も作者の時計は進んで
/// いたものとして、足し直した最初の区間は、その時刻で終わる窓になる (外していた間の標本は届かない)。足し直した位置から
/// 標本の頭へ戻らない。
///
/// [#3152]: https://github.com/mokume-metal/mokume/issues/3152
///
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
final class RecordedSource: AudioSource {
    let samples: [Float]
    let sampleRate: Float
    private var origin = SourceClock(seconds: 0)
    /// 一度でも開いたか。**起点 (``origin``) は最初に開いたときだけ決める** — 足し直しで取り直すと、位置が標本の頭へ戻る (#3152)。
    private var opened = false
    /// 前に入れた区間の終わり (標本の通し番号)。
    private var covered = 0
    /// 前に入れた通常の区間の長さ。実時間の時計で、観測の枚の「1 フレームぶん」を決める。まだ無ければ解析の窓。
    private var lastLength = AudioAnalysis.windowSize

    init(samples: [Float], sampleRate: Float) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    func start(into input: ExternalInput<AudioSpan>, at clock: SourceClock) {
        if !opened {
            origin = clock
            lastLength = AudioAnalysis.windowSize
            opened = true
        }
        // 最初の開きは 0 (起点と同じ時刻)。足し直しは、外していた間に進んだぶんの標本を飛ばした位置から数える
        // — 外さずに回した実行の、足し直した時刻までの区間の終わりと同じ位置
        covered = endIndex(at: clock.seconds, clock: clock)
        input.setState(samples.isEmpty ? .unavailable : .running)
    }

    func pump(into input: ExternalInput<AudioSpan>, at clock: SourceClock) {
        guard input.state == .running else { return }
        let end = endIndex(at: clock.seconds, clock: clock)
        // 過去へ飛んだら、そこから数え直す (区間は空で、次のフレームがそこから始まる)
        if end < covered { covered = end }
        var span = AudioSpan(base: 0, samples: [], from: 0)
        if end > covered {
            let from = AudioAnalysis.limited(from: covered, to: end)
            covered = end
            lastLength = end - from
            span = interval(from: from, to: end)
        }
        span.observation = observation(at: clock)
        guard !span.isEmpty || span.observation != nil else { return }
        input.send(span)
    }

    func stop() {}

    /// 標本 `[from, to)` の区間 (終わりまで行けば始まりへ戻る)。
    private func interval(from: Int, to: Int) -> AudioSpan {
        let first = AudioAnalysis.firstNeeded(from: from)
        return AudioSpan(
            base: first, samples: (first..<to).map { samples[$0 % samples.count] }, from: from)
    }

    /// 時刻を指定した観測の枚が見せる、指定の秒で終わる 1 フレームぶんの区間。観測の枚でなければ `nil`。
    /// 通常の続き (``covered``) には触れない。
    private func observation(at clock: SourceClock) -> AudioSpan.Observation? {
        guard let shown = clock.observed else { return nil }
        let end = endIndex(at: shown, clock: clock)
        let start: Int
        if let perSecond = fixedRate(of: clock) {
            // 固定の時計: 通常の枚と同じ式で、指定の秒の 1 フレーム前の頭から
            start = endIndex(at: shown - 1 / Double(perSecond), clock: clock)
        } else {
            start = end - lastLength
        }
        let from = AudioAnalysis.limited(from: max(0, start), to: end)
        guard end > from else { return nil }
        let span = interval(from: from, to: end)
        return AudioSpan.Observation(base: span.base, samples: span.samples, from: span.from)
    }

    /// 開いたときと同じ fps の固定の時計か。そうなら fps。
    private func fixedRate(of clock: SourceClock) -> Int? {
        guard let perSecond = clock.perSecond, origin.perSecond == perSecond else { return nil }
        return perSecond
    }

    /// 作者の時計の秒 `seconds` までに届いた標本の数。固定の時計なら、開いたときの位置からの差を、フレームの位置の
    /// 絶対の式の差で数える (``FrameSamples``)。実時間なら、開いてからの秒数 (標本の間に落ちる時刻は切り捨てる)。
    private func endIndex(at seconds: Double, clock: SourceClock) -> Int {
        if let perSecond = fixedRate(of: clock) {
            let rate = Double(perSecond)
            return max(
                0,
                FrameSamples.count(
                    fromPosition: origin.seconds * rate, toPosition: seconds * rate,
                    perSecond: perSecond, sampleRate: Double(sampleRate)))
        }
        return Self.index(at: seconds - origin.seconds, sampleRate: sampleRate)
    }

    /// 時刻 `time` (秒) までに届いた標本の数 (標本の間に落ちる時刻は切り捨てる)。
    static func index(at time: Double, sampleRate: Float) -> Int {
        max(0, Int((time * Double(sampleRate)).rounded(.down)))
    }
}
