// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// ファイル名の長さの数え方と、作れない長さの名前 ([#2774])。
///
/// 利用者の文字から作るファイル名 (`bundle` の名前・`new` の名前・`render --out`・`beginRecord`・
/// `save`) を、作る前に長さで検めるための 1 本である。**写しを持たない** — 数え方が 2 か所に
/// あると、片方だけが直った日に口によって線が食い違う。
///
/// [#2774]: https://github.com/mokume-metal/mokume/issues/2774
package nonisolated enum FileNameLength {
    /// ファイル名の長さの上限 (``of(_:)`` の数え方で)。APFS は 255 まで作れて、256 で
    /// `File name too long` になる ([#2501](https://github.com/mokume-metal/mokume/issues/2501) の実測)。
    package static let limit = 255

    /// `name` をファイル名にしたときの長さ。
    ///
    /// **バイトでも、渡された文字列の UTF-16 の単位でもない。** Foundation は名前を分解した形
    /// (HFS+ の分解) でファイルシステムへ渡し、APFS はそれを UTF-16 の単位で数える。`é` と濁点の
    /// 付いた仮名と絵文字は 2、記号が 2 つ付く字 (`ệ`) は 3、ハングルの音節は 2〜3、国旗は 4、
    /// ZWJ でつないだ家族の絵文字は 11 になる — 渡された形で数えると、`.app` は
    /// 作れて紙で落ちる名前 (濁点の付いた仮名 120 字) を通してしまう。完全な NFD とも違う
    /// (U+212B のオングストローム記号は分解されない) ので、Foundation がファイルシステムへ渡す形
    /// そのもの (`fileSystemRepresentation`) から数える (#2501)。
    ///
    /// **NUL を含む名前と空の名前は数えられず、`nil` を返す。** どちらもファイル名にできない (書けない名前)。
    /// `fileSystemRepresentation` は NUL を含む文字列にも空の文字列にも Objective-C の例外を投げ、
    /// プロセスごと落ちるので、呼ぶ前に見る (#2774 の反証)。`/` は数える (呼ぶ側が部品に分けてから呼ぶ)。
    package static func of(_ name: String) -> Int? {
        guard !name.isEmpty, !name.unicodeScalars.contains("\0") else { return nil }
        return String(cString: (name as NSString).fileSystemRepresentation).utf16.count
    }

    /// パスの、最後の部品より前の部品 (ディレクトリの名前)。空の部品 (`//`・先頭の `/`) は落とす。
    package static func directoryComponents(of path: String) -> [String] {
        let name = lastComponent(of: path)
        let scalars = path.unicodeScalars
        let head = scalars.prefix(scalars.count - name.unicodeScalars.count)
        return head.split(separator: "/", omittingEmptySubsequences: true).map { String($0) }
    }

    /// パスの最後の部品 (ファイル名)。**最後の `/` より後ろ**で、`/` を Unicode scalar で探す
    /// (``FrameSequence`` と同じ。書記素で探すと、直後の結合文字と 1 つの文字になった `/` を見落とす)。
    package static func lastComponent(of path: String) -> String {
        let scalars = path.unicodeScalars
        let start = scalars.lastIndex(of: "/").map(scalars.index(after:)) ?? scalars.startIndex
        return String(scalars[start...])
    }
}

/// 作れない長さのファイル名 ([#2774])。
///
/// [#2774]: https://github.com/mokume-metal/mokume/issues/2774
package nonisolated struct LongFileName: Equatable, Sendable {
    /// 越えたファイル名 (パスではなく最後の部品)。
    package let name: String
    /// ``FileNameLength/of(_:)`` で数えた長さ。NUL を含み数えられない名前は `nil`。
    package let length: Int?
    /// 書ける長さの上限。
    package let limit: Int
    /// 連番で、番号が伸びた後の名前を見たときの、その枚の通し番号 (0 始まり)。1 枚ものと `.mov` は `nil`。
    package let index: Int?
    /// ファイルの名前ではなく、作るディレクトリの部品の名前か。
    package let isDirectory: Bool
}
