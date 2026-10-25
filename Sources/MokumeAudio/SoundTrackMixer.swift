// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation
import MokumeCore
import MokumeDiagnostics

/// 書き出しの動画の音声トラックへ、このスケッチの音の流れ全体を載せる ([#3125])。
///
/// スケッチごとに 1 つで、固定の時計 (画面へ出さない) で動かす最初の音源 (``SoundFile``・``SynthStage``) が
/// 足す。**音源が居ない・録らない実行は何も払わない** — 入り口として居るだけで、`supply()` は何もしない。
///
/// ## 音声トラックが始まったとき
///
/// 固定の時計の音源は、ふだん鳴らさずに、位置をフレームの番号から数える ([ADR-0028] 決定 7)。音声トラックが
/// 始まる (``beginTrack(frameRate:)``) と、機材に出さない流れ (``SoundFlow/offline(sampleRate:channels:maximumFrames:)``)
/// を 1 つ作り、鳴らさずに数で進めていた ``SynthStage`` (ラック) と ``SoundFile`` を、その流れの
/// ``RackPlayer``・``FilePlayer`` へ切り替える。**位置は今の位置から続く** — 解析の値も切り替えの前後で
/// 途切れない。録りの途中で作られた音源は、最初からその流れで鳴る。
///
/// ## 窓
///
/// 窓はフレームごとに、`draw()` の後・次のフレームの供給の前に描く (``mix(into:)``)。フレーム `N` の
/// `draw()` が頼んだ操作 (鳴らす・止める・飛ぶ・音量・合成の変更) は、窓 `N` の先頭から効く。描くのは流れの
/// `renderOffline` で、窓の割り方に依らず同じ標本になる (一括で描いても、窓ごとに描いても一致する)。
///
/// 録りが終わった後 (または録りが窓を頼まないフレーム) は、音源の位置が止まらないよう、窓を描いて捨てる
/// (``supply()``)。
///
/// [#3125]: https://github.com/mokume-metal/mokume/issues/3125
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
final class SoundTrackMixer: SoundSource {
    /// スケッチごとの混ぜ役。**弱く持つ** (``SynthStage/stages`` と同じ理由)。
    private static var mixers: [ObjectIdentifier: Weak] = [:]

    private struct Weak {
        weak var mixer: SoundTrackMixer?
    }

    private struct WeakStage {
        weak var stage: SynthStage?
    }

    private struct WeakFile {
        weak var file: SoundFile?
    }

    /// 流れを描き続けるための、無音の節 (``beginTrack(frameRate:)``)。
    private let silentNode = SoundTrackMixer.makeSilentNode()
    private static let silentFormat = AVAudioFormat(
        standardFormatWithSampleRate: Double(SoundWindow.sampleRate), channels: 2)!

    private weak var owner: (any Sketch)?
    /// 音声トラックが始まったとき作る、機材に出さない流れ。始まるまで `nil`。
    private(set) var flow: SoundFlow?
    private var frameRate = 0
    /// 次に描く窓の番号。窓は順に描き、頼まれなかった窓は描いて捨てる。
    private var nextWindow = 0
    private var stages: [WeakStage] = []
    private var files: [WeakFile] = []
    private var noticed = false
    private var isClosed = false

    private init(owner: any Sketch) {
        self.owner = owner
    }

    /// `sketch` の混ぜ役。まだ無ければ作って、走っているスケッチへ足す。足せなければ `nil`。
    ///
    /// **音源を足す口 (``SoundFile/open()``・``SynthStage/open()``) から呼ぶ** — 走っている実行の中で、音源が
    /// 並びへ入る前に足されるので、混ぜ役は音源より先に `supply()` を受ける (窓を描いてから、音源が値を更新する)。
    static func mixer(for sketch: any Sketch) -> SoundTrackMixer? {
        let key = ObjectIdentifier(sketch)
        if let existing = mixers[key]?.mixer, !existing.isClosed, existing.owner === sketch {
            return existing
        }
        mixers = mixers.filter { $0.value.mixer != nil }
        let mixer = SoundTrackMixer(owner: sketch)
        guard
            sketch.attach(
                mixer, calledAs: "a sound source", returning: "a sound that is not in the recording")
        else { return nil }
        mixers[key] = Weak(mixer: mixer)
        return mixer
    }

