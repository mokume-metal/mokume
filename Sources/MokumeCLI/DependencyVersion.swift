// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// スケッチが依存として解決している mokume の版。
///
/// ## なぜ 1 箇所に置くのか
///
/// 読み手は 2 つある — 版ごとの資産 (公開 API の一覧) を取りに行く側と、動かないときの
/// 切り分けの口である。**それぞれが自分で読むと、`Package.resolved` の形が変わった日に
/// 片方だけが追随する。**
///
/// ## なぜ切り分けの口が要るのか
///
/// 起動の瞬間に決まるものの一覧は「依存している mokume はこの面を持たない」とまで名乗る
/// ([DependencyFacets]) のに、**いくつなのかを言わない**。読み手は持っていないことは分かるが、
/// どこまで上げればよいかを知れない ([#684](https://github.com/mokume-metal/mokume/issues/684))。
///
/// ## 断定できないときは断定しない
///
/// パスで指した依存には pin が無いので `nil` を返す。開発中はこの形になる。
enum DependencyVersion {
    /// 依存の識別子。
    static let identity = "mokume"

    /// 何で固定されているか。
    ///
    /// **版と改訂を分ける。** 版が読めないことには 2 つの意味があり (枝や改訂で固定した /
    /// そもそもまだ解決されていない)、混ぜるとビルドの置き場の鍵が**違う改訂の mokume を
    /// 同じ部屋へ入れる** — 実測で、そうすると互いを作り直させ続けて増分ビルドが 1.6 秒
    /// から 8 秒へ落ちる ([#1055](https://github.com/mokume-metal/mokume/issues/1055))。
    enum Pin: Equatable {
        /// 版で固定されている。
        case version(String)
        /// 枝または改訂で固定されている。
        case revision(String)
    }

    /// 解決された版。読めなければ `nil`。
    ///
    /// 形式は SwiftPM の版 2 以降 (`pins` が根にある) を読む。ひな形は tools-version 6.2 を
    /// 宣言するので、それより古い形式は書かれない。
    static func resolved(forPackageAt package: URL) -> String? {
        if case .version(let version) = pin(forPackageAt: package) { return version }
        return nil
    }

    /// 何で固定されているか。固定が読めなければ `nil`。
    static func pin(forPackageAt package: URL) -> Pin? {
        let url = package.appendingPathComponent("Package.resolved")
        guard let resolved = SwiftPM.read(SwiftPM.Resolved.self, at: url) else { return nil }
        if let version = resolved.version(of: identity) { return .version(version) }
        if let revision = resolved.revision(of: identity) { return .revision(revision) }
        return nil
    }
}
