// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation
import MokumeCore

// 音声ファイルの再生。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// 手本は p5.sound の `loadSound()` と、Processing Sound / p5.sound の `SoundFile` である
// ([ADR-0020] 決定 1)。呼べば使える標準の機能で ([ADR-0042] 決定 1)、`plugins` には何も書かない。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
extension Sketch {

    /// 音声ファイルを読み込み、再生できる状態にする。再生が始まるのは ``SoundFile/play()`` か
    /// ``SoundFile/loop()`` を呼んでから。
    ///
    /// <!-- example: 文脈 var song: SoundFile? -->
    /// ```swift
    /// func setup() throws {
    ///     song = try loadSound("assets/song.wav")
    ///     song?.loop()
    /// }
    /// func draw() {
    ///     background(0)
    ///     guard let song else { return }
    ///     // 鳴っている音の、低い帯域から 64 本の大きさで棒を伸ばす
    ///     for band in 1...64 {
    ///         let length = song.spectrumLevels[band] * 300
    ///         rect(Float(band) * 10, height - length, 8, length)
    ///     }
    /// }
    /// ```
    ///
    /// 再生中は、``SoundFile`` から現在再生している音を解析した値を読める (値の名前は
    /// ``AudioIn`` と同じ)。書き出し (`mokume render`) ではデバイスへ出力せず、フレーム数から決めた
    /// 位置の音を解析するので、何度書き出しても同じ絵になる。固定クロックで `.mov` へ書き出すと、再生した音は
    /// 動画の音声トラックに入る (``SoundFile``)。
    ///
    /// 探す場所は ``SketchPart/loadImage(_:)`` と同じ (``SketchPart/assetURL(_:)``)。読み込みは作成時に 1 度だけで、
    /// 解析に使うサンプルは全体をメモリに持つ。外している間は、再生用のデータ (左右などチャンネルごとのサンプル) を持たない
    /// ので、``SketchPart/detach(_:)-(Inlet)`` で外した ``SoundFile`` を追加し直してウィンドウで再生するときだけ、
    /// 再生用のデータをファイルからもう 1 度読む。この読み込みは `draw()` をブロックする同期処理で、`draw()` の中で
    /// 起きれば 1 度だけ警告する。読み直せなければ (ファイルが消えた・別のファイルに置き換わったなど)、音を出さずに
    /// 実時間で再生位置を進め、そのことを 1 度だけ警告する。呼んだだけでは再生されず、許可も要らない。
    ///
    /// `setup()`・`draw()`・入力のコールバックの中で呼ぶ。
    ///
    /// - Parameter file: 音声ファイルの名前。macOS が読める形式 (WAV・AIFF・CAF・MP3・
    ///   AAC/M4A・FLAC など)。**動画のコンテナ (`.mov`・`.mp4`) からも、音声トラックを読める** — 同じファイルを
    ///   `Movie` で表示し、ここで再生する (`Movie` は音を再生しない。同期の取り方は `Movie` の説明の「音」)。音声トラックが
    ///   複数あれば 1 本目を読み、音声トラックの無い動画 (macOS が音声として開けないコーデックのものも) は
    ///   ``AudioFailure/unreadable(path:)`` を投げる。
    /// - Throws: 見つからない・見つかったが開けない (ディレクトリだった・読み取り権限が無い。解決した場所が入る
    ///   ``AudioFailure/unopenable(path:location:reason:)``)・音声として読めない (壊れている・対応して
    ///   いない形式。動画なら、音声トラックが無い・開けないコーデックのとき)・サンプルが 1 つも無いとき。**作成時だけ投げ**、再生・停止のメソッドは投げない
    ///   ([ADR-0020] 決定 5)。
    ///   `setup()`・`draw()`・入力のコールバックの外 (初期化子の中・終了処理の後・`Task` の中) で呼ぶと、
    ///   ファイルを読む前に ``AudioFailure/notRunning(call:)`` を投げる (プロセスはクラッシュしない)。`Task` の中で読むなら
    ///   (``SketchPart/selectInput(_:)`` で選んだファイルなど) ``requestSound(_:)`` を使う。`draw()` の中で呼ぶと、
    ///   フレームをブロックする読み込みとして 1 度だけ警告し、``requestSound(_:)`` を案内する。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func loadSound(_ file: String) throws(AudioFailure) -> SoundFile {
        Self.noticeBlockingLoad("loadSound(_:)", instead: "requestSound(_:)")
        return try loadSound(file, flow: nil)
    }

    /// 音声ファイルを、**読み込み中もフレームをブロックせずに**読み込み、再生できる状態にする。
    ///
    /// ``loadSound(_:)`` の、完了を待つ非同期版 (``SketchPart/requestImage(_:)`` などと同じ形)。`setup()` かコールバックの中で
    /// `Task` を生成し、そこから呼ぶ。**``SketchPart/selectInput(_:)`` で選んだファイルは、これで読む** — 選んだ結果は `Task`
    /// に届き、そこでは ``loadSound(_:)`` を使えない。
    ///
    /// <!-- example: 文脈 var song: SoundFile? -->
    /// ```swift
    /// func keyPressed() {
    ///     if key == "o" {
    ///         Task {
    ///             guard let path = await selectInput("音声を選ぶ") else { return }
    ///             guard let next = try? await requestSound(path) else { return }
    ///             // 選び直したときは、前の音を止めて外す
    ///             if let song {
    ///                 song.stop()
    ///                 detach(song)
    ///             }
    ///             song = next
    ///             next.loop()
    ///         }
    ///     }
    /// }
    /// func draw() {
    ///     background(0)
    ///     guard let song else { return }
    ///     for band in 1...64 {
    ///         let length = song.spectrumLevels[band] * 300
    ///         rect(Float(band) * 10, height - length, 8, length)
    ///     }
    /// }
    /// ```
    ///
    /// 返る ``SoundFile`` は、``loadSound(_:)`` が返すものと同じく、実行中のスケッチへ追加されている
    /// (``SoundFile/play()`` を呼べば再生され、解析値を読める)。ファイルの読み込みとサンプルのデコードは別のタスクで行い、
    /// スケッチへの追加は**フレームの開始時点**に行う。そのため、`noLoop()` で止めている間も待ちは完了する。
    ///
    /// 探す場所・読める形式・投げるエラーは ``loadSound(_:)`` と同じ (``AudioFailure`` に case は追加しない)。
    ///
    /// > Note: 完了するフレームは、ファイルの大きさとフレームの間隔で変わる。何フレーム目で返るかは、
    /// > 現在の挙動であって保証ではない ([#2760])。呼んだ `Task` をキャンセルしても、読み込みは止まらず、
    /// > 読み終えればスケッチへ追加される (キャンセルをこの関数に伝えるかは未定)。不要なら、返った後に外す。
    /// > この関数専用のスクリーンショットは用意していない (音は画面に出ず、読み込む場所が違うだけで ``loadSound(_:)`` と同じ)。
    ///
    /// - Parameter file: 音声ファイルの名前。``loadSound(_:)`` と同じ。
    /// - Throws: ``loadSound(_:)`` と同じ (``AudioFailure``)。
    ///   実行中のスケッチの中で生成した `Task` 以外 (初期化子の中・終了処理の後・`Task.detached`) で
    ///   呼ぶと、ファイルを読む前に ``AudioFailure/notRunning(call:)`` を投げる (プロセスはクラッシュしない)。待っている最中に
    ///   スケッチが終了したときも同じ。
    ///
    /// [#2760]: https://github.com/mokume-metal/mokume/issues/2760
    // shot: 参照 loadSound(_:)
    public func requestSound(_ file: String) async throws(AudioFailure) -> SoundFile {
        try await requestSound(file, flow: nil)
    }

    /// 鳴らす流れを差し替えられる入口 (検査用)。`flow` を渡すと、時計によらずその流れで鳴らす。
    func requestSound(_ file: String, flow: SoundFlow?) async throws(AudioFailure) -> SoundFile {
        // 頼める所かを、ファイルを読む前に確かめる (#2740・#3398)。名乗るのは利用者が呼ぶ口
        try await attachedWaiting(
            AudioFailure.self, calledAs: "requestSound(_:)"
        ) { () async throws(AudioFailure) -> SoundFile in
            let url = try audioURL(file)
            // 読み・標本を解くのは裏で行う。main actor に戻って作るのは、`SoundFile` だけ
            let read: ReadSound
            do {
                read = try await Task.detached(priority: .utility) {
                    let buffer = try AudioFile.load(url, path: file)
                    return ReadSound(buffer: buffer, samples: AudioFile.mono(buffer))
                }.value
            } catch let failure as AudioFailure {
                throw failure
            } catch {
                throw .unreadable(path: file)
            }
            return SoundFile(
                name: file, buffer: read.buffer, owner: self, flow: flow, source: url, decodedSamples: read.samples)
        }
    }

    /// 鳴らす流れを差し替えられる入口 (検査用)。`flow` を渡すと、時計によらずその流れで鳴らす。
    func loadSound(_ file: String, flow: SoundFlow?) throws(AudioFailure) -> SoundFile {
        // 足せない所なら、ファイルを読む前に断る (#2740)。名乗るのは利用者が呼ぶ口
        return try attached(AudioFailure.self, calledAs: "loadSound(_:)") { () throws(AudioFailure) -> SoundFile in
            let url = try audioURL(file)
            let buffer = try AudioFile.load(url, path: file)
            return SoundFile(name: file, buffer: buffer, owner: self, flow: flow, source: url)
        }
    }
}

/// 裏で読んだ音声。**作った `Task` の外へ 1 度だけ渡し、渡した後は裏では触らない。** `AVAudioPCMBuffer` は
/// `Sendable` でないが、受け取る側 (main actor) だけが持つので、そのまま運んでよい。
private nonisolated struct ReadSound: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let samples: [Float]
}
