// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization

/// 資材の置き場が、パッケージの宣言に書かれているかを見る。
///
/// ## なぜ走らせる前に止めるのか
///
/// 宣言を書かないと**ビルドは静かに通り、実行時に読めないだけ**になる。この形の
/// 不具合は「描画側は正しく動いているのに絵にならない」という現れ方をするので、
/// 実装を疑うと当たりが外れ続ける。
///
/// 直し方は「宣言を忘れられない構造にすること」で、道具で作ったスケッチは最初から
/// 宣言を持っている。それでも人は置き場を増やすので、**走らせる前にここで止める**。
///
/// ## 宣言は道具立てが解いたものを読む
///
/// `Package.swift` の文字列を照らす形は採らない ([#3984](https://github.com/mokume-metal/mokume/issues/3984))。
/// 道具立てが受け付ける `.copy("./assets")` を宣言漏れとして拒み、別の target やコメントの
/// `resources: [.copy("assets")]` で通してしまう。`dump-package` が解いた target ごとの資材の
/// パスを読む。**宣言はコマンドが読んだものを受け取る** — 各コマンドは宣言を読んだ直後・ビルドの
/// 前にここを呼ぶ (`run`・`render`・`watch` は ``RunCommand/context(in:invocation:environment:home:announce:resolver:afterReading:)``
/// の `afterReading`、`bundle` は宣言を読む段の直後)。検査のために `dump-package` を重ねない。
nonisolated enum ResourceDeclaration {
    /// 資材の置き場としてこの名前を見る。
    static let directoryName = "assets"

    /// 宣言されていない置き場があれば投げる。
    ///
    /// **宣言が読めない回 (`nil`) は止めない。** 道具立てが読めない `Package.swift` は、後の段
    /// (`bundle` は宣言を読む段・`run` などはビルド) が道具立ての理由を添えて止める。ここで
    /// 「宣言が無い」と名乗ると、本当の理由 (宣言が壊れている) を隠す。
    static func check(in root: URL, declared: SwiftPM.Package?) throws(CommandFailure) {
        guard let declared else { return }
        for directory in undeclared(in: root, declared: declared) {
            throw .resourcesNotDeclared(directory: directory)
        }
    }

    /// 読んだ宣言を ``check(in:declared:)`` へ渡す手 (``RunCommand/context(in:invocation:environment:home:announce:resolver:afterReading:)`` へ渡す形)。
    static func checking(in root: URL) -> (SwiftPM.Package?) throws(CommandFailure) -> Void {
        { declared throws(CommandFailure) in try check(in: root, declared: declared) }
    }

    /// 見張りの検査。**宣言が読めた最初の回に 1 度だけ見る** (#682・#3984)。
    ///
    /// 始めに読めれば、見張り始める前にそこで見る (今までどおり 1 度きりで、作り直しのたびには
    /// 見ない)。**始めに宣言が読めなかったら、作り直しで初めて読めた回に見る** — 見るのを始めの
    /// 1 度に限ったまま読めない回を素通りさせると、壊れた宣言で始めた見張りでは検査が二度と
    /// 効かない。止まったら作り直しの失敗と同じ道で理由を出し、子を起こさない。通るまで
    /// 宣言を読み直すたびに見る。
    nonisolated final class Once: Sendable {
        private let root: URL
        private let done = Mutex(false)

        init(in root: URL) { self.root = root }

        /// 読んだ宣言を見る。見終えた後と、読めなかった回は何もしない。
        func check(_ declared: SwiftPM.Package?) throws(CommandFailure) {
            guard let declared, !done.withLock({ $0 }) else { return }
            try ResourceDeclaration.check(in: root, declared: declared)
            done.withLock { $0 = true }
        }
    }

    /// 中身を持つのに、置き場を含む target が宣言していない置き場 (リポジトリからの相対)。
    ///
    /// **見るのは置き場を含む target の宣言だけ** — 別の target の宣言では、その資材は束に
    /// 入らない。宣言が置き場を指すかは、見張りが子へ置き場を渡すかの判断 (``SwiftPM/Package/assetsOrigin(forProduct:in:directoryName:)``)
    /// と同じ 1 つ (``SwiftPM/Package/declaration(of:by:placedAt:)``) で見る — 置き場そのものを指す宣言だけが
    /// 宣言で、祖先 (`.copy("demo")`) や中の 1 ファイル (`.copy("assets/img.png")`) は宣言ではない。
    ///
    /// **置き場を含む target が宣言に無ければ見ない (通す)**: ビルドに入らないディレクトリで、
    /// 資材を宣言しても届かない。
    static func undeclared(in root: URL, declared: SwiftPM.Package) -> [String] {
        var found: [String] = []
        for assets in SwiftPM.Package.places(in: root, directoryName: directoryName) {
            guard hasContents(assets),
                let owner = declared.target(containing: assets, in: root),
                declared.declaration(of: assets, by: owner.target, placedAt: owner.directory) == nil
            else { continue }
            found.append("Sources/\(assets.deletingLastPathComponent().lastPathComponent)/\(directoryName)")
        }
        return found
    }

    /// 置き場に中身があるか (隠しファイルは数えない)。**置き場そのものがリンクなら辿らず、
    /// 中身が無いとして見ない** (前から同じ。見張りの #2519 と同じく範囲の外)。
    private static func hasContents(_ directory: URL) -> Bool {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        else { return false }
        return !entries.isEmpty
    }
}
