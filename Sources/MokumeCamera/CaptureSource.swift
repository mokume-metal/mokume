// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

/// カメラの絵の出どころ。**実機も記録の再生も、同じ入れ物 (``ExternalInput``) へ入れる**
/// ([ADR-0028] 決定 6・[ADR-0042] 決定 4 の「供給元を差し替えられる」)。
///
/// 入れ物から先 (``Capture``) は出どころを知らない。だから記録の再生で回した検査が、
/// 実機のときの受け取りの正しさをそのまま固定する。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
protocol CaptureSource: AnyObject {
    /// 始める。届いた絵と状態は `input` へ入れる。
    func start(into input: ExternalInput<DisplayImage>)
    /// フレームごと、取り出す前に呼ばれる。**実機は何もしない** (絵は向こうの都合で届く)。
    func pump(into input: ExternalInput<DisplayImage>)
    /// 止める。
    func stop()
}

/// 記録した絵の列を、フレームごとに 1 枚ずつ入れる出どころ。**機材も許可も使わない。**
///
/// どの絵が入るかはフレームの数え方だけで決まる (始めてから何回目の取り出しか) ので、
/// 同じ列からは何度回しても同じ絵が同じフレームに出る ([ADR-0028] 決定 7)。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
final class FramesSource: CaptureSource {
    private let frames: [DisplayImage]
    private var next = 0

    init(frames: [DisplayImage]) {
        self.frames = frames
    }

    func start(into input: ExternalInput<DisplayImage>) {
        input.setState(frames.isEmpty ? .unavailable : .running)
    }

    func pump(into input: ExternalInput<DisplayImage>) {
        guard !frames.isEmpty, input.state == .running else { return }
        input.send(frames[next % frames.count])
        next += 1
    }

    func stop() {}
}
