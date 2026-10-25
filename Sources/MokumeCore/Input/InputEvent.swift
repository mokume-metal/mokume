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
    /// 窓へファイルが落とされた。`paths` は**ファイルの絶対パスだけ** (中身は運ばない)。落とした
    /// 所は `x`・`y` で、スケッチからは ``SketchPart/mouseX``・``SketchPart/mouseY`` に当たる
    /// ([#3061](https://github.com/mokume-metal/mokume/issues/3061))。
    ///
    /// 窓は ``SketchSurface`` がファイルの URL だけを受け、1 本も無いドロップは送らない。外から送る線
    /// (`fileDropped`) は、`paths` が空の 1 件を読めない 1 件として落とす。
    case fileDropped(paths: [String], x: Float, y: Float)
    /// ファイルを選ばせるダイアログ (``SketchPart/selectInput(_:)``) の結果。選んだファイルの絶対パスで、
    /// **取り消しは `nil`** ([#3062](https://github.com/mokume-metal/mokume/issues/3062))。
    ///
    /// 線では `paths` の配列で運ぶ — 選んだ 1 本か、空の配列 (取り消し)。`paths` の無い出来事と、2 本以上
    /// の出来事は読めない 1 件にする。待っている ``SketchPart/selectInput(_:)`` が無いときは、合流点が
    /// 捨てる。
    ///
    /// `serial` は**どの頼みへの答えか** (``SketchPart/selectInput(_:)`` の頼みの通し番号)。**省ける** —
    /// 道具の窓が子へ送る結果は載せ、外から送る結果は載せなくてよい。載っていれば、合流点は**いまの待ちと番号が
    /// 同じときだけ**待ちを終え、違う番号の結果 (前の待ちの古い答え・待ちが終わった後の送り直し) は黙って捨てる。
    /// 載っていなければ今の待ちへ届く。番号があるので、道具は頼みが残っている間、落ちた結果を送り直せる。
    case fileSelected(path: String?, serial: Int? = nil)
    case keyDown(code: Key, characters: String, isRepeat: Bool)
    case keyUp(code: Key)
}

