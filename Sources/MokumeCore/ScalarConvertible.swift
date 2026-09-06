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
/// **オーバーロードではない。** [ADR-0033] 決定 1 は「`Int` と `Float` の口を並べると
/// リテラルの書き方で目盛りが変わる」罠を避けたが、ここはどの型を渡しても同じ 1 本が
/// 呼ばれるので、その罠は起きない。
///
/// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
/// [ADR-0035]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0035-numeric-reception.md
/// [#976]: https://github.com/mokume-metal/mokume/issues/976
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
