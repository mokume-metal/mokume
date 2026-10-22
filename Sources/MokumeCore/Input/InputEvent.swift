// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 入ってくる出来事。
///
/// 窓からの実操作も、外から送られたものも、同じ形でここへ集まる。
public enum InputEvent: Equatable, Sendable {
    /// `clickCount` は、この押下が何回目の連続した押下か (1 で単発、2 でダブルクリック)。
    /// 窓は `NSEvent.clickCount` をそのまま運び、外から送る線は省くと 1 と読む。
    case mouseDown(x: Float, y: Float, button: MouseButton, clickCount: Int = 1)
    case mouseUp(x: Float, y: Float, button: MouseButton)
    case mouseMoved(x: Float, y: Float)
    /// どこへではなく、**どれだけ**動いたか (描く解像度の画素・縦軸は下向き)。位置は動かさない。
    ///
    /// カーソルを捕まえている間 (``SketchPart/requestPointerLock()``) の窓は、位置が動かないので
    /// これを送る ([#1144](https://github.com/mokume-metal/mokume/issues/1144))。外から送る線
    /// (`mouseMovedBy`) も同じ形で、捕まえていなくても量として届く。
    case mouseMovedBy(dx: Float, dy: Float)
    case scrolled(dx: Float, dy: Float)
    /// トラックパッドのピンチ。**倍率の差分** (0.1 で 1.1 倍に開いた・負で閉じた) — AppKit の
    /// `NSEvent.magnification` と同じ量である ([#2762](https://github.com/mokume-metal/mokume/issues/2762))。
    /// スケッチからはフレームの合計 (``SketchPart/pinch``) として読む。
    case pinched(amount: Float)
    case keyDown(code: Key, characters: String, isRepeat: Bool)
    case keyUp(code: Key)
}

/// 外から送られてきた 1 件を解く。
///
/// **知らない種別も、知らない鍵も、壊れた 1 件も無視する** ([ADR-0018] 決定 3)。
/// 送り手が新しい種別を足しても、古い受け手に当たったときに落ちるのはその 1 件だけで、
/// 走っているスケッチは止まらない。
///
/// ## 意味を持つ既定値が無いフィールドは、欠けていたら解けない
///
/// 位置 (`x` / `y`) とキーの符号 (`code`) には省略の意味が無い。**0 は面の左上であり
/// A のキーであって「無い」ではない。** 埋めて通すと、`{"type":"mouseDown"}` という
/// 壊れた 1 件が「面の左上角を押した」という正しい出来事として合流点へ入り、送り手には
/// `accepted: 1` が返るので誰も気付けない ([#322](https://github.com/mokume-metal/mokume/issues/322))。
///
/// `amount` (ピンチの量) も省略に意味が無い。量の無いピンチは何も動かさず、送り手には `accepted: 1` が
/// 返るので、省いた 1 件を読めない 1 件として数える。`clickCount` は省略が自然に読める (単発の 1)。
///
/// 一方 `button` の 0 は主釦 (左)、`dx` の 0 は動いていない (スクロールでも、相対の移動
/// `mouseMovedBy` でも)、`isRepeat` の false は押しっぱなしでない — こちらは省略が自然に
/// 読めるので埋める。
///
/// **弾き方の機構は要らない。** `nil` を返せば知らない種別と同じ経路に乗り、
/// ``InputInbox`` がその 1 件だけを `ignored` に数えて残りを通す。
///
/// `type` の欠けや型の違う値のように**この型そのものが解けない 1 件**は、`nil` を返す
/// 前に throw する。それを 1 件で済ませるのは包む側の仕事である (面は `InputRequest.Entry`・
/// 標準入力は行ごとの `try?`)。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
struct RawInputEvent: Decodable {
    let type: String
    let x: Float?
    let y: Float?
    let button: Int?
    let dx: Float?
    let dy: Float?
    let code: Int?
    let characters: String?
    let isRepeat: Bool?
    let amount: Float?
    let clickCount: Int?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case type, x, y, button, dx, dy, code, characters, isRepeat, amount, clickCount
    }

    /// 読む鍵 (宣言順)。スキーマ (`input-request.schema.json`) の出来事の `properties` と同じ集合で、
    /// 知らない鍵の名乗りが並べる。一致は検査が見る ([#2843](https://github.com/mokume-metal/mokume/issues/2843))。
    static var readKeys: [String] { UnknownKeys.readKeys(CodingKeys.self) }

    /// 線の番号を釦にする。**番号を型へ絞る関所は、ここと窓 (`SketchSurface`) の 2 つだけ。**
    ///
    /// 線は macOS の `NSEvent.buttonNumber` のまま据え置いたので ([ADR-0034] 決定 4)、
    /// 変換はせず包むだけである。省いた 1 件は主釦 (左) として読む。
    ///
    /// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
    private var mouseButton: MouseButton {
        button.map(MouseButton.init(rawValue:)) ?? .left
    }

    /// 知っている形なら出来事にする。知らない種別も、必須の値が欠けたものも `nil`。
    ///
    /// **綴りは ``InputEventType`` から引く。** 知らない綴りを落とすのは
    /// `init(rawValue:)` の仕事で、そこから先は `default` を持たない — 書く側が
    /// 送れる種別を、読む側が知らないままにできなくするためである。
    var event: InputEvent? {
        guard let type = InputEventType(rawValue: type) else { return nil }
        switch type {
        case .mouseDown:
            guard let x, let y else { return nil }
            // **押した回数は整数で、負にはならない。** 省いた 1 件は単発 (1) と読む。整数でない値は
            // 解く前に落ちる (``InputRequest``・``StandardInputEvents`` は読めない 1 件として数える)。
            // 負の値は読めない 1 件にする — 負の回数が合流点へ入ると、何も言わずに別の意味になる
            if let clickCount, clickCount < 0 { return nil }
            return .mouseDown(x: x, y: y, button: mouseButton, clickCount: clickCount ?? 1)
        case .mouseUp:
            guard let x, let y else { return nil }
            return .mouseUp(x: x, y: y, button: mouseButton)
        case .mouseMoved:
            guard let x, let y else { return nil }
            return .mouseMoved(x: x, y: y)
        case .mouseMovedBy:
            return .mouseMovedBy(dx: dx ?? 0, dy: dy ?? 0)
        case .scrolled:
            return .scrolled(dx: dx ?? 0, dy: dy ?? 0)
        case .pinched:
            // 量の 0 は動いていない — 省略は読めるが、量の無いピンチは何も起こさないので落とす
            guard let amount else { return nil }
            return .pinched(amount: amount)
        case .keyDown:
            guard let code else { return nil }
            return .keyDown(
                code: Key(rawValue: code), characters: characters ?? "",
                isRepeat: isRepeat ?? false)
        case .keyUp:
            guard let code else { return nil }
            return .keyUp(code: Key(rawValue: code))
        }
    }
}
