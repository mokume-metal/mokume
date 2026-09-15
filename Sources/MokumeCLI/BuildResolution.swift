// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// 宣言から導いたもの。**土台と置き場を抱き合わせて 1 つで持つ。**
///
/// 別々に持てる形にすると、片方だけ持ち回って**古い置き場に新しい product を探す**
/// 組み合わせが書けてしまう。`BuildContext` が構成と置き場と product を抱き合わせて
/// いるのと同じ理由である (#680)。
nonisolated struct BuildResolution: Equatable {
    /// 作るときの土台 (構成と置き場と product)。
    let context: BuildContext
    /// 出来上がりが置かれる場所。
    let binPath: URL
}

/// 宣言が変わるまで、導いたものを持ち回る。
///
/// ## なぜ持ち回るのか
///
/// 導くには `swift` を 2 本起こす — `swift package dump-package` (宣言) と
/// `swift build --show-bin-path` (置き場)。どちらも数百 ms かかり、**見張りはこれを
/// 作り直しのたびに払っていた** ([#1067](https://github.com/mokume-metal/mokume/issues/1067))。
/// 手元の実測で `--show-bin-path` が毎回 315 ms・同じ回の作り直しが 1.7 秒なので、
/// **保存してから絵が変わるまでの約 19%** がここだった。
///
/// ## なぜ「1 回だけ」ではなく「宣言が変わるまで」なのか
///
/// 導いたものは全部 `Package.swift` から出る — product の名前も、置き場を共有できるかの
/// 鍵 (依存と対応環境) も。**編集されたら古くなる。** 持ち回ったままにすると、product の
/// 名前を変えた回に前の名前の実行ファイルを探し、「建っていない」と名乗ることになる
/// (#1067 の完了条件 3)。
///
/// 見張りは `Package.swift` も監視しているので (``SourceStamp/sources(in:)``)、編集は
/// 必ず作り直しとして届く。そこで世代を見比べれば、**変わった回だけ**導き直せる。
///
/// ## 世代は中身から導く
///
/// 時刻や大きさで振ると、**中身を変えずに保存しただけ**の回に `swift` を 2 本起こすことに
/// なる — 編集器は保存のたびに時刻を進めるので、珍しい操作ではない。``SourceStamp`` が
/// 監視しているソース全体に対してやっているのと同じ流儀で、ここは `Package.swift`
/// 1 枚を見る。
///
/// **持ち回るのは最新の 1 つだけである。** 書き換えて元に戻した回は、宣言が実際に 2 度
/// 変わっているので 2 度導く — 過去の世代を溜めても、`Package.swift` を往復させる編集で
/// しか効かない。
nonisolated final class BuildResolver: @unchecked Sendable {
    /// スケッチのパッケージの場所。
    private let directory: URL
    /// 宣言から導く手続き。**注入するのは検査のためだけではない** — 導くのに `swift` を
    /// 起こすことを、この型自身が知らずに済む。
    private let resolve: (URL) throws(CommandFailure) -> BuildResolution

    /// 鍵。導くのは作り直しの糸 (`Task.detached`) からで、持ち回る値はそこで書き換わる。
    private let lock = NSLock()
    /// 導いたときの `Package.swift` の世代。**読めなければ `nil`。**
    private var stamp: String?
    /// 持ち回っているもの。
    private var carried: BuildResolution?

    /// - Parameter resolve: 宣言から導く手続き。既定は `swift` を 2 本起こす本物。
    init(
        directory: URL,
        resolve: @escaping (URL) throws(CommandFailure) -> BuildResolution
    ) {
        self.directory = directory
        self.resolve = resolve
    }

    /// いまの宣言に合ったもの。**宣言が変わっていなければ、`swift` を 1 本も起こさない。**
    func current() throws(CommandFailure) -> BuildResolution {
        let stamp = Self.manifestStamp(in: directory)
        if let carried = lock.withLock({ self.stamp == stamp ? carried : nil }) { return carried }

        let resolution = try resolve(directory)
        lock.withLock {
            self.stamp = stamp
            carried = resolution
        }
        return resolution
    }

    /// `Package.swift` の世代。**読めなければ `nil`。**
    ///
    /// 読めない回に `nil` を持ち回るのは正しい — 宣言が読めない間は導いたものも
    /// 「宣言が読めなかった」という同じ結論になるので、読めるようになった回に
    /// 世代が変わって導き直される。
    private static func manifestStamp(in directory: URL) -> String? {
        let manifest = directory.appendingPathComponent("Package.swift")
        guard let contents = try? Data(contentsOf: manifest) else { return nil }
        return SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
    }
}

extension BuildResolver {
    /// `swift` を起こして導く、本物の手続きで組む。
    ///
    /// - Parameter running: 走っている `swift` を外から止められるように掴む先。
    ///   **見張りだけが渡す** (#1147)。
    static func live(
        in directory: URL, invocation: Invocation, running: RunningBuild? = nil
    ) -> BuildResolver {
        BuildResolver(directory: directory) { directory throws(CommandFailure) in
            let context = try RunCommand.context(in: directory, invocation: invocation)
            return BuildResolution(
                context: context,
                binPath: try RunCommand.binPath(
                    in: directory, context: context, running: running))
        }
    }
}
