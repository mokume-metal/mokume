// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 出口 — フレーム 1 枚を受ける差込口。
///
/// 映像の送出・録画・機材への出力がここへ入る ([ADR-0024] 決定 1)。**組み込みも
/// 外から足したものも同じ protocol を通る**ので、「組み込みにはできて外にはできない
/// こと」が増えない (同 決定 10)。
///
/// ```swift
/// final class MyOutlet: Outlet {
///     func receive(_ frame: OutputFrame) {
///         // frame.texture をそのまま渡す / frame.bytes() で中身を見る
///     }
/// }
/// ```
///
/// ## 転んでもフレームは止まらない
///
/// ``receive(_:)`` は**投げない** ([ADR-0024] 決定 7)。毎フレーム呼ばれるものが
/// 投げると、1 つの出口の不調でフレームごと落ちる。代わりに ``failure`` へ理由を
/// 置くと、**続けて転んだ出口は外され、外したことが診断に出る**。
///
/// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
public protocol Outlet: AnyObject {
    /// 一度だけ呼ばれる。資源の用意はここで行う。
    ///
    /// **ここは投げてよい。** 投げると**その束だけが外れて**、他の束とスケッチは
    /// 動き続ける ([ADR-0024] 決定 7)。
    func open() throws

    /// フレームごとに呼ばれる。**投げない。**
    func receive(_ frame: OutputFrame)

    /// 終わるときに一度だけ呼ばれる。**投げない。**
    func close()

    /// 直近の ``receive(_:)`` で転んだ理由。順調なら `nil`。
    ///
    /// **投げる代わりの報せ方である。** 続けて置かれると、この出口は外される。
    /// 直った時点で `nil` に戻せば、数え直しも起きない。
    var failure: String? { get }
}

extension Outlet {
    public func open() throws {}
    public func close() {}
    public var failure: String? { nil }
}
