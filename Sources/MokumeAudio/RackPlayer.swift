// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio

/// ラック (``SynthRack``) を音の流れ (``SoundFlow``) へ入れて、実際に鳴らす。
///
/// ``FilePlayer`` と同じ位置づけで、合成した音を AVFAudio へ渡すのはこの型だけである
/// ([ADR-0042] 決定 6 の「薄い層に閉じる」)。ラックを `AVAudioSourceNode` にして流れへ足し、
/// 流れが呼ぶたびにラックが標本を作る。**呼ばれるのは音の realtime スレッド**で、ラックは
/// そこで待たず、確保もしない ([ADR-0042] 決定 7)。
///
/// 標本化率はラックのものを使い、流れの出力と違えば混ぜる節が変換する。
///
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
final class RackPlayer {
    let flow: SoundFlow
    private let node: AVAudioSourceNode

    /// 流れに入れる。鳴らせなければ (出力が開けない) `nil`。
    init?(flow: SoundFlow, rack: SynthRack) {
        self.flow = flow
        guard
            let format = AVAudioFormat(standardFormatWithSampleRate: rack.sampleRate, channels: 2)
        else { return nil }
        node = Self.makeNode(rack: rack, format: format)
        guard flow.join(node, format: format) else { return nil }
    }

    /// 流れから外す。
    func leave() {
        flow.leave(node)
    }

    /// 音の側のスレッドで走る手続きを作る。
    ///
    /// **隔離の外で作る。** 手続きは音の realtime スレッドで呼ばれるので、main actor に属させると
    /// 動的な隔離検査 (SE-0423) で落ちる ([ADR-0042] 決定 7)。
    ///
    /// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
    nonisolated private static func makeNode(rack: SynthRack, format: AVAudioFormat)
        -> AVAudioSourceNode
    {
        AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            rack.render(left: left, right: right, frames: Int(frameCount))
            return noErr
        }
    }
}
