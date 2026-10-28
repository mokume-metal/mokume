// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

/// 検査の対象を作る口 (絵・描き場所・粒・断片・モデル) を、throw できない場所から呼ぶ補助 (#3345)。
///
/// `Canvas.draw` の閉包や `Sketch.setup()` は throw できない。そこで `try?` で作って
/// `guard let ... else { return }` で抜けると、**作る口が壊れても、検査は何も見ずに緑で終わる**。
/// 作れなかったときに失敗を記録して nil を返せば、呼び手はこれまでどおり抜けられ、
/// 抜けた検査は記録した失敗で赤になる。
///
/// GPU の門 (`RenderDevice.isAvailable`) を通った検査で作れないのは環境ではなく本体の退行なので、
/// 理由つきの skip ではなく赤にする。
///
/// 引数は `@autoclosure` にしない。`creating(try ...)` と書くと、外側の閉包が throw すると推論されて、
/// 描画の閉包 (`() -> Void`) へ渡せなくなる。
///
/// ```swift
/// guard let image = creating({ try canvas.createImage(8, 8) }) else { return }
/// ```
func creating<Made>(
    _ make: () throws -> Made,
    sourceLocation: SourceLocation = #_sourceLocation
) -> Made? {
    do {
        return try make()
    } catch {
        Issue.record("検査の対象を作れなかった: \(error)", sourceLocation: sourceLocation)
        return nil
    }
}
