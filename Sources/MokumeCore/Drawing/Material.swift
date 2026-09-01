// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 表面の質感ひとそろい。
///
/// **シェーディングの式は 1 本しかない。** 式を 2 本持って切り替える形にすると、
/// どの指定が効くかが「いまどちらの式か」に依存する — 利用者から見れば、書いた
/// 指定が黙って無視されるのと同じである。1 本に絞ったので、ここに並ぶ 4 つは
/// **常に全部が効く**。
///
/// ## 式
///
/// 塗りを `c`、金属らしさを `m` として、面が出す色は次で決まる。
///
/// ```text
/// 出る色 = 自発光
///        + 周りへの返し · c · (底上げの光の合計)
///        + (1 − m) · c · (向きを持つ光の Lambert 合計)
///        + 艶
/// ```
///
/// **既定 (``default``) では、材質が無かったときの式と 1 演算も違わない** —
/// 周りへの返しが白・金属らしさ 0・自発光が黒・艶なしのとき、上の式は
/// 「塗り × 受け取った光の合計」に畳まれる。既にある絵が動かないのはこのため。
///
/// ## 金属が映すもの
///
/// 金属は拡散を持たず、**周りを映す**ことでしか見えない。映る先は
/// [`Surroundings`](Surroundings.swift) で置いた周囲で、置いていなければ**底上げの光を
/// 一様な周りとして映す** (#295 の時点ではこちらしか無かった)。だから `lights()` だけの
/// 下でも金属が真っ黒にならず、**どちらも置いていなければ警告が出る**。
///
/// ## 寿命
///
/// 材質は**シーンの記述**なのでフレームを越えない ([ADR-0021] 決定 4)。
/// 積んだスタイルには含まれる — 変換と同じく、入れ子で書けないと使いにくいためである。
///
/// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
struct Material: Equatable, Sendable {
    /// 艶の鋭さ。**0 なら艶を出さない。**
    ///
    /// 手本の綴り (`shininess`) をそのまま採ったので、**大きいほど鋭い** —
    /// 粗さとは向きが逆である。粗さへは断片の側で写す (`Common.metal`)。
    var shininess: Float = 0
    /// 金属らしさ。0 が非金属、1 が金属。
    var metalness: Float = 0
    /// 周りの光をどれだけ返すか。白なら全部返す (= 遮蔽なし)。
    var ambient: SIMD3<Float> = SIMD3(1, 1, 1)
    /// 自ら出す光。光が当たっていなくても足される。
    var emissive: SIMD3<Float> = .zero
    /// この面が影を受けるか。
    ///
    /// **材質の指定ではない** — 利用者は `receiveShadow(_:)` で書く。ここに載せて
    /// あるのは、列ごとに断片へ届く値がここ 1 つにまとまっているためである。
    var receivesShadow = true

    static let `default` = Material()

    /// 何も指定していない状態か。**警告の判定に使う** — 既定のまま光が無いのは
    /// ふつうの平坦な塗りであって、知らせることが無い。
    var isDefault: Bool { self == .default }

    /// 効きようのない材質の書き方。
    ///
    /// **警告そのものを検査から呼べるように、判定を値として分けてある** — 警告は
    /// 標準エラーへ流れるだけなので、文言を読む検査は書けない。
    enum UnusableReason: Equatable, Sendable {
        /// 光が 1 つも無い。立体は塗り 1 色で出るので、材質はどれも効かない。
        case noLight
        /// 金属を上げたが、映す先 (底上げの光) が無い。艶だけが残って暗くなる。
        case metalWithoutSurroundings
    }

    /// この材質が、置いた光と周囲のもとで効くかどうか。
    static func unusableReason(
        _ material: Material, lights: [Light], surroundings: Surroundings?
    ) -> UnusableReason? {
        guard !material.isDefault else { return nil }
        // 周囲も面を明るくするので、光が無くても周囲があれば材質は効く
        if lights.isEmpty, surroundings == nil { return .noLight }
        guard material.metalness > 0, surroundings == nil else { return nil }
        // 映す先は、置いた周囲か、一様な周りとして扱う底上げの光のどちらか
        return lights.contains(where: { $0.kind == .ambient }) ? nil : .metalWithoutSurroundings
    }

    /// 影を受けるかどうかだけを差し替えた材質。
    func receiving(shadow: Bool) -> Material {
        var copy = self
        copy.receivesShadow = shadow
        return copy
    }

    /// シェーダへ渡す形へ詰める。
    var packed: PackedMaterial {
        PackedMaterial(
            ambientAndShininess: SIMD4(ambient, shininess),
            emissiveAndMetalness: SIMD4(emissive, metalness),
            flags: SIMD4(receivesShadow ? 1 : 0, 0, 0, 0))
    }
}

/// 材質をシェーダへ渡す形。
///
/// 並びは `Drawing/Shaders/Common.metal` の同名の構造体と一致していなければならない
/// (``ShapeVertex`` と同じ理由で、大きさを ``expectedStride`` として持つ)。
struct PackedMaterial {
    /// 周りの光への返し (rgb) と、艶の鋭さ (w)。
    var ambientAndShininess: SIMD4<Float>
    /// 自発光 (rgb) と、金属らしさ (w)。
    var emissiveAndMetalness: SIMD4<Float>
    /// 旗 — x が 1 なら影を受ける。
    var flags: SIMD4<Float>

    /// シェーダ側の構造体と一致すべき大きさ (バイト)。
    static let expectedStride = 48
}
