// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// エフェクトに通せる音。``SoundEffect/process(_:)`` ほかの引数の型で、合成した音 (``SynthSound``)
/// と音声ファイル (``SoundFile``) が準拠する。
///
/// Processing Sound の `SoundObject` (`LowPass.process(input)` の引数の型) に当たる。ただし**範囲が
/// 違う** — あちらでは `AudioIn` (マイク) も `SoundObject` を継ぐが、mokume では ``AudioIn`` を
/// エフェクトに通せない (マイクの音をスピーカーへ出す口が無い)。名前を揃えると同じ名前で範囲が
/// 違うことになるので、役目を名乗る名前にした。
///
/// ```swift
/// final class Muffled: Sketch {
///     var song: SoundFile?
///     var filter: LowPass?
///     func setup() {
///         song = try? loadSound("assets/song.wav")
///         filter = createLowPass()
///         if let song { filter?.process(song, 800) }
///         song?.loop()
///     }
/// }
/// ```
///
/// **準拠できるのは ``SynthSound`` と ``SoundFile`` だけ** (このモジュールの型)。それ以外の型を
/// 渡しても通らず、``SoundEffect/process(_:)`` が 1 度だけ知らせる。要件を持たないのは、音の側へ
/// 渡す手続きがモジュールの中の型にしか書けないため。
///
/// 解析の値 (``AudioIn/level`` と同じ名前) を共通にする型ではない。マイクを含めて音源に共通の解析の
/// 型が要るときは、この protocol とは別に作る。
public protocol EffectInput: AnyObject {}
