// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import Synchronization

/// 資材を探すときに、実行ファイルの隣に並んだ包みのうち**探してよいもの** (#4038)。
///
/// `run`・`watch`・`render`・`replay` のビルドの置き場は、利用者の `swift build` / `swift test` や同じ鍵の別の
/// スケッチと共有なので、実行ファイルの隣には、いまの宣言に無い包み (改名する前のパッケージ名・消した target・
/// 外した依存・テストの target・別のスケッチの包み) も並び、後からも増える。資材の探索 (``ImageFile/search(for:neighbourhood:resources:signal:)``)
/// は隣の包みをパスの順に見るので、名前の順で先に来るそれらの包みの同じ相対パスの資材を、黙って読みうる。
///
/// どの包みがいまの宣言のものかは、宣言と依存の木を読める道具にしか分からないので、道具が**探してよい包み**を
/// 子へ渡す (``StartupReads/assetBundles``)。子はそれ以外の包みを探さない (後から置き場に現れた包みも)。
/// **渡されなければ、隣の包みを全部探す** (いままでどおり)。
package nonisolated enum AssetBundles {
    /// 値の中の項の区切り。包みの名前は 1 段のファイル名なので `/` を含まない。
    package static let separator: Character = "/"

    /// 探してよい包み。名前そのもの (自分の実行 product の閉包の target の包み) と、名前の頭 (依存のパッケージの
    /// 名前に `_` を足したもの) で表す。**比べ方は大文字と小文字を区別しない** — 区別しないボリュームでは、改名した
    /// target の包みが古い綴りのまま作り直される。区別しない分は探す側 (残す側) へ倒れる。
    package struct Allowance: Equatable, Sendable {
        /// 包みの名前そのもの (小文字に畳んだもの・`.bundle` で終わる)。
        package let names: Set<String>
        /// 包みの名前の頭 (小文字に畳んだもの・`_` で終わる)。
        package let prefixes: Set<String>

        /// - Parameters:
        ///   - bundles: 探してよい包みの名前 (`demo_demo.bundle`)。
        ///   - packages: 包みを探してよい依存のパッケージの名前 (`mokume`)。頭 `mokume_` で始まる包みを探す。
        /// - Returns: 値に組めない名前 (空・`/` を含む・`.bundle` で終わらない包みの名前) が 1 つでもあれば `nil`。
        ///   **読めた分だけで組まない** — 一部だけを許すと、残りの依存の包みを外しすぎる。
        package init?(bundles: some Sequence<String>, packages: some Sequence<String>) {
            var names = Set<String>()
            for bundle in bundles {
                guard bundle.hasSuffix(".bundle"), !bundle.contains(AssetBundles.separator) else { return nil }
                names.insert(bundle.lowercased())
            }
            var prefixes = Set<String>()
            for package in packages {
                guard !package.isEmpty, !package.contains(AssetBundles.separator) else { return nil }
                prefixes.insert("\(package)_".lowercased())
            }
            guard !names.isEmpty || !prefixes.isEmpty else { return nil }
            self.names = names
            self.prefixes = prefixes
        }

        /// 環境に載った値を解く。**項が 1 つでも読めなければ `nil`** (渡されていないものとして全部探す) —
        /// 空の値・空の項・`.bundle` でも `_` でも終わらない項。読めた項だけで許すと、外しすぎる。
        package init?(value: String) {
            let items = value.split(separator: AssetBundles.separator, omittingEmptySubsequences: false)
            var bundles: [String] = []
            var packages: [String] = []
            for item in items.map(String.init) {
                if item.hasSuffix(".bundle") {
                    bundles.append(item)
                } else if item.count > 1, item.hasSuffix("_") {
                    packages.append(String(item.dropLast()))
                } else {
                    return nil
                }
            }
            self.init(bundles: bundles, packages: packages)
        }

        /// 環境に載せる値。名前の順に並べる — 同じ一覧から同じ値が出る。
        package var value: String {
            (names.sorted() + prefixes.sorted()).joined(separator: String(AssetBundles.separator))
        }

        /// 包み `bundle` (`Aaa_demo.bundle`) を探してよいか。
        package func allows(_ bundle: String) -> Bool {
            let folded = bundle.lowercased()
            return names.contains(folded) || prefixes.contains { folded.hasPrefix($0) }
        }
    }

    /// 道具の合図の読み手。**環境と、読んだ値の控えを持つ。** 本番はプロセスで 1 つ (``process``) で、検査は
    /// 自分の環境を持つものを作って読む — プロセスの環境と控えに触ると、並んで走るほかの検査の資材の探索が、
    /// 置いた値で包みを外す。
    package final class Signal: Sendable {
        /// 合図を読んだか、読んだ値。**一度だけ控える** — 読んだら環境から消すので、2 度目からは環境に無い。
        private struct Taken {
            var done = false
            var value: Allowance?
        }

        private let environment: @Sendable () -> [String: String]
        private let unset: @Sendable (String) -> Void
        private let taken = Mutex(Taken())

        /// - Parameters:
        ///   - environment: 環境を読む手。
        ///   - unset: 環境から合図を消す手。
        package init(
            environment: @escaping @Sendable () -> [String: String],
            unset: @escaping @Sendable (String) -> Void
        ) {
            self.environment = environment
            self.unset = unset
        }

        /// プロセスの環境を読み、`unsetenv` で消す本番の読み手。
        package static let process = Signal(
            environment: { ProcessInfo.processInfo.environment }, unset: { unsetenv($0) })

        /// 道具が渡した、探してよい包み。**無ければ `nil` (全部探す)。** main で初めて呼んだときに控える。
        ///
        /// **環境を読むのはここだけ** — 一覧 ([StartupReads]) が読み場所としてこのファイルを名指している。
        /// **main で呼ばれたら、合図を環境から消す** (``ShaderOrigin/startup()`` と同じ)。合図はこのプロセスを
        /// 起こした道具が自分の置き場と宣言から決めたもので、このプロセスがさらに起こす子のものではない — 継がせると、
        /// 別の置き場で走る孫が、そこで要る包みを外してしまう。読むのは `SketchApplication` の組み立てで、スケッチの
        /// `setup()` より前である (資材を探さないスケッチ・探す前に子を起こすスケッチでも消える)。控えた後に環境へ
        /// 合図が現れても (検査だけ)、main なら消すが、控えは替えない。
        ///
        /// **消すのは main だけ。** 資材の探索も組み立てを通らない入口の保険としてここを呼ぶが、探索は待たない
        /// 読み込みの裏の仕事や音の糸からも来る。main の外では、控えが無ければ環境を読むだけで消さず、控えもしない
        /// (`unsetenv` を、環境を読むほかの糸と競わせない)。
        ///
        /// - Parameter onMain: いま main で呼ばれているか。**検査が main の外を装うために渡せる形にしてある。**
        package func startup(onMain: Bool = Thread.isMainThread) -> Allowance? {
            let key = StartupReads.assetBundles.key
            let given = environment()[key]
            return taken.withLock { taken in
                guard onMain else { return taken.done ? taken.value : given.flatMap(Allowance.init(value:)) }
                if given != nil { unset(key) }
                if !taken.done {
                    taken.value = given.flatMap(Allowance.init(value:))
                    taken.done = true
                }
                return taken.value
            }
        }
    }

    /// プロセスの合図 (``Signal/process``) を読む。組み立てが呼ぶ。
    @discardableResult
    package static func startup() -> Allowance? {
        Signal.process.startup()
    }

    /// 外した包みにだけ在った資材の知らせの控え。
    private struct Missed {
        /// 知らせた包み。鍵は包みの名前。
        var log = WarningLog<String>()
        /// 外した包みの中を確かめたパス。**同じパスは 1 度しか確かめない** — 見つからない資材を毎フレーム探す
        /// スケッチで、外した包みの数だけの `stat` を毎フレーム払わない。
        var checked = Set<String>()
    }

    private static let missed = Mutex(Missed())

    /// 外した包みの中を確かめるパスの数の上限。名前を毎フレーム変えて探すスケッチで、控えを伸ばし続けない。
    static let checkedLimit = 256

    /// 見つからなかった資材 `path` について、外した包みの中を確かめてよいか。**同じパスでは 1 度だけ `true`**
    /// (上限 ``checkedLimit`` を越えたら確かめない)。
    static func shouldCheck(_ path: String) -> Bool {
        missed.withLock { missed in
            guard missed.checked.count < checkedLimit else { return false }
            return missed.checked.insert(path).inserted
        }
    }

    /// 探した資材がどこにも無く、外した包み `bundle` の中には在ったことを、**包みごとに 1 度**知らせる。
    ///
    /// 外す包みは道具が名前の形 (いまの宣言の target の包みか・依存の名前で始まるか) から決めるので、取り違えて
    /// 依存の包みを外すと、資材は「見つからない」とだけ言われる。そのとき作者が原因へ辿れるように、包みの名前と
    /// 外れた理由を言う。共有の置き場の別のスケッチの包みでも嘘にならないよう、言うのは事実 (その包みに在る・
    /// 道具がその包みを探させなかった) だけにする。投げる失敗 (``AssetFailure/notFound(path:searched:)`` など) は変えない。
    static func noteMissed(path: String, in bundle: String) {
        let first = missed.withLock { missed -> Bool in
            guard !missed.log.hasWarned(bundle) else { return false }
            missed.log.record(bundle, missedNotice(path: path, bundle: bundle))
            return true
        }
        if first { Diagnostics.warn(missedNotice(path: path, bundle: bundle)) }
    }

    /// ``noteMissed(path:in:)`` の文面。
    static func missedNotice(path: String, bundle: String) -> String {
        "\"\(path)\" was not found in the bundles this run looks in, but \(bundle) beside the executable has it. "
            + "The mokume tool did not let this run look in \(bundle), because its name is not that of a target of "
            + "this product or of a dependency in Package.swift; running the executable without the tool looks in "
            + "every bundle (said once per bundle)"
    }

    /// 知らせた控え。**検査が読む。**
    static var missedSnapshot: WarningLog<String> { missed.withLock { $0.log } }
}
