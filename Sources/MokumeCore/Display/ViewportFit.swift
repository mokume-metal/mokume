// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 描いた絵を、表示できる面のどこへ置くか。
///
/// **描く解像度と、それを映す面の大きさは別物である。** 面をどうリサイズしても
/// スケッチは同じ解像度で描き続け、縦横比を保ったまま面の中央へ収まる。余った領域は
/// 帯になる — 面が横長すぎれば左右に、縦長すぎれば上下に。
///
/// この独立は、表示の都合が描く解像度へ漏れない構造にするためのもの。**漏れる構造に
/// すると、そこから戻せない。**
struct ViewportFit: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    /// 面の中央へ、縦横比を保って最大に収める。
    ///
    /// - Parameters:
    ///   - contentAspect: 描いた絵の 幅 ÷ 高さ。
    ///   - surfaceWidth: 表示できる面の幅。
    ///   - surfaceHeight: 表示できる面の高さ。
    static func fit(
        contentAspect: Double, surfaceWidth: Double, surfaceHeight: Double
    ) -> ViewportFit {
        guard contentAspect > 0, surfaceWidth > 0, surfaceHeight > 0 else {
            return ViewportFit(x: 0, y: 0, width: 0, height: 0)
        }
        let surfaceAspect = surfaceWidth / surfaceHeight
        if surfaceAspect > contentAspect {
            // 面のほうが横長 — 高さいっぱいに広げ、左右に帯が出る
            let width = surfaceHeight * contentAspect
            return ViewportFit(
                x: (surfaceWidth - width) / 2, y: 0, width: width, height: surfaceHeight)
        }
        // 面のほうが縦長 (等しい場合も含む) — 幅いっぱいに広げ、上下に帯が出る
        let height = surfaceWidth / contentAspect
        return ViewportFit(
            x: 0, y: (surfaceHeight - height) / 2, width: surfaceWidth, height: height)
    }
}
