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
/// 窓はフレームごとに、`draw()` の後・次のフレームの供給の前に描く (``mix(into:)``)。描くのは流れの
/// `renderOffline` で、窓の割り方に依らず同じ標本になる (一括で描いても、窓ごとに描いても一致する)。
///
/// **操作が効く時刻は操作ごとに違う** ([ADR-0042] 決定 6 の改訂「操作が効く時刻」)。フレーム `N` の `draw()` が
/// 頼んだ、鳴らす (`play()`・`loop()`)・止める (`pause()`・`stop()`)・音量 (`amp(_:)`)・合成の変更は、窓 `N` の
/// 先頭から効く (音量は窓 `N` の先頭から変わり始め、窓 `N` の終わりまでに新しい音量に着く。途中の形と長さは OS に依るので約束しない)。飛ぶ (`jump(_:)`) は鳴っている間は次のフレームの頭で効くので、窓 `N + 1` の先頭から効く。
///
/// 録りが終わった後 (または録りが窓を頼まないフレーム) は、音源の位置が止まらないよう、流れを描き進めて捨てる
/// (``supply()``)。描けなかった分は、後の窓で描き足して流れの時間を戻す (``TrackFlow``)。
///
/// **限界**: `renderOffline` が続けて失敗する間は、その窓が無音のまま動画に書かれ、そのことを 1 度だけ診断に
/// 出す。**`mokume render` の終了コードには現れない** — 終了コードは動画へ書けなかったときに立ち、無音の窓も
/// 書けた窓である。流れが回復すれば、失敗した窓だけが無音で、以後の窓は元の時刻に戻る。
///
/// **動画の長さで切る**: 音声トラックの長さは映像と同じで、書き出しで絵が描けず落ちた末尾のフレームの窓は、描いて
/// 書くが、その音は動画に残らない。
///
/// [#3125]: https://github.com/mokume-metal/mokume/issues/3125
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
final class SoundTrackMixer: Inlet, SoundSource {
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

    /// 音声トラックの流れを作った直後に呼ぶ手 (検査)。流れを受けつけなくするなど、流れの状況を作る。
    var flowMadeForTesting: ((SoundFlow) -> Void)?

    private weak var owner: (any Sketch)?
    /// 音声トラックが始まったとき作る、機材に出さない流れ。始まるまで `nil`。
    private(set) var track: TrackFlow?
    /// 音声トラックが始まったときの流れ。始まるまで `nil`。
    var flow: SoundFlow? { track?.flow }
    private var frameRate = 0
    private var stages: [WeakStage] = []
    private var files: [WeakFile] = []
    private var noticed = false
    private var isClosed = false

    private init(owner: any Sketch) {
        self.owner = owner
    }

    /// `sketch` の混ぜ役。まだ無ければ作って、走っているスケッチへ足す。足せなければ `nil`。
    ///
    /// **音源を足す口 (``SoundFile/open()``・``SynthStage/open()``) から、録りが音を載せるかどうかに依らず呼ぶ**
    /// — 混ぜ役が入り口として居ることが「スケッチに音源が居る」という印で、載せない録り (実時間の時計・画面へ
    /// 出す録り・MP4・GIF・連番) が、音源が居ることを 1 度だけ名乗れる (``FrameRecorder/decideSound(hasSources:fixedClock:)``)。
    /// 走っている実行の中で、音源が並びへ入る前に足されるので、混ぜ役は音源より先に `supply()` を受ける
    /// (窓を描いてから、音源が値を更新する)。
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
        guard let track, let owner else { return }
        // 録りが窓を頼まなかったフレームの分は、流れを描き進めて捨てる (音源の位置は描いた標本の数から読む)
        let frame = max(0, owner.frameCount - 1)
        let complete = track.advance(to: SoundWindow.start(ofFrame: frame, frameRate: frameRate), keeping: 0).complete
        if !complete { noticeIncomplete() }
    }

    func beginTrack(frameRate: Int) {
        guard track == nil else {
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
        self.frameRate = frameRate
        flowMadeForTesting?(made)
        // 流れの時間は、最初の窓の先頭の標本から数える
        let first = max(0, (owner?.frameCount ?? 1) - 1)
        track = TrackFlow(flow: made, base: SoundWindow.start(ofFrame: first, frameRate: frameRate))
        for entry in stages { entry.stage?.joinTrack(made) }
        for entry in files { entry.file?.joinTrack(made) }
    }

    func mix(into window: inout SoundWindow) {
        guard let track else { return }
        let rendered = track.advance(to: window.start + window.count, keeping: window.count)
        if !rendered.complete { noticeIncomplete() }
        for index in 0..<window.count {
            window.left[index] += rendered.left[index]
            window.right[index] += rendered.right[index]
        }
    }

    func endTrack() {}

    func close() {
        isClosed = true
        track = nil
    }

    private func noticeIncomplete() {
        notice("The audio flow could not render some of the sound, so a stretch of the recording is silent")
    }

    private func notice(_ message: String) {
        guard !noticed else { return }
        noticed = true
        Diagnostics.warn(message)
    }
}

/// 機材に出さない流れを、音声トラックの始まりの標本から数えて描き進める。
///
/// **流れの時間を、標本の番号で持つ。** 描けなかった窓 (`renderOffline` が失敗した) の分を無音で埋めるだけだと、流れの
/// 時間が遅れたまま以後の窓を描き、音源の位置も窓の時刻より遅れて、恒久的に早く鳴ってしまう。描き進めた数を
/// ``rendered`` に持ち、次の窓では目的地 (窓の終わり) まで描き足す: 遅れた分は捨て、窓の長さぶんの最後だけを返すので、
/// 失敗した窓の音だけが無音になり、以後の窓は元の時刻に戻る。
final class TrackFlow {
    let flow: SoundFlow
    /// 流れの時間の原点 (最初の窓の先頭の標本の番号)。
    let base: Int
    /// 原点から描き進めた標本の数。
    private(set) var rendered = 0
    /// 流れから `count` 標本を `buffer` へ描く。描けたら `true`。**検査が差し替える。**
    var renderChunk: (AVAudioEngine, AVAudioFrameCount, AVAudioPCMBuffer) -> Bool = { engine, count, buffer in
        (try? engine.renderOffline(count, to: buffer)) == .success
    }

    init(flow: SoundFlow, base: Int) {
        self.flow = flow
        self.base = base
    }

    /// 絶対の標本 `end` まで描き進め、その手前の `count` 標本を返す。描いた分より前は捨てる。
    ///
    /// - Returns: 左右の標本 (描けなかった分は無音) と、`end` まで描き切れたか。
    func advance(to end: Int, keeping count: Int) -> (left: [Float], right: [Float], complete: Bool) {
        let target = max(0, end - base)
        let keptFrom = target - count
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        guard rendered < target else { return (left, right, true) }
        guard flow.start() else { return (left, right, false) }
        let engine = flow.engine
        while rendered < target {
            let chunk = min(4096, target - rendered)
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(chunk)),
                renderChunk(engine, AVAudioFrameCount(chunk), buffer),
                buffer.frameLength > 0, let data = buffer.floatChannelData
            else { return (left, right, false) }
            let frames = min(Int(buffer.frameLength), chunk)
            let rightData = buffer.format.channelCount > 1 ? data[1] : data[0]
            for index in 0..<frames where rendered + index >= keptFrom {
                left[rendered + index - keptFrom] = data[0][index]
                right[rendered + index - keptFrom] = rightData[index]
            }
            rendered += frames
        }
        return (left, right, true)
    }
}
