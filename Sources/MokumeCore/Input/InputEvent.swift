// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 入ってくる出来事。
///
/// 窓からの実操作も、外から送られたものも、同じ形でここへ集まる。
public enum InputEvent: Equatable, Sendable {
    case mouseDown(x: Float, y: Float, button: Int)
    case mouseUp(x: Float, y: Float, button: Int)
    case mouseMoved(x: Float, y: Float)
    case scrolled(dx: Float, dy: Float)
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
/// 一方 `button` の 0 は主釦、`dx` の 0 は動いていない、`isRepeat` の false は
/// 押しっぱなしでない — こちらは省略が自然に読めるので埋める。
///
/// **弾き方の機構は要らない。** `nil` を返せば知らない種別と同じ経路に乗り、
/// ``InputInbox`` がその 1 件だけを `ignored` に数えて残りを通す。
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

    private enum CodingKeys: String, CodingKey {
        case type, x, y, button, dx, dy, code, characters, isRepeat
    }

    /// 知っている形なら出来事にする。知らない種別も、必須の値が欠けたものも `nil`。
    var event: InputEvent? {
        switch type {
        case "mouseDown":
            guard let x, let y else { return nil }
            return .mouseDown(x: x, y: y, button: button ?? 0)
        case "mouseUp":
            guard let x, let y else { return nil }
            return .mouseUp(x: x, y: y, button: button ?? 0)
        case "mouseMoved":
            guard let x, let y else { return nil }
            return .mouseMoved(x: x, y: y)
        case "scrolled":
            return .scrolled(dx: dx ?? 0, dy: dy ?? 0)
        case "keyDown":
            guard let code else { return nil }
            return .keyDown(
                code: Key(rawValue: code), characters: characters ?? "",
                isRepeat: isRepeat ?? false)
        case "keyUp":
            guard let code else { return nil }
            return .keyUp(code: Key(rawValue: code))
        default:
            return nil
        }
    }
}
