// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeCore

// 音の入力。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// 呼べば使える標準の機能である ([ADR-0042] 決定 1)。`plugins` には何も書かない —
// 作る口が、走っているスケッチへ自分で入り口を足す (``Sketch/attach(_:)-(Inlet)``)。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
extension Sketch {

    /// マイク (音の入力の機材) を開く。音を解析した値は ``AudioIn`` から読む。
    ///
    /// ```swift
    /// final class Pulse: Sketch {
    ///     var mic: AudioIn?
    ///     func setup() { mic = createAudioIn() }
    ///     func draw() {
    ///         background(0)
    ///         if let mic { circle(width / 2, height / 2, 40 + mic.level * 300) }
    ///     }
    /// }
    /// ```
    ///
    /// - **呼んだときだけ機材を開く。** `import mokume` しただけでマイクが開いたり、許可の
    ///   ダイアログが出たりはしない
    /// - チャンネルが複数あれば、平均して 1 つにしてから解析する
    /// - **機材が無くても作れる。** ``AudioIn/state`` が ``SourceState/unavailable`` になり、
    ///   挿されたら始まる。選んだ機材が抜かれたら ``SourceState/disconnected`` になり、挿し直せば戻る
    /// - 初めて使うときは OS が許可を求める。束ねずに動かしている間は、許可はスケッチを
    ///   起動した端末のアプリに付く。束ねるときは `mokume-app.json` に `microphoneUsage` を書く
    ///
    /// `setup()`・`draw()`・入力のコールバックの中で呼ぶ。
    ///
    /// - Parameter device: 使う機材 (``audioInputDevices()`` から選ぶ)。省けば既定の入力。
    public func createAudioIn(device: AudioDevice? = nil) -> AudioIn {
        let audio = AudioIn(
            device: device, name: device.map { "microphone: \($0.name)" } ?? "microphone",
            source: MicrophoneSource(device: device), owner: self)
        attach(audio)
        return audio
    }

    /// 音声ファイルを、マイクの代わりに解析する。**鳴らさない。機材も許可も使わない。**
    ///
    /// <!-- example: 文脈 var song: AudioIn? -->
    /// ```swift
    /// func setup() {
    ///     song = try? createAudioIn(file: "assets/song.wav")
    /// }
    /// func draw() {
    ///     background(0)
    ///     if let song { circle(width / 2, height / 2, 40 + song.level * 300) }
    /// }
    /// ```
    ///
    /// 各フレームでは、開いてからそのフレームの時刻までに進んだところで終わる窓を解析する。
    /// 終わりまで行けば始まりへ戻る。**どの窓を解析するかはフレームの時刻だけで決まる**ので、
    /// 固定の時計で書き出すと、何度書き出しても同じフレームが同じ値を受け取る
    /// ([ADR-0028] 決定 7)。マイクを使うスケッチを、機材の無い場所で確かめるときにも使う。
    ///
    /// 探す場所は ``loadImage(_:)`` と同じ (``assetURL(_:)``)。読み込みは作るときに 1 度だけで、
    /// 全体を標本列として持つ。
    ///
    /// - Parameter file: 音声ファイルの名前。macOS が読める形式 (WAV・AIFF・CAF・MP3・
    ///   AAC/M4A・FLAC など)。
    /// - Throws: 見つからない・音声として読めない・標本が 1 つも無いとき。
    ///
    /// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
    public func createAudioIn(file: String) throws(AudioFailure) -> AudioIn {
        let decoded = try AudioFile.read(audioURL(file), path: file)
        return attachRecorded(
            samples: decoded.samples, sampleRate: decoded.sampleRate, name: "audio file: \(file)")
    }

    /// 手元の標本列を、マイクの代わりに解析する。**鳴らさない。機材も許可も使わない。**
    ///
    /// ```swift
    /// final class Beat: Sketch {
    ///     var beat: AudioIn?
    ///     func setup() {
    ///         // 440 Hz の音を、1 秒に 2 回大きくする
    ///         let samples = (0..<48_000).map { index -> Float in
    ///             let t = Float(index) / 48_000
    ///             return sin(2 * .pi * 440 * t) * (0.5 + 0.5 * cos(2 * .pi * 2 * t))
    ///         }
    ///         beat = try? createAudioIn(samples: samples, sampleRate: 48_000)
    ///     }
    ///     func draw() {
    ///         background(0)
    ///         if let beat { circle(width / 2, height / 2, 40 + beat.level * 300) }
    ///     }
    /// }
    /// ```
    ///
    /// 解析する窓の決まり方は ``createAudioIn(file:)`` と同じで、終わりまで行けば始まりへ戻る。
    ///
    /// - Parameters:
    ///   - samples: 標本 (-1〜1 が全振幅)。1 チャンネル。
    ///   - sampleRate: 1 秒あたりの標本の数。
    /// - Throws: 標本が 1 つも無いか、標本化率が正でないとき。
    public func createAudioIn(samples: [Float], sampleRate: Float) throws(AudioFailure) -> AudioIn {
        guard !samples.isEmpty else { throw .empty }
        guard sampleRate > 0, sampleRate.isFinite else { throw .invalidSampleRate(sampleRate) }
        return attachRecorded(samples: samples, sampleRate: sampleRate, name: "audio (samples)")
    }

    /// 繋がっている音の入力の機材の一覧。``createAudioIn(device:)`` で 1 つを選ぶのに使う。
    ///
    /// ```swift
    /// func setup() {
    ///     for device in audioInputDevices() { print(device.name) }
    /// }
    /// ```
    public func audioInputDevices() -> [AudioDevice] {
        AudioDevice.connected()
    }

    /// 音声ファイルの名前を場所へ解く。探す場所は ``assetURL(_:)`` と同じで、見つからなければ
    /// 音の失敗として投げる。
    func audioURL(_ file: String) throws(AudioFailure) -> URL {
        do {
            return try assetURL(file)
        } catch {
            switch error {
            case .notFound(let path, let searched): throw .notFound(path: path, searched: searched)
            }
        }
    }

    private func attachRecorded(samples: [Float], sampleRate: Float, name: String) -> AudioIn {
        let audio = AudioIn(
            device: nil, name: name,
            source: RecordedSource(samples: samples, sampleRate: sampleRate), owner: self)
        attach(audio)
        return audio
    }
}
