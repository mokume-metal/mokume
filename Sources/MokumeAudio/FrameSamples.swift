// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 固定の時計 (フレームの数え方) で、フレームの番号から標本の位置を決める式。
///
/// [ADR-0042] 決定 6 の改訂の「時刻の対応」: **フレーム N は標本 `[⌊N·sr/fps⌋, ⌊(N+1)·sr/fps⌋)`**、原点は
/// 固定の時計のフレーム 0 の頭。窓の先頭はフレームの番号から直に求め、窓の長さを丸めて足さない。`sr` が
/// `fps` の倍数でないとき (48000 Hz・144 fps) は、窓ごとの長さが 1 標本ずつ違うだけで、継ぎ目に欠けも重なりも
/// 無い。
///
/// ``SoundFile`` と ``SynthStage`` の位置は、**鳴らし始めた (始めた) フレームからの差を、絶対のフレーム番号の
/// この式の差で数える**。`⌊(N − origin)·sr/fps⌋` のようにフレームの差から数えると、`origin` が窓の継ぎ目の
/// 途中にあるとき (`sr` が `fps` の倍数でないとき) に、窓の継ぎ目と最大 1 標本ずれて、絵が見る音と載せる音が
/// 同じ時刻を指さなくなる ([#3136] の条件 8・[#3125])。
///
/// [#3125]: https://github.com/mokume-metal/mokume/issues/3125
/// [#3136]: https://github.com/mokume-metal/mokume/issues/3136
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
nonisolated enum FrameSamples {
    /// フレーム `frame` の頭の標本の位置 `⌊frame·sampleRate/perSecond⌋` (固定の時計のフレーム 0 が標本 0)。
    static func start(ofFrame frame: Int, perSecond: Int, sampleRate: Double) -> Int {
        Int((Double(frame) * sampleRate / Double(perSecond)).rounded(.down))
    }

    /// フレーム `origin` の頭から、フレーム `frame` の頭までの標本の数。絶対の位置の差なので、`origin` がどこにあっても
    /// 窓の継ぎ目と揃う。
    static func count(
        from origin: Int, to frame: Int, perSecond: Int, sampleRate: Double
    ) -> Int {
        start(ofFrame: frame, perSecond: perSecond, sampleRate: sampleRate)
            - start(ofFrame: origin, perSecond: perSecond, sampleRate: sampleRate)
    }
}
