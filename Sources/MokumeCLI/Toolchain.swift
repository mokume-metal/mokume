// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 道具立て (Swift) の名乗り。
///
/// ## なぜ切り分けの口から出したのか
///
/// 読み手が 2 つになった。**切り分けの口**は人へ見せるために読み、**ビルドの置き場**は
/// 鍵の一部にするために読む — 置き場の 55% (モジュールキャッシュと prebuilt) は
/// 道具立ての産物なので、版が動いたものを同じ部屋へ入れると硬い失敗になる
/// ([ADR-0037])。
///
/// 別々に読むと、片方が読み方を変えた日にもう片方が追随しない。**綴りはここ 1 箇所。**
///
/// [ADR-0037]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0037-shared-build-directory.md
enum Toolchain {
    /// 道具立ての名乗り 1 行。**起動できなければ黙って諦める** (投げない)。
    ///
    /// 切り分けの口の規律に従う — 断定できないときは断定しない。置き場のほうは `nil` を
    /// 「共有しない」へ倒すので、読めないことが黙って共有を許すことにはならない。
    static func describe(in directory: URL) -> String? {
        guard
            let result = try? RunCommand.swift(
                ["--version"], in: directory, capturing: true, errors: .discard),
            result.status == 0
        else { return nil }
        let first = result.output.split(separator: "\n").first.map(String.init)
        let trimmed = first?.trimmingCharacters(in: .whitespaces)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}
