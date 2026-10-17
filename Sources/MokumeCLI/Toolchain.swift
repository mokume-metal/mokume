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
///
/// **main actor には置かない。** 見張りの作り直しは巡回とは別の糸から進むので、
/// そこから辿るものが隔離されていると待ちが main actor へ戻ってしまう
/// ([#1067](https://github.com/mokume-metal/mokume/issues/1067)・ADR-0010 決定 4)。
nonisolated enum Toolchain {
    /// 道具立てに聞いた結果。
    ///
    /// **聞いて答えなかった理由を捨てない** (#2522)。`doctor` が「could not launch swift」の
    /// 1 文しか持たなかった頃は、`swift` が `PATH` に無い回も、入れない場所で起こせなかった回も、
    /// 0 以外で終わった回も同じ文になり、人を Xcode の入れ直しへ向かわせていた。
    nonisolated enum Reading: Equatable {
        /// 名乗り 1 行 (`swift-driver version: …` など)。
        case version(String)
        /// 答えなかった。`reason` は人へ見せる 1 行で、**何が起きたかだけを言う**。
        case unanswered(reason: String)
    }

    /// 道具立てに聞いて、名乗りか、答えなかった理由を返す。**投げない。**
    ///
    /// 起こせなかった失敗は、子を起こす口が読み分けたもの (``RunCommand/launchFailure(of:error:executableMissing:)``・
    /// `env` 越しの 127) をそのまま理由にする。ここで読み替えない。
    ///
    /// - Parameter ask: 聞く口。**検査から偽の答え・失敗を渡せる形にしてある** — 聞く側は
    ///   `/usr/bin/env swift` を書き固めている (`PATH` を差し替えずに、127 の回を通すため)。
    static func read(
        in directory: URL,
        asking ask: (URL) throws(CommandFailure) -> (status: Int32, output: String) = {
            directory throws(CommandFailure) in
            try RunCommand.swift(["--version"], in: directory, capturing: true, errors: .discard)
        }
    ) -> Reading {
        let result: (status: Int32, output: String)
        do throws(CommandFailure) {
            result = try ask(directory)
        } catch {
            return .unanswered(reason: reason(for: error))
        }
        guard result.status == 0 else {
            return .unanswered(reason: "swift --version exited with code \(result.status)")
        }
        let first = result.output.split(separator: "\n").first.map(String.init)
        guard let trimmed = first?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else {
            return .unanswered(reason: "swift --version printed nothing")
        }
        return .version(trimmed)
    }

    /// 起こせなかった失敗を、道具立てを聞けなかった理由の 1 行にする。
    ///
    /// **`swift` が無いことと、無いとは言えないことを混ぜない。** 無いと言うのは
    /// ``CommandFailure/toolchainMissing(_:)`` (`env` が 127 で終わった) だけで、場所が使えない・
    /// OS の事情で起こせない回は、その理由を名乗る。
    static func reason(for failure: CommandFailure) -> String {
        switch failure {
        case .toolchainMissing(let tool):
            "\(tool) was not found on the PATH — install the Xcode command line tools"
        case .placeUnusable(let tool, let place, let presence):
            "\(tool) cannot start in \(place): \(presence.reason)"
        case .cannotLaunch(let tool, let place, let reason):
            "\(tool) could not start in \(place): \(reason)"
        default:
            failure.message
        }
    }

    /// 道具立ての名乗り 1 行。**答えなければ `nil`** (投げない)。
    ///
    /// 置き場の鍵が読む形で、`nil` は「共有しない」へ倒れる — 読めないことが黙って共有を
    /// 許すことにはならない。理由が要る読み手 (`doctor`) は ``read(in:)`` を使う。
    static func describe(in directory: URL) -> String? {
        guard case .version(let version) = read(in: directory) else { return nil }
        return version
    }
}
