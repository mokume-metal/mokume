// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 道具が返す失敗。
///
/// 起こりうるものを列挙できるので typed throws で運ぶ ([ADR-0010] 決定 7)。
/// **どの失敗にも「次に何をすればよいか」を書く** — 道具の失敗は人が読んで直すもの
/// なので、状態の報告だけでは足りない。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
enum CommandFailure: Error, Equatable {
    case usage(String)
    case nameMissing
    case invalidName(String)
    case directoryExists(path: String)
    case cannotCreate(path: String, reason: String)
    case templatesMissing
    case templateUnreadable(name: String)
    case packageNotFound(path: String)
    case buildFailed(status: Int32)
    /// 走らせたスケッチが 0 以外で終わった。**道具の失敗ではない。**
    case sketchExited(status: Int32)
    case noExecutable(path: String)
    /// 作り直しは通ったのに、走らせるものが建っていない。
    ///
    /// **「ビルドが成功した」とは別の失敗である。** 置き場の計画が古いと道具立ては
    /// 「Build complete!」と言って実行ファイルを 1 つも作らないので、終了コードだけを
    /// 見ていると成功として通り、置き場に残っていた**別のスケッチの実行ファイル**を
    /// 起動することになる ([#1055](https://github.com/mokume-metal/mokume/issues/1055))。
    case productNotBuilt(product: String, path: String)
    case toolchainMissing(String)

    /// 資材の置き場があるのに、パッケージが宣言していない。
    case resourcesNotDeclared(directory: String)
    /// 束ねようとしたが、名乗りが置かれていない。
    case identityMissing(path: String)
    /// 名乗りは在るが、読める形をしていない。
    case identityUnreadable(path: String)
    /// 名乗りに、名乗れる中身が揃っていない。
    case identityIncomplete(path: String, missing: [String])
    /// 宣言された資材の包みが、組み上がりに入っていない。
    case bundledResourceMissing(name: String, path: String)
    /// 区画へ要求を置けなかった。
    case facetUnwritable(path: String, reason: String)
    /// 署名に失敗した。
    case codesignFailed(status: Int32)

    /// 道具が返す終了コード。
    ///
    /// **`run` だけが子の終了コードを引き継ぐ。** 呼ぶ側が見ているのは道具の成否では
    /// なくスケッチの成否なので、そのまま通す。ほかは道具自身の失敗なので 1 でよい。
    var exitCode: Int32 {
        if case .sketchExited(let status) = self { status } else { 1 }
    }

    var message: String {
        switch self {
        case .usage(let text):
            text
        case .nameMissing:
            "The sketch needs a name: \(Command.name) new <name>"
        case .invalidName(let name):
            """
            That name has characters a sketch cannot use: \(name)
            Use letters, digits, hyphens and underscores, and start with a letter
            """
        case .directoryExists(let path):
            "Already there: \(path)\nPick another name, or remove that one first"
        case .cannotCreate(let path, let reason):
            "Could not create: \(path)\n\(reason)"
        case .templatesMissing:
            """
            Cannot find the templates.
            The tool is two pieces that belong together — the executable and
            mokume_MokumeCLI.bundle — and the templates live in the second one.
            Check that the install put both in place, not just one
            """
        case .templateUnreadable(let name):
            "Cannot read the template: \(name)"
        case .packageNotFound(let path):
            """
            Cannot find a sketch here: \(path)
            Point at a directory that has Package.swift (\(Command.name) new <name> makes one)
            """
        case .resourcesNotDeclared(let directory):
            """
            \(directory) holds assets, but Package.swift does not declare them.
            Running as is will build fine and only fail to read them once the sketch is
            drawing (nothing appears, and the drawing code takes the blame). Add one line
            to the target:

              resources: [.copy("\(ResourceDeclaration.directoryName)")],

            If that directory is not meant to ship as assets, rename it.
            """
        case .identityMissing(let path):
            """
            Bundling needs an identity. There is none at: \(path)

            \(AppIdentity.example)

            The templates do not ship one. A sketch runs without it, but shipping without
            it causes trouble later: the identifier is the key that granted permissions
            hang from, so leaving a placeholder in place mixes one work's permissions with
            another's. Give every work its own values.
            """
        case .identityUnreadable(let path):
            """
            Cannot read the identity: \(path)
            Check that it is well-formed JSON:

            \(AppIdentity.example)
            """
        case .identityIncomplete(let path, let missing):
            """
            The identity is missing something: \(path)
            Absent or empty: \(missing.joined(separator: " / "))

            \(AppIdentity.example)
            """
        case .bundledResourceMissing(let name, let path):
            """
            A declared asset bundle did not make it into the build: \(name)
            Where it belongs: \(path)

            Ship this and the other side gets no drawing and nothing that points at why.
            Build again; if it still does not appear, check that the declaration in
            Package.swift and the name of what was built agree.
            """
        case .facetUnwritable(let path, let reason):
            """
            Could not place the request: \(path)
            \(reason)

            Check that the directory can be written to and that the disk has room.
            MOKUME_WORK_DIR moves it (pass the same value to the runner and to the
            interface, or the two look in different places)
            """
        case .codesignFailed(let status):
            """
            Signing failed (exit code \(status)). Read the output above
            Without a signature, another machine refuses to open it at all
            """
        case .buildFailed(let status):
            "The build failed (exit code \(status)). Read the output above"
        case .sketchExited(let status):
            """
            The sketch exited with code \(status).
            This is not a failure the tool added — the reason is in the sketch's own output
            """
        case .noExecutable(let path):
            """
            Cannot find anything to run: \(path)
            Check that Package.swift declares an executable in products
            """
        case .productNotBuilt(let product, let path):
            """
            The build succeeded, but \(product) was never built: \(path)
            A stale plan left in the build directory can do this — remove that directory
            and try again
            """
        case .toolchainMissing(let tool):
            "Cannot find \(tool). Install the Xcode command line tools"
        }
    }
}
