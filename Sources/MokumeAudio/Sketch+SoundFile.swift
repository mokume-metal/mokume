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

    /// 音声ファイルを読み、鳴らせる形にする。鳴らすのは ``SoundFile/play()`` か
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
    /// 鳴っている間、``SoundFile`` からいま鳴っている音を解析した値が読める (値の名前は
    /// ``AudioIn`` と同じ)。書き出し (`mokume render`) では機材に鳴らさず、フレームの数から決めた
    /// 位置の音を解析するので、何度書き出しても同じ絵になる。固定の時計で `.mov` へ書き出すと、鳴った音は
    /// 動画の音声トラックに載る (``SoundFile``)。
    ///
    /// 探す場所は ``SketchPart/loadImage(_:)`` と同じ (``SketchPart/assetURL(_:)``)。読み込みは作るときに 1 度だけで、
    /// 解析に使う標本は全体を手元に持つ。外している間は、鳴らす分 (左右などチャンネルごとの標本) を持たない
    /// ので、``SketchPart/detach(_:)-(Inlet)`` で外した ``SoundFile`` を足し直して窓に出して鳴らすときだけ、
    /// 鳴らす分をファイルからもう 1 度読む。この読み込みは `draw()` を止める同期のもので、`draw()` の中で
    /// 起きれば 1 度だけ知らせる。読み直せなければ (ファイルが消えた・別のものに替わったなど)、鳴らさずに
    /// 実時間で位置を進め、そのことを 1 度だけ知らせる。呼んだだけでは鳴らず、許可も要らない。
    ///
    /// `setup()`・`draw()`・入力のコールバックの中で呼ぶ。
    ///
    /// - Parameter file: 音声ファイルの名前。macOS が読める形式 (WAV・AIFF・CAF・MP3・
    ///   AAC/M4A・FLAC など)。
    /// - Throws: 見つからない・見つかったが開けない (ディレクトリだった・読む権利が無い。解けた場所が載る
    ///   ``AudioFailure/unopenable(path:location:reason:)``)・音声として読めない (壊れている・対応して
    ///   いない形式)・標本が 1 つも無いとき。**作るときだけ投げ**、鳴らす・止める口は投げない
    ///   ([ADR-0020] 決定 5)。
    ///   `setup()`・`draw()`・入力のコールバックの外 (初期化子の中・後片付けの後・`Task` の中) で呼ぶと、
    ///   ファイルを読む前に ``AudioFailure/notRunning(call:)`` (プロセスは落ちない)。`Task` の中で読むなら
    ///   (``SketchPart/selectInput(_:)`` で選んだファイルなど) ``requestSound(_:)`` を使う。`draw()` の中で呼ぶと、
    ///   フレームを止める読み込みとして 1 度だけ知らせ、``requestSound(_:)`` へ案内する。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func loadSound(_ file: String) throws(AudioFailure) -> SoundFile {
        Self.noticeBlockingLoad("loadSound(_:)", instead: "requestSound(_:)")
        return try loadSound(file, flow: nil)
    }

    /// 音声ファイルを、**読んでいる間フレームを止めずに**読み、鳴らせる形にする。
    ///
    /// ``loadSound(_:)`` の、待つ読み込みの口 (``SketchPart/requestImage(_:)`` などと同じ形)。`setup()` かコールバックの中で
    /// `Task` を起こし、そこから呼ぶ。**``SketchPart/selectInput(_:)`` で選んだファイルは、ここで読む** — 選んだ結果は `Task`
    /// に届き、そこでは ``loadSound(_:)`` が読めない。
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
    /// 返る ``SoundFile`` は、``loadSound(_:)`` が返すものと同じく、走っているスケッチへ足されている
    /// (``SoundFile/play()`` を呼べば鳴り、解析の値が読める)。ファイルを読んで標本を解くのは別の仕事で行い、
    /// スケッチへ足すのは**フレームの頭**に行う。そのため、`noLoop()` で止めている間も待ちは終わる。
    ///
    /// 探す場所・読める形式・投げる失敗は ``loadSound(_:)`` と同じ (``AudioFailure`` に case は足さない)。
    ///
    /// > Note: 届くフレームは、ファイルの大きさとフレームの間隔で変わる。何枚目のフレームで返るかは、
    /// > いまの振る舞いであって約束ではない ([#2760])。呼んだ `Task` を取り消しても、読み込みは止まらず、
    /// > 読み終えればスケッチへ足される (取り消しを口に伝えるかは決めていない)。要らなければ、返った後に外す。
    /// > この口だけの絵は撮っていない (鳴る音は絵に出ず、読む場所が違うだけで ``loadSound(_:)`` と同じ)。
    ///
    /// - Parameter file: 音声ファイルの名前。``loadSound(_:)`` と同じ。
    /// - Throws: ``loadSound(_:)`` と同じ (``AudioFailure``)。
    ///   走っている実行の中で起こした `Task` から呼んでいない所 (初期化子の中・後片付けの後・`Task.detached`) で
    ///   呼ぶと、ファイルを読む前に ``AudioFailure/notRunning(call:)`` (プロセスは落ちない)。待っている最中に
    ///   スケッチが終わったときも同じ。
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
