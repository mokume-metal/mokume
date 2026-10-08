// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio

/// 音の流れ。鳴らす音源の節を受け、混ぜて出力の機材へ出す。
///
/// **音の流れは音のターゲットが持ち、本体に差込口を足さない** ([ADR-0042] 決定 6)。音は絵の
/// フレームの前でも後でもなく、OS の音の時計で進むためである。再生 (``FilePlayer``) と、
/// 合成とエフェクト (``RackPlayer``) は、ここへ節を入れる音源である。
///
/// `AVAudioEngine` を持つのはここだけで、節の繋ぎ方 (混ぜる節の空いた入口へ繋ぐ) もここに閉じる。
///
/// - 実機へ出す流れ (``speakers``) はプロセスに 1 つで、最初に頼まれたときに作る。節が 1 つも
///   無くなれば止め、次に頼まれたら始め直す
/// - 機材に出さない流れ (``offline(sampleRate:channels:maximumFrames:)``) は、呼んだ側が
///   描かせる (manual rendering)。検査が使い、機材にも許可にも触れない
///
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
final class SoundFlow {
    let engine: AVAudioEngine
    /// 機材に出さず、呼んだ側が描かせる流れか。
    let isOffline: Bool
    /// 流れに入っている節の数。
    private var members = 0

    private init(engine: AVAudioEngine, isOffline: Bool) {
        self.engine = engine
        self.isOffline = isOffline
    }

    /// 実機の出力へ出す流れ。プロセスに 1 つ。
    static var speakers: SoundFlow {
        if let shared { return shared }
        let flow = SoundFlow(engine: AVAudioEngine(), isOffline: false)
        shared = flow
        return flow
    }
    private static var shared: SoundFlow?

    /// 機材に出さない流れ。描くのは呼んだ側 (`engine.renderOffline`) で、描いた分だけ時間が進む。
    static func offline(
        sampleRate: Double, channels: AVAudioChannelCount, maximumFrames: AVAudioFrameCount
    ) throws -> SoundFlow {
        let engine = AVAudioEngine()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)
        else { throw AudioFailure.invalidSampleRate(Float(sampleRate)) }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maximumFrames)
        return SoundFlow(engine: engine, isOffline: true)
    }

    /// 合成した音を作る標本化率 (Hz)。機材に出さない流れは、描かせる形式の標本化率に合わせて、
    /// 変換を挟まない。実機へ出す流れは 48000 で、出力の機材と違えば混ぜる節が変換する。
    var synthesisRate: Double {
        isOffline ? engine.manualRenderingFormat.sampleRate : 48_000
    }

    /// 動いているか。出力の機材が替わる (標本化率やチャンネル数が変わる) と、流れは自分で止まる。
    var isRunning: Bool { engine.isRunning }

    /// 節を流れへ入れ、混ぜる節の空いた入口へ繋ぐ。止まっていれば始める。
    ///
    /// - Returns: 鳴らせる状態になったか。始められなければ節を外して `false` を返す
    ///   (出力の機材が無い・開けない)。
    func join(_ node: AVAudioNode, format: AVAudioFormat) -> Bool {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        members += 1
        guard start() else {
            leave(node)
            return false
        }
        return true
    }

    /// 節を外す。実機へ出す流れは、節が 1 つも無くなれば止める。
    func leave(_ node: AVAudioNode) {
        guard node.engine === engine else { return }
        engine.detach(node)
        members -= 1
        if members == 0, !isOffline { engine.stop() }
    }

    /// 止まっていれば始める。始められたか (既に動いていたか) を返す。
    @discardableResult
    func start() -> Bool {
        if engine.isRunning { return true }
        do {
            try engine.start()
            return true
        } catch {
            return false
        }
    }
}
