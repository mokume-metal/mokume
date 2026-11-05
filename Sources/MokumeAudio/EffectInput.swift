// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// エフェクトに入力できる音。``SoundEffect/process(_:)`` などの引数の型で、合成音 (``SynthSound``)
/// と音声ファイル (``SoundFile``) が準拠する。
///
/// Processing Sound の `SoundObject` (`LowPass.process(input)` の引数の型) に当たる。ただし**対象が
/// 違う** — Processing Sound では `AudioIn` (マイク) も `SoundObject` を継承するが、mokume では ``AudioIn`` を
/// エフェクトに通せない (マイクの音をスピーカーへ出力する API が無い)。名前を揃えると同じ名前で対象が
/// 違うことになるので、役割を表す名前にした。
///
/// ```swift
/// final class Muffled: Sketch {
///     var song: SoundFile?
///     var filter: LowPass?
///     func setup() throws {
///         song = try loadSound("assets/song.wav")
///         filter = createLowPass()
///         if let song { filter?.process(song, 800) }
///         song?.loop()
///     }
/// }
/// ```
///
/// **準拠できるのは ``SynthSound`` と ``SoundFile`` だけ** (このモジュールの型)。それ以外の型を
/// 渡しても処理されず、``SoundEffect/process(_:)`` が 1 度だけ警告する。要件を持たないのは、音源を
/// エフェクトへ渡す処理がモジュール内部の型でしか書けないため。
///
/// 解析値 (``AudioIn/level`` と同じ名前のプロパティ) を共通化する型ではない。マイクを含めて音源に共通の解析用の
/// 型が要るときは、このプロトコルとは別に作る。
public protocol EffectInput: AnyObject {}
