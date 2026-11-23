// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import Synchronization

/// 資材を探すときに、実行ファイルの隣に並んでいても**探さない包み** (#4038)。
///
/// `run`・`watch` のビルドの置き場は、利用者の `swift build` / `swift test` や同じ鍵の別のスケッチと共有なので、
/// 実行ファイルの隣には、いまの宣言に無い包み (改名する前のパッケージ名・消した target・外した依存・テストの
/// target・別のスケッチの包み) も並ぶ。資材の探索 (``ImageFile/search(for:)``) は隣の包みをパスの順に見るので、
/// 名前の順で先に来るそれらの包みの同じ相対パスの資材を、黙って読みうる。
///
/// どの包みがいまの宣言のものかは、宣言と依存の木を読める道具にしか分からないので、道具が探さない包みの名前を
/// 子へ渡す (``StartupReads/undeclaredBundles``)。**渡されなければ、隣の包みを全部探す** (いままでどおり)。
package nonisolated enum UndeclaredBundles {
    /// 値の中の名前の区切り。包みの名前は 1 段のファイル名なので `/` を含まない。
    package static let separator: Character = "/"

    /// 合図を読んだか、読んだ値。**一度だけ控える** — 読んだら環境から消すので、2 度目からは環境に無い。
    private struct Taken {
        var done = false
        var value: Set<String> = []
    }

    private static let taken = Mutex(Taken())

    /// 道具が渡した、探さない包みの名前。**無ければ空。** main で初めて呼んだときに環境から読んで消し、控える。
    ///
    /// **環境を読むのはここだけ** — 一覧 ([StartupReads]) が読み場所としてこのファイルを名指している。
    /// **読んだら環境から消す** (``ShaderOrigin/startup()`` と同じ)。合図はこのプロセスを起こした道具が
    /// 自分の置き場の並びから決めたもので、このプロセスがさらに起こす子のものではない — 継がせると、別の置き場で
    /// 走る孫が、そこに在る包みを外してしまう。読むのは `SketchApplication` の組み立てで、スケッチの `setup()` より
    /// 前である (資材を探さないスケッチ・探す前に子を起こすスケッチでも消える)。
    ///
    /// **消すのは main で 1 度だけ。** 資材の探索 (``ImageFile/search(for:)``) も組み立てを通らない入口の保険として
    /// ここを呼ぶが、探索は待たない読み込みの裏の仕事や音の糸からも来る。main の外では環境を読むだけで消さず、
    /// 控えもしない (`unsetenv` を、環境を読むほかの糸と競わせない)。
    ///
    /// - Parameter onMain: いま main で呼ばれているか。**検査が main の外を装うために渡せる形にしてある。**
    package static func startup(onMain: Bool = Thread.isMainThread) -> Set<String> {
        taken.withLock { taken in
            if taken.done { return taken.value }
            guard onMain else { return names(from: ProcessInfo.processInfo.environment) }
            taken.value = take()
            taken.done = true
            return taken.value
        }
    }

    /// 控えを捨てる。**検査だけが呼ぶ** — 本番は起動の瞬間に 1 度読んだきりである。
    static func forgetStartup() {
        taken.withLock { $0 = Taken() }
    }

    /// 合図を読み、環境から消す。
    static func take(
        from environment: [String: String] = ProcessInfo.processInfo.environment,
        unset: (String) -> Void = { unsetenv($0) }
    ) -> Set<String> {
        let names = names(from: environment)
        if environment[StartupReads.undeclaredBundles.key] != nil { unset(StartupReads.undeclaredBundles.key) }
        return names
    }

    /// 環境に載った合図を解く。空の名前・`.bundle` で終わらない名前は捨てる (包みの名前でないものを
    /// 名指しても、探す側の並びには現れない)。
    static func names(from environment: [String: String]) -> Set<String> {
        guard let given = environment[StartupReads.undeclaredBundles.key] else { return [] }
        return Set(
            given.split(separator: separator).map(String.init).filter { $0.hasSuffix(".bundle") })
    }

    /// 外した包みにだけ在った資材の知らせの控え。鍵は包みの名前で、数は道具が渡した名前の数を越えない。
    private static let missed = Mutex(WarningLog<String>())

    /// 探した資材がどこにも無く、外した包み `bundle` の中にだけ在ったことを、**包みごとに 1 度**知らせる。
    ///
    /// 外す包みは道具が名前の形 (依存の宣言の名前で始まるか) から決めるので、取り違えて依存の包みを外すと、資材は
    /// 「見つからない」とだけ言われる。そのとき作者が原因へ辿れるように、外した包みと、その外し方を名乗る。投げる
    /// 失敗 (``AssetFailure/notFound(path:searched:)`` など) は変えない。
    static func noteMissed(path: String, in bundle: String) {
        let first = missed.withLock { log -> Bool in
            guard !log.hasWarned(bundle) else { return false }
            log.record(bundle, missedNotice(path: path, bundle: bundle))
            return true
        }
        if first { Diagnostics.warn(missedNotice(path: path, bundle: bundle)) }
    }

    /// ``noteMissed(path:in:)`` の文面。
    static func missedNotice(path: String, bundle: String) -> String {
        "\"\(path)\" is in \(bundle), which the mokume tool left out of the asset search for this run, "
            + "because no target of this product and no dependency in Package.swift seemed to build it. "
            + "If it should be read, report it as a bug; running the executable without the tool looks in every bundle "
            + "(said once per bundle)"
    }

    /// 知らせた控え。**検査が読む。**
    static var missedSnapshot: WarningLog<String> { missed.withLock { $0 } }

    /// 合図の値を組む (道具の側が使う)。名前の順に並べる — 同じ集合から同じ値が出る。
    package static func value(of names: Set<String>) -> String? {
        let valid = names.filter { $0.hasSuffix(".bundle") && !$0.contains(separator) }
        return valid.isEmpty ? nil : valid.sorted().joined(separator: String(separator))
    }
}
