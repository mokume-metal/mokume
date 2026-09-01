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

    /// 解決された版。読めなければ `nil`。
    ///
    /// 形式は SwiftPM の版 2 以降 (`pins` が根にある) を読む。ひな形は tools-version 6.2 を
    /// 宣言するので、それより古い形式は書かれない。
    static func resolved(forPackageAt package: URL) -> String? {
        let url = package.appendingPathComponent("Package.resolved")
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let pins = object["pins"] as? [[String: Any]]
        else { return nil }
        for pin in pins where pin["identity"] as? String == identity {
            return (pin["state"] as? [String: Any])?["version"] as? String
        }
        return nil
    }
}