extension String {
    /// 絶対パスの綴りか (`/` で始まる)。**窓の落としはファイルの URL だけを受け、パスは必ず絶対パスになる**
    /// ので、外から送る線も同じ約束を守らせる — 空文字列・`https://…`・相対パスは、窓なら届かないもので、
    /// 作例の `loadImage(paths[0])` が別のものを読む元になる。
    var isAbsolutePath: Bool { hasPrefix("/") }
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
/// 返るので、省いた 1 件を読めない 1 件として数える。`paths` (落としたファイルの並び) も同じで、
/// 無い・空の落としは何も届けず、スケッチの `paths[0]` を落とすだけなので読めない 1 件にする。要素が
/// 絶対パス (`/` で始まる) でないもの — 空文字列・`https://…`・相対パス — を含む落としも、窓なら届かない
/// ものなので読めない 1 件にする。
/// 選んだ結果 (`fileSelected`) の `paths` は、**空の配列が取り消し**という意味を持つ。だから空は読めるが、
/// **無い (書き忘れ) は取り消しと読まず**読めない 1 件にし、2 本以上も 1 本を選ばせる口の結果として
/// 読めないので読めない 1 件にする (先頭の 1 本を黙って取らない)。要素が絶対パスでない結果も読めない。
/// `serial` (どの頼みへの答えか) は省ける。載せるなら正の整数 — 0 や負の番号は頼みの番号ではないので、
/// 読めない 1 件にする (番号なしと読むと、狙った待ちではない待ちを終えうる)。
/// `clickCount` は省略が自然に読める (単発の 1)。
/// **`amount`・`clickCount`・`paths`・`serial` は、それぞれ読む種別 (`pinched`・`mouseDown`・
/// `fileDropped` と `fileSelected`・`fileSelected`) でだけ読む** (``readKeys(forType:)``)。
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
    let paths: [String]?
    let serial: Int?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case type, x, y, button, dx, dy, code, characters, isRepeat, amount, clickCount, paths, serial
    }

    /// 読む鍵 (宣言順)。スキーマ (`input-request.schema.json`) の出来事の `properties` と同じ集合で、
    /// どれかの種別が読む鍵をすべて含む。一致は検査が見る ([#2843](https://github.com/mokume-metal/mokume/issues/2843))。
    static var readKeys: [String] { UnknownKeys.readKeys(CodingKeys.self) }

    /// 種別 `type` の出来事が読む鍵 (宣言順)。知らない鍵の名乗りが並べる。
    ///
    /// **`amount` は `pinched` でだけ、`clickCount` は `mouseDown` でだけ、`paths` は `fileDropped` と `fileSelected` で、
    /// `serial` は `fileSelected` でだけ読む**
    /// ([#2762](https://github.com/mokume-metal/mokume/issues/2762)・[#3061](https://github.com/mokume-metal/mokume/issues/3061))。
    /// ほかの種別に付いていたら、足す前と同じく読まない鍵として名乗り、その 1 件は通す (値の型が違っても
    /// 解けない 1 件にしない — `mouseUp` の `"clickCount": 1.5` で解放が落ちると、釦が押されたまま残る)。
    /// 種別が欠けた・知らない出来事は、どの種別の鍵か決まらないので、すべての鍵を読む鍵として扱う (名乗りに出さない)。
    static func readKeys(forType type: String?) -> [String] {
        guard let type, let kind = InputEventType(rawValue: type) else { return readKeys }
        return readKeys.filter { key in
            switch key {
            case CodingKeys.amount.stringValue: kind == .pinched
            case CodingKeys.clickCount.stringValue: kind == .mouseDown
            case CodingKeys.paths.stringValue: kind == .fileDropped || kind == .fileSelected
            case CodingKeys.serial.stringValue: kind == .fileSelected
            default: true
            }
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        x = try container.decodeIfPresent(Float.self, forKey: .x)
        y = try container.decodeIfPresent(Float.self, forKey: .y)
        button = try container.decodeIfPresent(Int.self, forKey: .button)
        dx = try container.decodeIfPresent(Float.self, forKey: .dx)
        dy = try container.decodeIfPresent(Float.self, forKey: .dy)
        code = try container.decodeIfPresent(Int.self, forKey: .code)
        characters = try container.decodeIfPresent(String.self, forKey: .characters)
        isRepeat = try container.decodeIfPresent(Bool.self, forKey: .isRepeat)
        // 種別が読まない鍵は解かない (値の型が違っても、その 1 件は解ける)
        let kind = InputEventType(rawValue: type)
        amount = kind == .pinched ? try container.decodeIfPresent(Float.self, forKey: .amount) : nil
        clickCount =
            kind == .mouseDown ? try container.decodeIfPresent(Int.self, forKey: .clickCount) : nil
        paths =
            kind == .fileDropped || kind == .fileSelected
            ? try container.decodeIfPresent([String].self, forKey: .paths) : nil
        serial =
            kind == .fileSelected ? try container.decodeIfPresent(Int.self, forKey: .serial) : nil
    }

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
        case .fileDropped:
            // 位置を持つ種別なので x・y は要る (0 は左上であって「無い」ではない)。パスの無い・空の落としは
            // スケッチの `paths[0]` を落とすだけで何も届けないので、読めない 1 件にする
            guard let x, let y, let paths, !paths.isEmpty, paths.allSatisfy(\.isAbsolutePath)
            else { return nil }
            return .fileDropped(paths: paths, x: x, y: y)
        case .fileSelected:
            // 空の配列は取り消し。`paths` が無い・null は書き忘れなので取り消しと読まない。2 本以上は
            // 1 本を選ばせる口の結果として読めない (先頭の 1 本を黙って取らない)
            guard let paths, paths.count <= 1, paths.allSatisfy(\.isAbsolutePath) else { return nil }
            // 番号は省ける。載せるなら頼みの番号 (1 から数える) でなければならない
            if let serial, serial < 1 { return nil }
            return .fileSelected(path: paths.first, serial: serial)
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
