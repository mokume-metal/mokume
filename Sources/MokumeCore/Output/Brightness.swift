// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// 表示できる範囲を超えた明るさの丸め方。
public enum ToneMapping: Sendable, Equatable, CaseIterable {
    /// 範囲の外だけを端に寄せる。**0…1 の内側は 1 ビットも変えない。**
    case clip
    /// 明るいところを、範囲へ入るまでなめらかに寄せる。
    ///
    ///
    /// 白飛びした面が一様な白い塊にならなくなる代わりに、`0.8` より明るいところが
    /// 指定より少し暗く出る。色みは変えない (3 成分に同じ倍率を掛ける)。
    case roll

    /// 断片へ渡す番号。**綴りではなく番号で渡す**ので、並びを変えたら断片側も直す。
    var rawIndex: UInt32 {
        switch self {
        case .clip: 0
        case .roll: 1
        }
    }
}

/// 明るさを画面へ写す段。
///
/// **画面 (描画先) の性質であって、材質の性質ではない。** 材質はフレームごとに
/// 戻るが、これは書き換えるまで残る — 同じところに置くと寿命が非対称になり、
/// どちらの規則で動いているのか読めなくなる。
///
/// 効く先は**画面から出て行く絵すべて** — 画面へ差し出す絵と、書き出す絵の両方。
/// ``Canvas/loadPixels()`` で読む画素には効かない。そちらは出力段より手前の
/// 作業空間そのものだからである ([ADR-0011] 決定 3)。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
struct Brightness: Equatable, Sendable {
    /// 画面全体の明るさの倍率。
    var exposure: Float = 1
    /// 範囲を超えた明るさの丸め方。
    var toneMapping: ToneMapping = .clip

    static let `default` = Brightness()

    /// 寄せ始める明るさ。ここより暗いところは ``ToneMapping/roll`` でも動かない。
    static let knee: Float = 0.8

    /// 乗算を戻した色 1 つを、表示へ向けて写す。
    ///
    /// **この関数が曲線の正本である。** 画面へ差し出す経路は GPU 上の断片で同じ
    /// 計算をするので、写しがずれていないことを検査で突き合わせる (`BrightnessTests`)。
    func map(_ color: SIMD3<Float>) -> SIMD3<Float> {
        let lifted = color * exposure
        guard toneMapping == .roll else { return lifted }
        // **どれか 1 つでも有限でなければ丸めない。** 丸めは 3 成分に共通の倍率を
        // 掛けるので、有限でない成分が 1 つあれば倍率そのものが意味を失う。
        //
        // いちばん明るい成分を先に取ってから有限かを見る形にすると、**どの成分が
        // 数でないかで丸まったり丸まらなかったりする** — `max` が数でない値を
        // 引数の位置によって落とすためで、赤が数でなければ丸まらず、青が数でなければ
        // 丸まる。同じ画素なのに結果が変わるうえ、絵としては「少し暗い」だけなので
        // 気付けない ([#440] で、面に描かずに取り出した絵と突き合わせて見つかった)
        //
        // [#440]: https://github.com/mokume-metal/mokume/issues/440
        guard lifted.x.isFinite, lifted.y.isFinite, lifted.z.isFinite else { return lifted }
        // **色みを変えないため、いちばん明るい成分で全体を縮める。** 成分ごとに
        // 曲げると、範囲を超えた成分だけが先に頭打ちになって色が転ぶ
        let peak = max(lifted.x, max(lifted.y, lifted.z))
        guard peak > Self.knee else { return lifted }
        return lifted * (Self.rolled(peak) / peak)
    }

    /// 範囲へ寄せた明るさ。`knee` までは動かさず、そこから 1 へ漸近させる。
    static func rolled(_ peak: Float) -> Float {
        let over = (peak - knee) / (1 - knee)
        return knee + (1 - knee) * (1 - exp(-over))
    }
}