    func register(stage: SynthStage) {
        guard !stages.contains(where: { $0.stage === stage }) else { return }
        stages.removeAll { $0.stage == nil }
        stages.append(WeakStage(stage: stage))
    }

    func register(file: SoundFile) {
        guard !files.contains(where: { $0.file === file }) else { return }
        files.removeAll { $0.file == nil }
        files.append(WeakFile(file: file))
    }

    /// 何も出さない節。**隔離の外で作る** (音の realtime スレッドで呼ばれる — ``RackPlayer`` と同じ理由)。
    nonisolated private static func makeSilentNode() -> AVAudioSourceNode {
        AVAudioSourceNode { _, _, _, bufferList in
            for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }
    }

    // MARK: - SoundSource

    func supply() {
        guard flow != nil, let owner else { return }
        // 録りが窓を頼まなかったフレームの窓は、描いて捨てる (音源の位置は描いた標本の数から読む)
        discardWindows(before: max(0, owner.frameCount - 1))
    }

    func beginTrack(frameRate: Int) {
        guard flow == nil else {
            // 2 本目の録り。流れは続いている
            self.frameRate = frameRate
            return
        }
        guard
            let made = try? SoundFlow.offline(
                sampleRate: Double(SoundWindow.sampleRate), channels: 2, maximumFrames: 4096)
        else {
            notice(
                "The sound of this sketch could not be put in the recording: the offline audio flow could "
                    + "not be made")
            return
        }
        // **何も繋がっていない流れは描けない** (機材に出さない流れの `renderOffline` は、節が 1 つも無いと落ちる)。
        // 音源が 1 つも流れへ入れなかった (読み直せない・出力が開けない) ときも描けるよう、無音の節を 1 つ繋いでおく
        guard made.join(silentNode, format: Self.silentFormat) else {
            notice("The audio flow of the recording could not be started, so the sound is not in the movie")
            return
        }
        flow = made
        self.frameRate = frameRate
        nextWindow = max(0, (owner?.frameCount ?? 1) - 1)
        for entry in stages { entry.stage?.joinTrack(made) }
        for entry in files { entry.file?.joinTrack(made) }
    }

    func mix(into window: inout SoundWindow) {
        guard flow != nil else { return }
        discardWindows(before: window.frame)
        let (left, right) = render(count: window.count)
        for index in 0..<window.count {
            window.left[index] += left[index]
            window.right[index] += right[index]
        }
        nextWindow = window.frame + 1
    }

    func endTrack() {}

    func close() {
        isClosed = true
        flow = nil
    }

    // MARK: - 描く

    private func discardWindows(before frame: Int) {
        while nextWindow < frame {
            _ = render(count: SoundWindow.count(ofFrame: nextWindow, frameRate: frameRate))
            nextWindow += 1
        }
    }

    /// 流れから `count` 標本を描く。描けなかった分は無音で埋め、1 度だけ知らせる。
    private func render(count: Int) -> (left: [Float], right: [Float]) {
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(count)
        right.reserveCapacity(count)
        if let flow, flow.start() {
            let engine = flow.engine
            while left.count < count {
                let chunk = min(4096, count - left.count)
                guard
                    let buffer = AVAudioPCMBuffer(
                        pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(chunk)),
                    (try? engine.renderOffline(AVAudioFrameCount(chunk), to: buffer)) == .success,
                    buffer.frameLength > 0, let data = buffer.floatChannelData
                else { break }
                let frames = Int(buffer.frameLength)
                left.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
                right.append(
                    contentsOf: UnsafeBufferPointer(start: data[buffer.format.channelCount > 1 ? 1 : 0], count: frames))
            }
        }
        if left.count < count {
            notice("The audio flow could not render some of the sound, so a stretch of the recording is silent")
            left += [Float](repeating: 0, count: count - left.count)
            right += [Float](repeating: 0, count: count - right.count)
        }
        return (left, right)
    }

    private func notice(_ message: String) {
        guard !noticed else { return }
        noticed = true
        Diagnostics.warn(message)
    }
}
