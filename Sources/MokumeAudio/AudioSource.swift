// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

/// 音の出どころ。**実機もファイルも合成した標本列も、同じ入れ物 (``ExternalInput``) へ
/// 解析する窓を入れる** ([ADR-0028] 決定 6・[ADR-0042] 決定 4 の「供給元を差し替えられる」)。
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
    func start(into input: ExternalInput<[Float]>, at time: Double)
    /// フレームごと、取り出す前に呼ばれる。`time` はそのフレームの時刻 (秒)。
    func pump(into input: ExternalInput<[Float]>, at time: Double)
    /// 止める。
    func stop()
}

/// 手元にある標本列を、フレームの時刻の窓で入れる出どころ。**機材も許可も使わず、鳴らさない。**
///
/// 窓の終わりは「開いてからフレームの時刻までの経過」で決まる。時刻がフレームの数え方から
/// 決まる時計 (固定の時計) で回せば、同じ列からは何度回しても同じ窓が同じフレームに入る
/// ([ADR-0028] 決定 7・[ADR-0025] の水準 2)。終わりまで行けば始まりへ戻る。
///
/// ファイル (``Sketch/createAudioIn(file:)``) も、読み終えた標本列としてここへ来る。
///
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
final class RecordedSource: AudioSource {
    let samples: [Float]
    let sampleRate: Float
    private var origin: Double = 0

    init(samples: [Float], sampleRate: Float) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    func start(into input: ExternalInput<[Float]>, at time: Double) {
        origin = time
        input.setState(samples.isEmpty ? .unavailable : .running)
    }

    func pump(into input: ExternalInput<[Float]>, at time: Double) {
        guard input.state == .running else { return }
        input.send(
            AudioAnalysis.window(of: samples, sampleRate: sampleRate, endingAt: time - origin))
    }

    func stop() {}
}
