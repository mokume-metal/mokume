// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

// 資材の場所。
extension SketchPart {
    /// 資材の名前を、実際に在るファイルの場所へ解く。
    ///
    /// <!-- example: 文脈 var notes: String? -->
    /// ```swift
    /// func setup() {
    ///     if let url = try? assetURL("assets/notes.txt") {
    ///         notes = try? String(contentsOf: url, encoding: .utf8)
    ///     }
    /// }
    /// ```
    ///
    /// **探す場所と順は ``loadImage(_:)`` と同じ** — 作業ディレクトリ、束ねた資源の置き場、
    /// 実行ファイルの隣の包みの中、の順に見て、最初に在ったものを返す。`/` で始まる名前は
    /// そのまま使う。mokume が読まない形式のファイルを、同梱した資材から読むのに使う。
    /// 外のパッケージが資材を読むときも、これを使えば利用者の置き方と食い違わない。
    ///
    /// **在れば、ディレクトリでも返す** — フォルダを資材として解く使い方のため。だから作業
    /// ディレクトリに同じ名前のフォルダがあると、同梱した本物のファイルより先にそれが解ける。
    /// mokume の読む口 (``loadImage(_:)``・``loadTable(_:header:)`` など) はここと同じ並びで解いた先を
    /// 開き、ディレクトリや読む権利の無いファイルは、見つからないとは言わずに**開けないもの**として、
    /// 解けた場所と OS の事情を添えて投げる (``ImageFailure/unopenable(path:location:reason:)``・
    /// ``DataFailure/unopenable(path:location:reason:)`` など・
    /// [#2358](https://github.com/mokume-metal/mokume/issues/2358))。
    ///
    /// **見つからないと言うのは、本当に無いときだけ** ([#2838](https://github.com/mokume-metal/mokume/issues/2838))。
    /// 候補の場所に入れず (親のフォルダに入る権利が無いなど) 在るかを確かめられないときは、そこで探すのを
    /// 止め、その場所と OS の事情を ``AssetFailure/unreachable(path:location:reason:)`` で名乗る。
    /// 入れない親の下では、在るファイルと無いファイルの区別が付かない。
    ///
    /// - Throws: どこにも無いとき (説明には探した場所が載る)、または候補の場所に入れないとき。
    // shot: 撮れない 返すのはファイルの場所で、解く先の資材ファイルがこのリポジトリの例には無い
    public func assetURL(_ path: String) throws(AssetFailure) -> URL {
        try AssetLookup.locate(ImageFile.search(for: path), path: path)
    }
}
