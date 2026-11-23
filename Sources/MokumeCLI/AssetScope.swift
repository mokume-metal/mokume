// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import mokume

/// 走らせる子に**探させてよい**資材の包み (#4038)。
///
/// `run`・`watch`・`render`・`replay` のビルドの置き場は、利用者の `swift build` / `swift test` や同じ鍵の別の
/// スケッチと共有なので、実行ファイルの隣にはいまの宣言に無い包みも並び、後からも増える。子の資材の探索は隣の包みを
/// パスの順に見るので、名前の順で先に来るそれらの包みの同じ相対パスの資材を黙って読みうる。
///
/// 子へは**許す一覧** (``AssetBundles/Allowance``) を渡す: 実行 product の閉包の target の包みの名前と、依存の
/// パッケージの名前の頭。求めるのは `bundle` が写す包みと同じ閉包・同じ依存の名前・同じ問い
/// (``BundleCommand/dependencyTree(of:place:asking:)``) からで、宣言・product・閉包・依存の木のどれかが読めなければ
/// 渡さない (子は隣の包みを全部探す)。
///
/// **依存の木の答えは置き場に控える** (``Record``)。問うのは、隣に自分の閉包の包みでも直接の依存の identity でも
/// 説明できない包みが在り、しかも鍵の合う控えが無いときだけ — 共有の置き場には別のスケッチの包みが並ぶので、
/// 控えが無いと `run` のたびに `swift` を 1 本起こす (1.1〜1.6 秒・実測)。外した包みの名乗りも、前の回に名乗った
/// 集合から変わったときだけ出す。
nonisolated enum AssetScope {
    /// 道具立てへの問い (引数と場所を受けて終了コードと標準出力を返す)。
    typealias Asking = @Sendable (_ arguments: [String], _ directory: URL) -> (status: Int32, output: String)

    /// 子に渡す探してよい包みを決め、要れば 1 行名乗る。**`run`・`render`・`replay` (``RunCommand/prepare(in:context:say:asking:building:)``)
    /// と `watch` (``Carried``) の 4 つの口が、ここだけを通る。**
    ///
    /// - 宣言・product・閉包が読めない: 渡さない (`nil`・全部探す)。名乗らない (宣言の読めなさは別の段が名乗る)
    /// - 隣の包みが、閉包の target の包みと直接の依存の identity で全部説明できる: 依存の木を問わずに決まる
    /// - 説明できない包みが在る: 鍵の合う控えの依存の名前を使う。無ければ 1 行名乗って問い、答えを控える。
    ///   問えなかった回は渡さず (全部探す)、そう 1 行名乗る (``unscopedNotice``)
    /// - 外す包みが前の回に名乗った集合から変われば、1 行名乗る (``notice(_:)``)
    ///
    /// - Parameters:
    ///   - context: 導いた土台。読んだ宣言 (``BuildContext/declared``)・置き場・道具立ての名乗りを使う。
    ///   - executable: 建った実行ファイル。隣の並びを読む。
    ///   - package: パッケージの場所。依存の木はここで、`context` の置き場について問う。
    ///   - say: 名乗りの行き先。
    ///   - asking: 道具立てへの問い。**検査が偽の答えを渡すために外から渡せる形にしてある。**
    ///   - tool: 道具の印 (控えの鍵・``toolStamp()``)。**検査が道具の版の違いを装うために渡せる形にしてある。**
    static func settle(
        context: BuildContext, executable: URL, package: URL, say: (String) -> Void,
        asking: Asking = BundleCommand.askSwiftPM, tool: String = toolStamp()
    ) -> AssetBundles.Allowance? {
        guard let declared = context.declared, let product = context.product,
            let closure = declared.targetClosure(ofProduct: product)
        else { return nil }
        let built = BundleCommand.resourceBundles(besides: executable, excluding: []).map(\.lastPathComponent)
        let url = recordURL(context: context, package: package)
        let owner = BuildDirectory.ownerPath(of: package)
        let stored = Record.read(at: url, package: owner)
        var record = stored ?? Record(package: owner)
        defer { if record != stored { try? AtomicFile.writeJSON(record, to: url) } }

        var dependencyNames: [String] = []
        if !declared.leftoverCandidates(forProduct: product, beside: built).isEmpty {
            if let names = record.answer(tool: tool, toolchain: context.toolchain) {
                dependencyNames = names
            } else {
                say(askingLine)
                guard
                    let tree = BundleCommand.dependencyTree(of: package, place: context.place, asking: asking),
                    let names = tree.dependencyNames
                else {
                    record.announced = []
                    say(unscopedNotice)
                    return nil
                }
                dependencyNames = names
                record.remember(tree, names: names, package: package, tool: tool, toolchain: context.toolchain)
            }
        }
        let bundles = declared.targets.filter { closure.contains($0.name) }.map { declared.bundleName(of: $0) }
        guard
            let allowance = AssetBundles.Allowance(
                bundles: bundles, packages: declared.dependencies.compactMap(\.identity) + dependencyNames)
        else {
            record.announced = []
            say(unscopedNotice)
            return nil
        }
        let excluded = built.filter { !allowance.allows($0) }.sorted()
        if excluded != record.announced {
            record.announced = excluded
            if let notice = notice(Set(excluded)) { say(notice) }
        }
        return allowance
    }

    /// 依存の木を問う前の 1 行。依存の解決を始める前の名乗り (`RunCommand.resolvingLine`) と同じく、始まりだけを言う。
    static let askingLine =
        "Reading the dependencies of Package.swift to choose the asset bundles the sketch looks in"
        + " (once, until Package.swift or Package.resolved changes)"

    /// 探してよい包みを決められなかった回の 1 行。**黙って全部探さない** — `bundle` が `Kept:` と名乗るのと同じ向き。
    static let unscopedNotice =
        "Looking for assets in every bundle in the build folder: could not read the dependencies of Package.swift"
        + " (swift package show-dependencies) or pass their names to the sketch"

    /// 名乗りに並べる名前の数の上限。共有の置き場には別のスケッチの包みが多く並びうるので、1 行に収める。
    static let listedLimit = 5

    /// 探させない包みの名乗り (1 行)。無ければ `nil`。**黙って外さない** — 名前の形から推した除外なので、
    /// 依存の包みを取り違えて外したときに、絵が出ない理由を辿れるようにする。
    ///
    /// **言うのは、外したという事実だけ** — 古いとも要らないとも言わない。共有の置き場では、別のスケッチの現役の
    /// 包みもここに入るので、それを古い包みのように見せない。
    static func notice(_ names: Set<String>) -> String? {
        guard !names.isEmpty else { return nil }
        let sorted = names.sorted()
        var listed = sorted.prefix(listedLimit).joined(separator: ", ")
        if sorted.count > listedLimit { listed += " and \(sorted.count - listedLimit) more" }
        let counted = sorted.count == 1 ? "1 bundle" : "\(sorted.count) bundles"
        return "Not looking for assets in \(counted) in the build folder that are not from this product"
            + " or its dependencies: \(listed)"
    }

    // MARK: - 控え

    /// 道具の印 (控えの鍵)。走っている道具の実行ファイルの在処と大きさと更新時刻で、入れ替えれば変わる。
    /// 読めなければ毎回違う値にする (控えを信じない)。
    static func toolStamp() -> String {
        guard let executable = Bundle.main.executableURL,
            let values = try? executable.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
            let size = values.fileSize, let modified = values.contentModificationDate
        else { return UUID().uuidString }
        return "\(executable.path) \(size) \(modified.timeIntervalSince1970)"
    }

    /// 控えを置くディレクトリの名前 (置き場の直下)。
    static let recordSegment = "asset-scope"

    /// 控えの場所。置き場 (共有なら別のスケッチと同じ) の下で、**パッケージの根ごとに別のファイル**にする。
    static func recordURL(context: BuildContext, package: URL) -> URL {
        let owner = BuildDirectory.ownerPath(of: package)
        let hash = SHA256.hash(data: Data(owner.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return context.place.directory(under: package)
            .appendingPathComponent(recordSegment, isDirectory: true)
            .appendingPathComponent("\(hash).json", isDirectory: false)
    }

    /// 依存の木の答えと、前の回に名乗った外す包みの控え。
    ///
    /// **鍵が合わなければ答えを使わない** (問い直す)。鍵は、控えの形の版・道具の印 (``AssetScope/toolStamp()``)・道具立ての名乗りと、
    /// 根と依存の木に載ったすべての依存の在処の、宣言のファイル (``manifestNames(in:)``) の中身の印。パスの依存の
    /// `Package.swift` の改名、`--local` での行き先の切り替え、版の固定の変更はどれも印を変える。読めない・壊れた・
    /// 別の形の版の控えは無いものとして扱う (``read(at:package:)``)。
    struct Record: Codable, Equatable {
        /// 控えの形の版。形を変えたら上げる。
        static let currentFormat = 1

        var format = Record.currentFormat
        /// パッケージの根 (``BuildDirectory/ownerPath(of:)``)。ファイル名の印の衝突で、別のスケッチの控えを読まない。
        var package: String
        /// 依存の木の答えの鍵。答えが無ければ `nil`。
        var key: Key?
        /// 依存の木の答え (``SwiftPM/DependencyTree/dependencyNames``)。
        var dependencyNames: [String]?
        /// 前の回に名乗った外す包み (名前の順)。
        var announced: [String] = []

        struct Key: Codable, Equatable {
            var tool: String
            var toolchain: String?
            /// 在処ごとの、宣言のファイルの中身の印。
            var manifests: [String: String]
        }

        init(package: String) {
            self.package = package
        }

        /// 控えを読む。**読めない・形の版が違う・別のパッケージのものなら `nil`。**
        static func read(at url: URL, package: String) -> Record? {
            guard let record = SwiftPM.read(Record.self, at: url), record.format == currentFormat,
                record.package == package
            else { return nil }
            return record
        }

        /// 鍵の合う答え。**合わなければ `nil`** — 道具・道具立ての名乗りか、どこかの在処の宣言のファイルが変わった。
        func answer(tool: String, toolchain: String?) -> [String]? {
            guard let key, let dependencyNames, key.tool == tool, key.toolchain == toolchain,
                let current = Record.manifests(of: Array(key.manifests.keys)), current == key.manifests
            else { return nil }
            return dependencyNames
        }

        /// 問うた答えを控える。依存の在処が 1 つでも読めなければ、答えは控えない (次の回に問い直す)。
        mutating func remember(
            _ tree: SwiftPM.DependencyTree, names: [String], package: URL, tool: String, toolchain: String?
        ) {
            let paths = tree.paths
            guard paths.count == tree.dependencyCount + 1,
                let manifests = Record.manifests(of: paths + [package.standardizedFileURL.path])
            else {
                key = nil
                dependencyNames = nil
                return
            }
            key = Key(tool: tool, toolchain: toolchain, manifests: manifests)
            dependencyNames = names
        }

        /// 在処ごとの宣言のファイルの中身の印。**1 つでも読めなければ `nil`** (鍵にしない)。
        static func manifests(of directories: [String]) -> [String: String]? {
            var digests: [String: String] = [:]
            for directory in directories {
                guard let digest = digest(of: directory) else { return nil }
                digests[directory] = digest
            }
            return digests
        }

        /// 在処 1 つの宣言のファイルの名前と中身の印。ディレクトリが読めなければ `nil`。
        static func digest(of directory: String) -> String? {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
            var hasher = SHA256()
            for name in names.filter(isManifest).sorted() {
                guard let data = FileManager.default.contents(atPath: (directory as NSString).appendingPathComponent(name))
                else { return nil }
                hasher.update(data: Data(name.utf8))
                hasher.update(data: Data([0]))
                hasher.update(data: Data(SHA256.hash(data: data)))
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        /// 宣言のファイルか: `Package.swift`・`Package@swift-*.swift`・`Package.resolved`。
        static func isManifest(_ name: String) -> Bool {
            name == "Package.swift" || name == "Package.resolved"
                || (name.hasPrefix("Package@swift-") && name.hasSuffix(".swift"))
        }
    }

    // MARK: - 見張り

    /// 見張りの世代をまたいで、子に渡す探してよい包みを持ち回る。作り直しの糸から書き、子を起こす口から読むので、
    /// 鍵で守る。決めるのは毎回 ``settle(context:executable:package:say:asking:tool:)`` で、問いと名乗りを
    /// 減らすのは置き場の控えである。
    final class Carried: @unchecked Sendable {
        private let lock = NSLock()
        private var allowance: AssetBundles.Allowance?
        private let asking: Asking

        /// - Parameter asking: 道具立てへの問い。省けば本物を起こす。
        init(asking: @escaping Asking = BundleCommand.askSwiftPM) {
            self.asking = asking
        }

        /// 作り直しの後の段取り: **建った回だけ**決め直す。建たなかった回は前の値を持ち回る (子は前の実行ファイルの
        /// まま走る)。
        func afterRebuild(_ rebuilt: RunCommand.Rebuilt, context: BuildContext, package: URL, say: (String) -> Void) {
            guard rebuilt.status == 0, let executable = rebuilt.executable else { return }
            let decided = AssetScope.settle(
                context: context, executable: executable, package: package, say: say, asking: asking)
            lock.withLock { allowance = decided }
        }

        /// 次に起こす子に渡す、探してよい包み。
        var current: AssetBundles.Allowance? { lock.withLock { allowance } }
    }
}
