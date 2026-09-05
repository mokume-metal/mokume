// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 出来事を 1 行にする。
///
/// ## なぜ書く側もここに置くのか
///
/// 道具の窓が拾った出来事は、子の標準入力へ 1 行 1 件で渡る ([ADR-0032] 決定 4)。
/// **書く側と読む側の綴りが割れると、症状は「触っても効かない」としか出ない** — 道具は
/// 書けたと思い、子は知らない鍵として捨てるので、どちらも何も言わない。
///
/// だから読み手 (``RawInputEvent``) の**隣に置く**。道具はこの行を受け取って中身を見ずに
/// 転送するだけなので、形を知っているのはライブラリだけになる。
///
/// ## 外向きの面とは別物
///
/// `.mokume/input` の区画 ([ADR-0018] 決定 1) は**外から送る口**で、こちらは道具と子の
/// 内側の経路である。鍵の綴りを共有しているのは、読み手が 1 つで済むからであって、
/// 同じ面だからではない。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
/// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
extension InputEvent {
    /// そのまま子の標準入力へ書ける 1 行 (改行を含む)。
    ///
    /// **必ず作れる。** 送るのは自分が組み立てた出来事なので、組めない値は入ってこない。
    var wireLine: String {
        var fields: [(String, String)] = [("type", Self.quoted(wireType))]
        for (key, value) in wireFields { fields.append((key, value)) }
        return "{" + fields.map { "\(Self.quoted($0.0)):\($0.1)" }.joined(separator: ",") + "}\n"
    }

    /// 種別の名前。**読み手の `switch` と同じ綴り。**
    private var wireType: String {
        switch self {
        case .mouseDown: "mouseDown"
        case .mouseUp: "mouseUp"
        case .mouseMoved: "mouseMoved"
        case .scrolled: "scrolled"
        case .keyDown: "keyDown"
        case .keyUp: "keyUp"
        }
    }

    /// 種別ごとに要る値。**読み手が「省略の意味が無い」とした鍵は必ず載せる。**
    private var wireFields: [(String, String)] {
        switch self {
        case .mouseDown(let x, let y, let button), .mouseUp(let x, let y, let button):
            [("x", Self.number(x)), ("y", Self.number(y)), ("button", "\(button)")]
        case .mouseMoved(let x, let y):
            [("x", Self.number(x)), ("y", Self.number(y))]
        case .scrolled(let dx, let dy):
            [("dx", Self.number(dx)), ("dy", Self.number(dy))]
        case .keyDown(let code, let characters, let isRepeat):
            [
                ("code", "\(code.rawValue)"), ("characters", Self.quoted(characters)),
                ("isRepeat", isRepeat ? "true" : "false"),
            ]
        case .keyUp(let code):
            [("code", "\(code.rawValue)")]
        }
    }

    /// 数の書き方。
    ///
    /// **有限でない値は 0 にする。** JSON に `nan` も `inf` も無いので、そのまま書くと
    /// 行ごと解けなくなる — 1 件が消えるのは、位置が 0 になるより分かりにくい。
    private static func number(_ value: Float) -> String {
        value.isFinite ? "\(value)" : "0"
    }

    /// 文字列の囲み方。**入力された文字がそのまま入る**ので、引用符も改行も逃がす —
    /// 逃がさないと、`"` を 1 つ打っただけで行が壊れる。
    private static func quoted(_ text: String) -> String {
        var out = "\""
        for character in text.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if character.value < 0x20 {
                    out += String(format: "\\u%04x", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        return out + "\""
    }
}
