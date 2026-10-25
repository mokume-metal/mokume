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
    /// 始める。`time` は開いたときのスケッチの時刻 (秒)。状態は `input` へ入れる。
    func start(into input: ExternalInput<AudioSpan>, at time: Double)
    /// フレームごと、取り出す前に呼ばれる。`time` はそのフレームの時刻 (秒)。
    func pump(into input: ExternalInput<AudioSpan>, at time: Double)
    /// 止める。
    func stop()
}

/// 手元にある標本列を、フレームの時刻までの区間で入れる出どころ。**機材も許可も使わず、鳴らさない。**
///
/// 区間の終わりは「開いてからフレームの時刻までの経過」で決まり、始まりは前のフレームの区間の終わり
/// である。時刻がフレームの数え方から決まる時計 (固定の時計) で回せば、同じ列からは何度回しても同じ
/// 区間が同じフレームに入る ([ADR-0028] 決定 7・[ADR-0025] の水準 2)。終わりまで行けば始まりへ戻る
/// (通し番号は戻らず、標本だけが始まりから読み直される)。
///
/// **標本が進まなかったフレームは何も入れない** — マイクで新しい標本が届かなかったときと同じく、値は前の
/// まま (``AudioIn/isNewFrame`` が false)。開いた最初のフレーム (経過が 0)、``SketchPart/pauseTime()``
/// で時間を止めた間、時間を過去へ飛ばした直後 (``SketchPart/jumpTime(_:)``。そこから数え直す) が当たる。
///
/// ファイル (``Sketch/createAudioIn(file:)``) も、読み終えた標本列としてここへ来る。
///
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
final class RecordedSource: AudioSource {
    let samples: [Float]
    let sampleRate: Float
    private var origin: Double = 0
    /// 前に入れた区間の終わり (標本の通し番号)。
    private var covered = 0

    init(samples: [Float], sampleRate: Float) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    func start(into input: ExternalInput<AudioSpan>, at time: Double) {
        origin = time
        covered = 0
        input.setState(samples.isEmpty ? .unavailable : .running)
    }

    func pump(into input: ExternalInput<AudioSpan>, at time: Double) {
        guard input.state == .running else { return }
        let end = Self.index(at: time - origin, sampleRate: sampleRate)
        // 過去へ飛んだら、そこから数え直す (区間は空で、次のフレームがそこから始まる)
        if end < covered { covered = end }
        guard end > covered else { return }
        let from = AudioAnalysis.limited(from: covered, to: end)
        covered = end
        let first = AudioAnalysis.firstNeeded(from: from)
        // 終わりまで行けば始まりへ戻る
        let window = (first..<end).map { samples[$0 % samples.count] }
        input.send(AudioSpan(base: first, samples: window, from: from))
    }

    func stop() {}

    /// 時刻 `time` (秒) までに届いた標本の数 (標本の間に落ちる時刻は切り捨てる)。
    static func index(at time: Double, sampleRate: Float) -> Int {
        max(0, Int((time * Double(sampleRate)).rounded(.down)))
    }
}
