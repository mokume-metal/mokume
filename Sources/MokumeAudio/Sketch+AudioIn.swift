// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeCore

// 音の入力。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// 呼べば使える標準の機能である ([ADR-0042] 決定 1)。`plugins` には何も書かない —
// 作る口が、走っているスケッチへ自分で入り口を足す (``SketchPart/attach(_:)-(Inlet)``)。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
extension Sketch {

    /// マイク (音声入力デバイス) を開く。音を解析した値は ``AudioIn`` から読む。
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
    /// - **呼んだときに初めてデバイスを開く。** `import mokume` しただけでマイクが開いたり、許可の
    ///   ダイアログが出たりはしない
    /// - チャンネルが複数あれば、平均して 1 チャンネルにしてから解析する
    /// - **デバイスが無くても作れる。** ``AudioIn/state`` が ``SourceState/unavailable`` になり、
    ///   接続されたら開始する。選んだデバイスが切断されたら ``SourceState/disconnected`` になり、再接続すれば戻る
    /// - 初めて使うときは OS が許可を求める。アプリにバンドルせずに実行している間は、許可はスケッチを
    ///   起動したターミナルのアプリに付く。バンドルするときは `mokume-app.json` に `microphoneUsage` を書く
    ///
    /// `setup()`・`draw()`・入力のコールバックの中で呼ぶ。それ以外 (初期化子の中・終了処理の後・`Task` の中) で
    /// 呼ぶと、デバイスを開かずに何も受け取らない入力を返し、この関数の名前を添えて 1 度だけ警告する。
    ///
    /// - Parameter device: 使うデバイス (``audioInputDevices()`` から選ぶ)。省略すると既定の入力。
    public func createAudioIn(device: AudioDevice? = nil) -> AudioIn {
        let audio = AudioIn(
            device: device, name: device.map { "microphone: \($0.name)" } ?? "microphone",
            source: MicrophoneSource(device: device), owner: self)
        attach(audio, calledAs: #function, returning: "an input that never hears anything")
        return audio
    }

    /// 音声ファイルを、マイクの代わりに解析する。**再生しない。デバイスも許可も使わない。**
    ///
    /// <!-- example: 文脈 var song: AudioIn? -->
    /// ```swift
    /// func setup() throws {
    ///     song = try createAudioIn(file: "assets/song.wav")
    /// }
    /// func draw() {
    ///     background(0)
    ///     if let song { circle(width / 2, height / 2, 40 + song.level * 300) }
    /// }
    /// ```
    ///
    /// 各フレームでは、前のフレームの時刻からそのフレームの時刻までに進んだ区間のサンプルをすべて解析する
    /// (値の意味は ``AudioIn`` と同じ)。末尾まで進むと先頭へ戻る。**どの区間を解析するかはフレームの
    /// 時刻だけで決まる**ので、固定クロックで書き出すと、何度書き出しても同じフレームが同じ値を受け取る
    /// ([ADR-0028] 決定 7)。**外して追加し直しても、解析する区間はフレームの時刻だけで決まる** (外していた間のサンプルは届かず、
    /// 追加し直した後のフレームは、外さずに実行したときと同じ区間を解析する。時刻どおりに進む・[#3152](https://github.com/mokume-metal/mokume/issues/3152))。開いた最初のフレームと、時間を止めている間 (``SketchPart/pauseTime()``) は
    /// サンプルが進まないので、何も届かず (``AudioIn/isNewFrame`` が false)、値は前のまま (最初は無音)。
    /// 時刻を指定した `observe` のフレームは、その秒で終わる 1 フレームぶんの区間の値を返す (撮るフレームと同じ時刻の音)。`observe` のフレームの後の
    /// 通常のフレームは、`observe` が無かったときと同じ値になる。
    /// マイクを使うスケッチを、デバイスの無い環境で確かめるときにも使う。
    ///
    /// 探す場所は ``SketchPart/loadImage(_:)`` と同じ (``SketchPart/assetURL(_:)``)。読み込みは作成時に 1 度だけで、
    /// 全体をサンプル列としてメモリに持つ。
    ///
    /// - Parameter file: 音声ファイルの名前。macOS が読める形式 (WAV・AIFF・CAF・MP3・
    ///   AAC/M4A・FLAC など。動画のコンテナ (`.mov`・`.mp4`) は音声トラックを読む)。
    /// - Throws: 見つからない・見つかったが開けない (ディレクトリだった・読み取り権限が無い。解決した場所が入る
    ///   ``AudioFailure/unopenable(path:location:reason:)``)・音声として読めない・サンプルが 1 つも無いとき。
    ///   `setup()`・`draw()`・入力のコールバックの外 (初期化子の中・終了処理の後・`Task` の中) で呼ぶと、
    ///   ファイルを読む前に ``AudioFailure/notRunning(call:)`` を投げる (プロセスはクラッシュしない)。
    ///
    /// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
    public func createAudioIn(file: String) throws(AudioFailure) -> AudioIn {
        return try attached(AudioFailure.self, calledAs: #function) { () throws(AudioFailure) -> AudioIn in
            let decoded = try AudioFile.read(audioURL(file), path: file)
            return recordedAudioIn(
                samples: decoded.samples, sampleRate: decoded.sampleRate, name: "audio file: \(file)")
        }
    }

    /// 用意したサンプル列を、マイクの代わりに解析する。**再生しない。デバイスも許可も使わない。**
    ///
    /// ```swift
    /// final class Beat: Sketch {
    ///     var beat: AudioIn?
    ///     func setup() throws {
    ///         // 440 Hz の音を、1 秒に 2 回大きくする
    ///         let samples = (0..<48_000).map { index -> Float in
    ///             let t = Float(index) / 48_000
    ///             return sin(2 * .pi * 440 * t) * (0.5 + 0.5 * cos(2 * .pi * 2 * t))
    ///         }
    ///         beat = try createAudioIn(samples: samples, sampleRate: 48_000)
    ///     }
    ///     func draw() {
    ///         background(0)
    ///         if let beat { circle(width / 2, height / 2, 40 + beat.level * 300) }
    ///     }
    /// }
    /// ```
    ///
    /// 解析する区間の決まり方は ``createAudioIn(file:)`` と同じで (外して追加し直したときも)、末尾まで進むと先頭へ戻る。
    ///
    /// - Parameters:
    ///   - samples: サンプル (-1〜1 がフルスケール)。1 チャンネル。
    ///   - sampleRate: サンプルレート (1 秒あたりのサンプル数)。
    /// - Throws: サンプルが 1 つも無いか、サンプルレートが正でないとき。使えるサンプル列を `setup()`・`draw()`・入力の
    ///   コールバックの外 (初期化子の中・終了処理の後・`Task` の中) で渡すと ``AudioFailure/notRunning(call:)`` を投げる
    ///   (プロセスはクラッシュしない)。
    public func createAudioIn(samples: [Float], sampleRate: Float) throws(AudioFailure) -> AudioIn {
        guard !samples.isEmpty else { throw .empty }
        guard sampleRate > 0, sampleRate.isFinite else { throw .invalidSampleRate(sampleRate) }
        return try attached(AudioFailure.self, calledAs: #function) {
            recordedAudioIn(samples: samples, sampleRate: sampleRate, name: "audio (samples)")
        }
    }

    /// 接続されている音声入力デバイスの一覧。``createAudioIn(device:)`` で 1 つを選ぶのに使う。
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
            case .unreachable(let path, let location, let reason):
                throw .unopenable(
                    path: path, location: location, reason: AssetOpening.unreachableReason(reason))
            }
        }
    }

    /// 記録した標本から入り口を作る。足すのは呼ぶ側の ``attached(_:calledAs:making:)``。
    private func recordedAudioIn(samples: [Float], sampleRate: Float, name: String) -> AudioIn {
        AudioIn(
            device: nil, name: name,
            source: RecordedSource(samples: samples, sampleRate: sampleRate), owner: self)
    }
}
