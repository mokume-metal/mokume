// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 観測から持ち出した 1 枚の目録 ([#2618])。形の正典は `Schemas/kept-frame.schema.json`。
///
/// 観測の区画の絵と目録は次の要求で消える。持ち出し (`"keep": true`) は、撮った 1 枚とそのフレームについて
/// 分かる条件を組にして、区画の外 (`.mokume/kept/<要求の id>/`) に残す。
///
/// ## 分かることだけを書く
///
/// - **`@Param` の値は、その絵を描いた `draw()` の終わりに読んだ値**である (``Params/read``)。描いた入力の
///   値ではない — `circle(…, radius)` の後に `radius += 1` するスケッチを半径 120 から撮ると、ここには 121 が載る。
///   絵を描いたフレームの後に値が動いた (外から止めている間につまみを動かした) なら、古い絵に新しい値を
///   結び付けず、``params`` を `nil` にして理由 (``paramsUnknownReason``) を名乗る
/// - **乱数の種と版の鍵は作らない。** その来歴は記録 ([#2603]) が持ち、ここでは記録の識別子とフレーム番号
///   (``record``) で指す。記録していない実行では ``record`` が `nil` で、種と版は不明である — 推測で埋めない
///
/// ## 完成の印
///
/// 記録 (``ReplayRecorder``) と同じ作法で、`<id>.<pid>.partial/` に絵と目録を置き終えてから `<id>/` へ改名する
/// (``FrameObserver/keep(_:image:)``)。**完成の印は置き場の名前 (`<id>/`) である。** 改名の前に落ちた・書けなかった組は
/// 書き途中の名前のまま残り、完成として読まれない。目録の ``complete`` は改名の前に書くので、書き途中の置き場の中にも
/// `complete: true` の目録が残りうる — **書き途中の置き場の中の目録を読んではならない。**
///
/// [#2603]: https://github.com/mokume-metal/mokume/issues/2603
/// [#2618]: https://github.com/mokume-metal/mokume/issues/2618
struct KeptFrame: Encodable {
    /// この形式の版。
    let schemaVersion = 1
    /// 持ち出しを頼んだ観測の要求の識別子。置き場の名前でもある。
    let id: String
    /// 絵のファイル名 (この目録からの相対)。
    let image: String
    /// 絵を描いたフレームの番号。
    let frame: Int
    /// 絵を描いたフレームの時刻 (秒)。
    let time: Double
    /// 走っていた時計。
    let clock: KeptClock
    /// 描いた面の大きさ。縮小を頼んだ観測では、絵のほうが小さい。
    let size: ObservationReport.Size
    /// この絵を生んだ入力の世代 (観測の応答の `stamp` と同じ。等値比較だけに使う)。
    let stamp: String?
    /// このフレームでスケッチが差し出した値。
    let values: [String: ExposedValue]
    /// `@Param` の値。分からなければ `nil`。
    let params: Params?
    /// ``params`` が `nil` の理由。
    let paramsUnknownReason: String?
    /// 記録している実行なら、その記録の識別子と、この絵のフレーム番号。記録していなければ `nil`。
    let record: Record?
    /// 「この目録は、置き終える組のものとして書いた」ことだけを言う (常に `true`)。**完成の印ではない** — 完成の印は
    /// 置き場の名前 (`<id>/`) で、改名で転んだ書き途中の置き場の中にも `true` の目録が残る。
    let complete = true

    /// 時計。
    struct KeptClock: Encodable, Equatable {
        /// `wallClock` (実際に流れた時間) か `frames` (フレーム番号から導く)。
        let kind: String
        /// `frames` のときの 1 秒あたりの枚数。
        let frameRate: Int?

        init(_ clock: Clock) {
            switch clock {
            case .wallClock:
                kind = "wallClock"
                frameRate = nil
            case .frameIndex(let rate):
                kind = "frames"
                frameRate = rate
            }
        }
    }

    /// `@Param` の値。
    struct Params: Encodable, Equatable {
        /// いつ読んだか。いまは `endOfDraw` (その絵を描いた `draw()` の終わり) だけ。
        let read = "endOfDraw"
        /// 宣言した順の値。
        let values: [NamedParamValue]

        private enum CodingKeys: String, CodingKey { case read, values }
    }

    /// 記録を指す印。
    struct Record: Encodable, Equatable {
        /// 記録の識別子 (記録の `id`)。
        let id: String
        /// この絵を描いたフレームの番号。
        let frame: Int
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, image, frame, time, clock, size, stamp, values, params, paramsUnknownReason
        case record, complete
    }

    /// **分からないことは `null` で書く** (``params``・``record``・``stamp``)。鍵ごと落とすと、古い書き手が
    /// 知らなかった鍵と見分けが付かない。``paramsUnknownReason`` だけは在るときにだけ書く。
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(image, forKey: .image)
        try container.encode(frame, forKey: .frame)
        try container.encode(time, forKey: .time)
        try container.encode(clock, forKey: .clock)
        try container.encode(size, forKey: .size)
        try container.encode(stamp, forKey: .stamp)
        try container.encode(values, forKey: .values)
        try container.encode(params, forKey: .params)
        try container.encodeIfPresent(paramsUnknownReason, forKey: .paramsUnknownReason)
        try container.encode(record, forKey: .record)
        try container.encode(complete, forKey: .complete)
    }

    /// 置き場の名前に使えない識別子なら、その理由。使えるなら `nil`。
    ///
    /// **要求の識別子はそのまま置き場の名前になる** ので、区切り (`/`)・NUL を含むものと、点で始まるもの (`.`・`..`・
    /// 隠しファイル) は断る — 断らないと `.mokume/kept` の外へ書ける。長すぎる名前 (書き途中の名前の上限を越える) も断る。
    ///
    /// **`.partial` で終わる名前は、大文字小文字を区別せずに断る** ([#2618] の反証 1)。書き途中の名前は
    /// `<id>.<pid>.partial` なので、それと同じ形の識別子 (`x.12.partial`) を通すと、別の識別子 (`x`) の書き途中と
    /// ボリュームの上で同じ名前になりうる。macOS の既定の APFS は大文字小文字を区別しない (`x.12.PARTIAL` も
    /// 同じ名前) ので、比べ方も区別しない。Unicode の正規化の違い (APFS は正規化の違いも同じ名前に読む) は、
    /// `String` の比較が正規の等価で比べるので同じ扱いになる。
    ///
    /// [#2618]: https://github.com/mokume-metal/mokume/issues/2618
    static func refusal(forDirectoryNamed id: String) -> String? {
        if id.isEmpty { return "the id is empty" }
        if id.contains("/") || id.contains("\u{0}") {
            return "the id contains a character a folder name cannot hold (/ or NUL)"
        }
        if id.hasPrefix(".") { return "the id starts with a dot" }
        let suffix = FrameObserver.keptPartialSuffix
        if id.range(of: suffix, options: [.caseInsensitive, .anchored, .backwards]) != nil {
            return "the id ends with \(suffix) (in any case), which is the shape of a folder being written"
        }
        // 書き途中の名前 (`<id>.<pid>.partial`) が名前の上限 (255 バイト) に収まること。pid は最大 10 桁
        if id.utf8.count + 1 + 10 + suffix.utf8.count > 255 {
            return "the id is too long for a folder name"
        }
        return nil
    }
}
