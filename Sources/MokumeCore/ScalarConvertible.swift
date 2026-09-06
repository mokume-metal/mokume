// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 描画へ渡せる数。`Float`・`Double`・`Int` のどれで持っていても渡せる。
///
/// **受け口だけを広げ、中は `Float` のまま持つ** ([ADR-0035])。Metal のシェーダに
/// `double` は無いので、どの型で受けても GPU の手前で 32 bit になる — 面を `Double` に
/// すると変換が消えるのではなく、書き手のコードから GPU 境界へ移り、回数が「1 行 1 回」から
/// 「毎フレーム全頂点」に増える。
///
/// **費用は測ってある** ([#976])。別のパッケージから release で呼んで 1 回あたり約 0.8 ns
/// (2〜3 クロック) で、`circle` 本体の 60〜70 ns に対して 1% 台である。ジェネリックは
/// 呼ぶ側で特殊化されるので、`Float` を直に受けるのと同じ機械語に落ちる。
///
/// **オーバーロードではないが、リテラルの書き方は結果を変える。** [ADR-0033] 決定 1 は
/// 「`Int` と `Float` の口を並べると、どちらが呼ばれるかで目盛りが変わる」罠を避けた。
/// ここはどの型を渡しても同じ 1 本が呼ばれるので**その**罠は起きないが、呼ばれる関数が
/// 1 本でも**渡る値**は変わりうる ([#1018])。
///
/// ```swift
/// circle(width / 2, height / 2, 1 / 2)   // 直径に 0 が渡る。何も描かれない
/// circle(width / 2, height / 2, 1 / 2.0) // 0.5 が渡る
/// ```
///
/// 総称の引数では、渡す式の型を引数のほうが決めてくれない。整数リテラルだけで書かれた
/// 式には**リテラルの既定型 (`Int`) が付く**ので、割り算が整数除算になる。
/// **割り算を含む式は、片方を `Float` で書く。**
///
/// 同じ理由で、暗黙メンバ参照は解決しない — `rotate(.pi / 2)` ではなく
/// `rotate(Float.pi / 2)` と綴る ([ADR-0035] 決定 6)。
///
/// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
/// [ADR-0035]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0035-numeric-reception.md
/// [#976]: https://github.com/mokume-metal/mokume/issues/976
/// [#1018]: https://github.com/mokume-metal/mokume/issues/1018
public protocol ScalarConvertible {
    /// 描画へ渡す幅 (32 bit)。
    var asFloat: Float { get }
}

extension Float: ScalarConvertible {
    @inlinable public var asFloat: Float { self }
}

extension Double: ScalarConvertible {
    @inlinable public var asFloat: Float { Float(self) }
}

extension Int: ScalarConvertible {
    @inlinable public var asFloat: Float { Float(self) }
}
