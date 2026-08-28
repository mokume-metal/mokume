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

    var message: String {
        switch self {
        case .usage(let text):
            text
        case .nameMissing:
            "作るスケッチの名前が要る: mokume-cli new <名前>"
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
            "ひな形が見つからない。道具のビルドが壊れている可能性がある"
        case .templateUnreadable(let name):
            "ひな形を読めない: \(name)"
        case .packageNotFound(let path):
            """
            スケッチが見つからない: \(path)
            Package.swift のあるディレクトリを指す (mokume-cli new <名前> で作れる)
            """
        case .resourcesNotDeclared(let directory):
            """
            \(directory) に資材があるが、Package.swift が宣言していない。
            このまま走らせるとビルドは通り、実行時に読めないだけになる (絵が出ないのに
            描画側を疑うことになる)。target に 1 行足す:

              resources: [.copy("\(ResourceDeclaration.directoryName)")],

            資材として運ばない置き場なら、名前を変える。
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
