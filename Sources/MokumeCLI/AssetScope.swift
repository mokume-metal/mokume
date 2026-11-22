// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 走らせる子に**探させない**資材の包み (#4038)。
///
/// `run`・`watch`・`render`・`replay` のビルドの置き場は、利用者の `swift build` / `swift test` や同じ鍵の別の
/// スケッチと共有なので、実行ファイルの隣にはいまの宣言に無い包みも並ぶ。子の資材の探索は隣の包みをパスの順に
/// 見るので、名前の順で先に来るそれらの包みの同じ相対パスの資材を黙って読みうる。
///
/// **どの包みを外すかは、`bundle` が写さない包みと同じ 1 つの規則で決める**
/// (``BundleCommand/resourceScope(of:product:executable:package:place:asking:)``)。宣言・product・依存の木の
/// どれかが読めなければ何も外さない (子は隣の包みを全部探す)。外した包みは起動で 1 行名乗る
/// (``notice(_:)``)。子へは ``StartupReads/undeclaredBundles`` で渡す。
nonisolated enum AssetScope {
    /// 子に探させない包みの名前。宣言か product が読めなければ空。
    ///
    /// - Parameters:
    ///   - context: 導いた土台。読んだ宣言 (``BuildContext/declared``) と置き場を使う。
    ///   - executable: 建った実行ファイル。隣の並びを読む。
    ///   - package: パッケージの場所。依存の木はここで、`context` の置き場について問う。
    ///   - asking: 道具立てへの問い (``BundleCommand/resourceScope(of:product:executable:package:place:asking:)``
    ///     と同じ)。**検査が偽の答えを渡すために外から渡せる形にしてある。**
    static func undeclaredBundles(
        context: BuildContext, executable: URL, package: URL, asking: Asking = BundleCommand.askSwiftPM
    ) -> Set<String> {
        guard let declared = context.declared, let product = context.product else { return [] }
        return BundleCommand.resourceScope(
            of: declared, product: product, executable: executable, package: package, place: context.place,
            asking: asking
        ).excluded
    }

    /// 1 度だけ子を起こす口 (`run`・`render`・`replay`) の段取り: 探させない包みを決め、在れば 1 行名乗る。
    static func announced(
        context: BuildContext, executable: URL, package: URL, say: (String) -> Void = { print($0) }
    ) -> Set<String> {
        let names = undeclaredBundles(context: context, executable: executable, package: package)
        if let notice = notice(names) { say(notice) }
        return names
    }

    /// 道具立てへの問い (引数と場所を受けて終了コードと標準出力を返す)。
    typealias Asking = @Sendable (_ arguments: [String], _ directory: URL) -> (status: Int32, output: String)

    /// 名乗りに並べる名前の数の上限。共有の置き場には別のスケッチの包みが多く並びうるので、1 行に収める。
    static let listedLimit = 5

    /// 探させない包みの名乗り (1 行)。無ければ `nil`。**黙って外さない** — 名前の形から推した除外なので、
    /// 依存の包みを取り違えて外したときに、絵が出ない理由を辿れるようにする。
    static func notice(_ names: Set<String>) -> String? {
        guard !names.isEmpty else { return nil }
        let sorted = names.sorted()
        var listed = sorted.prefix(listedLimit).joined(separator: ", ")
        if sorted.count > listedLimit { listed += " and \(sorted.count - listedLimit) more" }
        return "Not looking for assets in \(listed) — in the build folder, but no target of this product"
            + " and no dependency in Package.swift builds \(sorted.count == 1 ? "it" : "them") now"
    }

    /// 見張りの世代をまたいで、探させない包みを持ち回る。
    ///
    /// **宣言と置き場と隣の並びが変わらなければ、依存の木を問い直さない** — 作り直しのたびに `swift` を 1 本
    /// 起こすと、保存から絵が変わるまでの待ちに乗る。名乗りは、外す包みが変わった回だけ返す (起動で 1 度)。
    /// 作り直しの糸から書き、子を起こす口から読むので、鍵で守る。
    final class Carried: @unchecked Sendable {
        private struct Key: Equatable {
            let declared: SwiftPM.Package?
            let place: BuildDirectory.Place
            let product: String?
            let built: [String]
        }

        private let lock = NSLock()
        private var key: Key?
        private var names: Set<String> = []
        /// 名乗った集合。**同じ集合を 2 度名乗らない。**
        private var announced: Set<String> = []
        private let asking: Asking

        /// - Parameter asking: 道具立てへの問い。省けば本物を起こす。
        init(asking: @escaping Asking = BundleCommand.askSwiftPM) {
            self.asking = asking
        }

        /// 建った実行ファイルの隣を読み直し、探させない包みを決め直す。
        ///
        /// - Returns: 外す包みが前に名乗ったものから変わったなら、その名乗り。変わらなければ `nil`。
        func refresh(context: BuildContext, executable: URL, package: URL) -> String? {
            let built = BundleCommand.resourceBundles(besides: executable, excluding: []).map(\.lastPathComponent)
            let key = Key(declared: context.declared, place: context.place, product: context.product, built: built)
            let reuse = lock.withLock { self.key == key }
            let names =
                reuse
                ? lock.withLock { self.names }
                : AssetScope.undeclaredBundles(
                    context: context, executable: executable, package: package, asking: asking)
            return lock.withLock {
                self.key = key
                self.names = names
                guard names != announced else { return nil }
                announced = names
                return AssetScope.notice(names)
            }
        }

        /// 次に起こす子に探させない包み。
        var current: Set<String> { lock.withLock { names } }
    }
}
