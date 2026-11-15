// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 出力先 (Outlet) — フレーム 1 枚を受ける拡張点。
///
/// 映像の送出・録画・機材への出力がここへ入る ([ADR-0024] 決定 1)。**組み込みも
/// 外から追加したものも同じ protocol を通る**ので、「組み込みにはできて外にはできない
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
/// ## 失敗してもフレームは止まらない
///
/// ``receive(_:)`` は**投げない** ([ADR-0024] 決定 7)。毎フレーム呼ばれるものが
/// 投げると、1 つの出力先の不調でフレームごと落ちる。代わりに ``failure`` へ理由を
/// 置くと、**続けて失敗した出力先は外され、外したことが診断に出る**。
///
/// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
public protocol Outlet: AnyObject {
    /// 追加されたときに呼ばれる。リソースの用意はここで行う。
    ///
    /// **ここは投げてよい。** 投げると**その束だけが外れて**、他の束とスケッチは
    /// 動き続ける ([ADR-0024] 決定 7)。
    ///
    /// **取り外された出力先が追加し直されると、``close()`` の後にもう 1 度呼ばれる** (``Inlet/open()`` と同じ)。
    /// 出力先は ``close()`` を最後と思い込まず、ここで自分を使える状態へ戻す。
    func open() throws

    /// フレームごとに呼ばれる。**投げない。**
    func receive(_ frame: OutputFrame)

    /// 外されるとき (``SketchPart/detach(_:)-(Outlet)``) と、スケッチが終わるときに呼ばれる。**投げない。**
    ///
    /// 外された後に追加し直されれば、``open()`` がもう 1 度来る。
    func close()

    /// 直近の ``receive(_:)`` で失敗した理由。順調なら `nil`。
    ///
    /// **投げる代わりの通知の仕方である。** 続けて置かれると、この出力先は外される。
    /// 直った時点で `nil` に戻せば、数え直しも起きない。
    var failure: String? { get }
}

extension Outlet {
    public func open() throws {}
    public func close() {}
    public var failure: String? { nil }
}
