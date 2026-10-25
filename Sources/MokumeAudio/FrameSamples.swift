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

    /// 作者の時計が指すフレームの位置 `frames` (固定の時計の秒 × fps。止める・飛ぶで整数でなくなる) の頭の標本の位置。
    ///
    /// 止めも飛びもしない間は、位置がフレームの番号と等しく、``start(ofFrame:perSecond:sampleRate:)`` と 1 標本も
    /// 違わない — 秒に fps を掛けた位置の浮動小数のずれ (4.999999…) は、標本の位置が整数になるところで取り除く。
    /// 止めた間は同じ位置が続き、フレームの途中へ飛んだ後は、その端数のまま進む。
    static func start(ofPosition frames: Double, perSecond: Int, sampleRate: Double) -> Int {
        // 割り切れるはずのところ (整数のフレーム、または 0.125 フレームなど正確に表せる位置) の浮動小数のずれは、
        // 整数の標本へ寄せる。割り切れないときの小数部は 1/fps の倍数で、1e-6 より十分に大きい
        let position = frames * sampleRate / Double(perSecond)
        let snapped = position.rounded()
        return Int((abs(position - snapped) < 1e-6 ? snapped : position).rounded(.down))
    }

    /// 位置 `origin` の頭から、位置 `frames` の頭までの標本の数 (どちらも作者の時計の位置・フレーム数)。
    static func count(
        fromPosition origin: Double, toPosition frames: Double, perSecond: Int, sampleRate: Double
    ) -> Int {
        start(ofPosition: frames, perSecond: perSecond, sampleRate: sampleRate)
            - start(ofPosition: origin, perSecond: perSecond, sampleRate: sampleRate)
    }
}
