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
    case keyDown(code: Int, characters: String, isRepeat: Bool)
    case keyUp(code: Int)
}

/// 外から送られてきた 1 件を解く。
///
/// **知らない種別も、知らない鍵も、壊れた 1 件も無視する** ([ADR-0018] 決定 3)。
/// 送り手が新しい種別を足しても、古い受け手に当たったときに落ちるのはその 1 件だけで、
/// 走っているスケッチは止まらない。
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

    /// 知っている形なら出来事にする。知らなければ `nil`。
    var event: InputEvent? {
        switch type {
        case "mouseDown":
            .mouseDown(x: x ?? 0, y: y ?? 0, button: button ?? 0)
        case "mouseUp":
            .mouseUp(x: x ?? 0, y: y ?? 0, button: button ?? 0)
        case "mouseMoved":
            .mouseMoved(x: x ?? 0, y: y ?? 0)
        case "scrolled":
            .scrolled(dx: dx ?? 0, dy: dy ?? 0)
        case "keyDown":
            .keyDown(code: code ?? 0, characters: characters ?? "", isRepeat: isRepeat ?? false)
        case "keyUp":
            .keyUp(code: code ?? 0)
        default:
            nil
        }
    }
}
