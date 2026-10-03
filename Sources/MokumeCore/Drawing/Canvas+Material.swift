// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 表面の質感を決める。式と寿命は ``Material`` と [ADR-0021] 決定 4 が定める。
//
// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
extension Canvas {

    // 艶の鋭さ。0 なら艶を出さない。
    public func shininess(_ amount: some ScalarConvertible) {
        // フレームの外の断りを、範囲の外の断りより先に言う (``refuseMaterialColor(_:)``)
        guard admits(.material) else { return }
        let amount = amount.asFloat
        guard amount.isFinite, amount >= 0 else { return warnBadMaterial("shininess") }
        apply { $0.shininess = amount }
    }

    // 金属らしさ。0 が非金属、1 が金属。
    public func metalness(_ amount: some ScalarConvertible) {
        guard admits(.material) else { return }
        let amount = amount.asFloat
        guard amount.isFinite, amount >= 0, amount <= 1 else {
            return warnBadMaterial("metalness")
        }
        apply { $0.metalness = amount }
    }

    // 周りの光をどれだけ返すか。
    public func ambient(_ color: LinearRGBA) {
        // 数でない成分・無限の成分は数の形と同じ鍵で断り、負の成分は範囲の外として断る (#1706)。
        // 不透明度は材質に持ち込まないので見ない
        guard color.hasFiniteRGB else { return refuseMaterialColor(.ambient) }
        guard admits(.material) else { return }
        guard let components = Self.materialComponents(color) else {
            return warnBadMaterial("ambient")
        }
        apply { $0.ambient = components }
    }

    // 自ら出す光。
    public func emissive(_ color: LinearRGBA) {
        guard color.hasFiniteRGB else { return refuseMaterialColor(.emissive) }
        guard admits(.material) else { return }
        guard let components = Self.materialComponents(color) else {
            return warnBadMaterial("emissive")
        }
        apply { $0.emissive = components }
    }

    /// 受け取れない材質の色を断る。**フレームの外の断りを先に言う** ([#1706] の反証 2)。
    ///
    /// 数の形 (`ambient(r, g, b)`) も色の値の形も、ここで同じ順に断る。光の
    /// ``refuseLightColor(_:)`` と同じ順で、置かない呼び出しのために色の鍵を使い切らない。
    /// 範囲の外の量 (負の成分・`shininess` / `metalness` の範囲の外) も、フレームの外の後に断る。
    ///
    /// [#1706]: https://github.com/mokume-metal/mokume/issues/1706
    func refuseMaterialColor(_ entry: ColorEntry) {
        guard admits(.material) else { return }
        warnNotANumberColor(entry)
    }

    /// 材質を書き換える。**列をその場で閉じる**ので、既に置いた立体は置いた時点の
    /// 材質で描かれる ([ADR-0021] 決定 2 の「記録した列だけで絵が決まる」)。
    ///
    /// フレームの外 (初期化のとき) に書かれた材質は、どのフレームにも属さないので
    /// 警告して無視する (同 決定 4)。光・視点と同じ扱いである。呼ぶ口は値を検める前に
    /// 同じ断りを言う (``refuseMaterialColor(_:)``) ので、ここで言うことは無い守りである。
    private func apply(_ change: (inout Material) -> Void) {
        guard admits(.material) else { return }
        closeBatch()
        change(&style.material)
    }

    /// 材質へ渡された色から、足し引きに使う 3 成分を取り出す。
    ///
    /// 光と同じくアルファは持ち込まない (乗算済みの成分をそのまま使う)。負の成分は
    /// 光を吸う値になり、式のどこにも意味を持たないので受け取らない。
    private static func materialComponents(_ color: LinearRGBA) -> SIMD3<Float>? {
        // **有限かは成分ごとに先に見る** (``LinearRGBA/hasFiniteRGB``)。SIMD の min は数でない
        // 成分を飛ばすので、有限と分かった後でだけまとめて見てよい
        guard color.hasFiniteRGB else { return nil }
        let components = SIMD3(color.red, color.green, color.blue)
        guard components.min() >= 0 else { return nil }
        return components
    }

    /// 受け取れない値を、初回だけ知らせる。
    private func warnBadMaterial(_ name: String) {
        warnOnce(
            .badMaterial,
            "\(name)(): got a value that is not a number, or an infinite one, or one outside the range, so the material was left as it was")
    }
}
