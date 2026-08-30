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
    case noExecutable(path: String)
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
    /// 署名に失敗した。
    case codesignFailed(status: Int32)

    var message: String {
        switch self {
        case .usage(let text):
            text
        case .nameMissing:
            "作るスケッチの名前が要る: \(Command.name) new <名前>"
        case .invalidName(let name):
            """
            スケッチの名前に使えない文字がある: \(name)
            英数字とハイフン・下線で始まる名前にする (先頭は英字)
            """
        case .directoryExists(let path):
            "すでにある: \(path)\n別の名前にするか、先に消す"
        case .cannotCreate(let path, let reason):
            "作れなかった: \(path)\n\(reason)"
        case .templatesMissing:
            """
            ひな形が見つからない。
            道具は実行ファイルと mokume_MokumeCLI.bundle の 2 つで 1 組で、ひな形は
            後者に入っている — 入れるときに片方だけ置いていないか確かめる
            """
        case .templateUnreadable(let name):
            "ひな形を読めない: \(name)"
        case .packageNotFound(let path):
            """
            スケッチが見つからない: \(path)
            Package.swift のあるディレクトリを指す (\(Command.name) new <名前> で作れる)
            """
        case .resourcesNotDeclared(let directory):
            """
            \(directory) に資材があるが、Package.swift が宣言していない。
            このまま走らせるとビルドは通り、実行時に読めないだけになる (絵が出ないのに
            描画側を疑うことになる)。target に 1 行足す:

              resources: [.copy("\(ResourceDeclaration.directoryName)")],

            資材として運ばない置き場なら、名前を変える。
            """
        case .identityMissing(let path):
            """
            束ねるには名乗りが要る。無い: \(path)

            \(AppIdentity.example)

            ひな形には入っていない。書かなくても走るが、書かないまま配ると事故になる
            もので、とくに識別子は権限の許可がぶら下がる鍵である — 仮の値のまま配ると、
            許可の状態が別の作品と混ざる。作品ごとに違う値を書く。
            """
        case .identityUnreadable(let path):
            """
            名乗りを読めない: \(path)
            JSON の形になっているか確かめる:

            \(AppIdentity.example)
            """
        case .identityIncomplete(let path, let missing):
            """
            名乗りに足りないものがある: \(path)
            書かれていない (または空): \(missing.joined(separator: " / "))

            \(AppIdentity.example)
            """
        case .bundledResourceMissing(let name, let path):
            """
            宣言された資材の包みが、組み上がりに入っていない: \(name)
            入れる場所: \(path)

            このまま配ると、受け取った側では絵が出ないだけで、原因を指すものが何も
            残らない。組み上げ直して、それでも入らないなら Package.swift の宣言と
            出来上がったものの名前が合っているかを見る。
            """
        case .codesignFailed(let status):
            """
            署名に失敗した (終了コード \(status))。上の出力を見る
            署名が無いと、別の機械では起動そのものが拒まれる
            """
        case .buildFailed(let status):
            "作り直しに失敗した (終了コード \(status))。上の出力を見る"
        case .noExecutable(let path):
            """
            走らせるものが見つからない: \(path)
            Package.swift の products に実行ファイルが宣言されているか確かめる
            """
        case .toolchainMissing(let tool):
            "\(tool) が見つからない。Xcode のコマンドラインツールを入れる"
        }
    }
}
