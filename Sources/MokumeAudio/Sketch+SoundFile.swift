// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

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
    /// func setup() {
    ///     song = try? loadSound("assets/song.wav")
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
    /// ``AudioIn`` と同じ)。書き出し (`mokume render`) では鳴らさず、フレームの数から決めた
    /// 位置の音を解析するので、何度書き出しても同じ絵になる。
    ///
    /// 探す場所は ``loadImage(_:)`` と同じ (``assetURL(_:)``)。読み込みは作るときに 1 度だけで、
    /// 全体を手元に持つ。呼んだだけでは鳴らず、許可も要らない。
    ///
    /// `setup()`・`draw()`・入力のコールバックの中で呼ぶ。
    ///
    /// - Parameter file: 音声ファイルの名前。macOS が読める形式 (WAV・AIFF・CAF・MP3・
    ///   AAC/M4A・FLAC など)。
    /// - Throws: 見つからない・音声として読めない (壊れている・対応していない形式)・標本が
    ///   1 つも無いとき。**作るときだけ投げ**、鳴らす・止める口は投げない ([ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func loadSound(_ file: String) throws(AudioFailure) -> SoundFile {
        try loadSound(file, flow: nil)
    }

    /// 鳴らす流れを差し替えられる入口 (検査用)。`flow` を渡すと、時計によらずその流れで鳴らす。
    func loadSound(_ file: String, flow: SoundFlow?) throws(AudioFailure) -> SoundFile {
        let buffer = try AudioFile.load(audioURL(file), path: file)
        let sound = SoundFile(name: file, buffer: buffer, owner: self, flow: flow)
        attach(sound)
        return sound
    }
}
