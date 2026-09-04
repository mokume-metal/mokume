// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 表面の質感を決める。式と寿命は ``Material`` と [ADR-0021] 決定 4 が定める。
//
// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
extension Canvas {

    // 艶の鋭さ。0 なら艶を出さない。
    public func shininess(_ amount: Float) {
        guard amount.isFinite, amount >= 0 else { return warnBadMaterial("shininess") }
        apply { $0.shininess = amount }
    }

    // 金属らしさ。0 が非金属、1 が金属。
    public func metalness(_ amount: Float) {
        guard amount.isFinite, amount >= 0, amount <= 1 else {
            return warnBadMaterial("metalness")
        }
        apply { $0.metalness = amount }
    }

    // 周りの光をどれだけ返すか。
    public func ambient(_ color: LinearRGBA) {
        guard let components = Self.materialComponents(color) else {
            return warnBadMaterial("ambient")
        }
        apply { $0.ambient = components }
    }

    // 自ら出す光。
    public func emissive(_ color: LinearRGBA) {
        guard let components = Self.materialComponents(color) else {
            return warnBadMaterial("emissive")
        }
        apply { $0.emissive = components }
    }

    /// 材質を書き換える。**列をその場で閉じる**ので、既に置いた立体は置いた時点の
    /// 材質で描かれる ([ADR-0021] 決定 2 の「記録した列だけで絵が決まる」)。
    ///
    /// フレームの外 (初期化のとき) に書かれた材質は、どのフレームにも属さないので
    /// 警告して無視する (同 決定 4)。光・視点と同じ扱いである。
    private func apply(_ change: (inout Material) -> Void) {
        guard isDrawing else { return warnMaterialOutsideFrame() }
        closeBatch()
        change(&currentMaterial)
    }

    /// 材質へ渡された色から、足し引きに使う 3 成分を取り出す。
    ///
    /// 光と同じくアルファは持ち込まない (乗算済みの成分をそのまま使う)。負の成分は
    /// 光を吸う値になり、式のどこにも意味を持たないので受け取らない。
    private static func materialComponents(_ color: LinearRGBA) -> SIMD3<Float>? {
        let components = SIMD3(color.red, color.green, color.blue)
        // **成分ごとに見る。** SIMD の min / max は数でない成分を飛ばすので、
        // まとめて見ると NaN が 1 つ混じっていても通ってしまう
        guard (0..<3).allSatisfy({ components[$0].isFinite && components[$0] >= 0 })
        else { return nil }
        return components
    }

    /// フレームの外で材質を書いたことを、初回だけ知らせる。
    private func warnMaterialOutsideFrame() {
        warnOnce(
            .materialOutsideFrame,
            "材質はフレームごとに書き直すものなので、描くところ (draw) で呼んでください。"
                + "初期化のときに書いた材質はどのフレームにも属さないため、無視しました")
    }

    /// 受け取れない値を、初回だけ知らせる。
    private func warnBadMaterial(_ name: String) {
        warnOnce(
            .badMaterial,
            "\(name)(): 数でない値・無限・範囲の外の値が渡されたので、材質を変えませんでした")
    }
}
