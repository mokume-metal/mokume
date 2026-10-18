// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 断片の入口。組めなかった理由を、期待する入口の形で言い直す ([#2782])。
///
/// ## 塗りと効果: 前置きが呼ぶ記号で照合する
///
/// 塗りと効果の前置きは入口 (`paint`・`effect`) を宣言して呼ぶだけで、定義は断片が書く。名前や
/// 引数を書き違えると組み立ては通り、リンクの段で `Undefined symbol(s)` と内部の記号の名前
/// (`'_Z5paint8Fragment6Values'`) で落ちる。この理由は書いた断片のどこも指さないので、失敗の説明が
/// 言う「理由が指す所を、書いた断片の中で直せ」が成り立たない。
///
/// **入口の形は記号の名前で一意に決まる**ので、理由の中にその記号が未定義と出たら、期待する形を
/// 1 行で先頭に足す。Metal の文面は消さずに下へ残す。照合するのは引用符つきの記号である —
/// 2 引数の記号は 3 引数の記号の頭と同じ綴りで、`referenced from:` の下にも入口の記号が引用符なしで
/// 並ぶ (入口から呼んだ別の関数が未定義のとき)。
///
/// 断片の本文から入口を探す形は採らない。コメント・`#if`・マクロで見誤る (#2782 の決定)。
///
/// ## 計算: 組んだライブラリに入口があるかを見る
///
/// 計算の入口は利用者が `kernel void <name>(…)` で書く。名前が合わないとライブラリは組み上がり、
/// パイプラインの作成で Metal が assert でプロセスごと落とす (`computeFunction must not be nil`)
/// ので、言い直す文面が無い。だからパイプラインを作る前に、ライブラリにその名前の `kernel` 関数が
/// あるかを見て断る (``ComputePipeline/StateJob``)。
///
/// ## 言い直しの行の形
///
/// **`<断片の名前>: error: …` の形にする。** 組み立ての誤りの行 (`shader:2:12: error: …`) と同じ形
/// なので、理由から最初の `error:` の行を拾う読み手 ([#2784]) は、前置きの警告や Metal の
/// `Undefined symbol(s)` ではなくこの行を拾う。
///
/// [#2782]: https://github.com/mokume-metal/mokume/issues/2782
/// [#2784]: https://github.com/mokume-metal/mokume/issues/2784
nonisolated struct ShaderEntryPoint: Sendable {
    /// 前置きが呼ぶ記号の名前。
    let symbol: String
    /// 断片に書く形。
    let signature: String
    /// 形を言った後に足す、直し方の手がかり (文の頭の `. ` から)。
    let hint: String
    /// この入口の断片で、`unknown type name '<型>'` と出たら入口の取り違えと読む型と、その言い直し。
    /// 面を渡さない塗りの `Surfaces` だけが持つ。
    let missingType: (name: String, restatement: String)?

    /// 塗りの入口。**`surfaces:` の有無で引数の数が変わる** (前置きの `#ifdef MOKUME_SURFACES`)。
    static func paint(surfaces: Bool) -> Self {
        let twoArguments = "float4 paint(Fragment in, Values values)"
        if surfaces {
            return Self(
                symbol: "_Z5paint8Fragment6Values8Surfaces",
                signature: "float4 paint(Fragment in, Values values, Surfaces surfaces)",
                hint: ". It was made with surfaces:, so paint takes them as its third parameter",
                missingType: nil)
        }
        return Self(
            symbol: "_Z5paint8Fragment6Values",
            signature: twoArguments,
            hint: ". Check its name and parameters (only a fragment made with surfaces: takes "
                + "Surfaces surfaces as the third)",
            // 面を渡さなければ `Surfaces` の型そのものが無いので、3 引数で書くとリンクの前の
            // 組み立てで落ちる
            missingType: (
                "Surfaces",
                "Surfaces exists only in a fragment made with surfaces:, so without them the entry "
                    + "point is \(twoArguments)"
            ))
    }

    /// 効果の入口。
    static let effect = Self(
        symbol: "_Z6effect5Pixel6Values",
        signature: "float4 effect(Pixel in, Values values)",
        hint: ". Check its name and parameters",
        missingType: nil)

    /// 理由を、言い直しの 1 行を先頭に足した形で返す。入口の取り違えと読めなければそのまま返す。
    ///
    /// - Parameter fragment: 断片が名乗る名前 (``ShaderSource/bodyName(_:url:)``)。`name:` は利用者が
    ///   何でも書けるので、改行と制御文字は空白にして 1 行を割らない (``ShaderSource/oneLine(_:)``)。
    func restating(_ reason: String, in fragment: String) -> String {
        guard let line = restatement(of: reason, in: ShaderSource.oneLine(fragment)) else { return reason }
        return "\(line)\n\(reason)"
    }

    private func restatement(of reason: String, in fragment: String) -> String? {
        if reason.contains("Undefined symbol"), reason.contains("'\(symbol)'") {
            return "\(fragment): error: the fragment does not define its entry point \(signature)\(hint)"
        }
        if let missingType, reason.contains("error: unknown type name '\(missingType.name)'") {
            return "\(fragment): error: \(missingType.restatement)"
        }
        return nil
    }

    /// 計算の入口の関数が、組んだライブラリに無いときの言い直し。
    static func missingKernel(named name: String, in fragment: String) -> String {
        "\(ShaderSource.oneLine(fragment)): error: the fragment does not define its entry point kernel void \(name)(…). "
            + "A computation runs the kernel function named after it (its name:, or the file name "
            + "for a file)"
    }
}
