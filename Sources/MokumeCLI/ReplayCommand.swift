// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 記録を画面なしで全速で流し、照らす (`replay <記録>`・#3571)。
///
/// ## 子がすること
///
/// ウィンドウも利用者の区画 (`observe` / `input` / `params`) も開かず、つまみの保存も読まず、画面を持たない全速の駆動で
/// 記録の回を流す。開始の状態 (つまみの値・作者の時計の秒と止めているか) を `setup()` の前に当て、回ごとに記録の入力・
/// つまみの値・時刻を指定した観測を当て、記録時の `expose` の値と画素のハッシュに照らす。読み手は `SketchApplication` で、
/// 合図は `StartupReads.replay` の環境変数 1 つである。作品のコードは 1 行も変えない。
///
/// ## 何を返すか
///
/// **終了コードと `.mokume/replay/report.json`** (`Schemas/replay-report.schema.json`)。照合がすべて一致すれば 0 で、
/// 食い違ったら、最初に食い違ったフレームの番号を名乗って 0 以外で終わる。作品の CI からは、この 2 つだけで使える
/// (MCP の道具・Swift の検査から呼ぶ口は足さない・#3571 の完了条件 9)。
enum ReplayCommand {
    /// 解いた引数。
    struct Options: Equatable {
        /// 走らせる部分 (場所・構成・置き場)。`run` と同じ解き方で解く。
        var invocation: Invocation
        /// 記録のファイル。**絶対パスになっている** — 子の作業ディレクトリはスケッチの場所である。
        var record: String
    }

    static func run(_ arguments: [String]) throws(CommandFailure) {
        // **ビルドの前に解き、記録も読む。** 引数の誤りと読めない記録を、数分のビルドの後で知らせない
        let options = try parse(arguments)
        // **前の回の結果を最初に消す** — 記録が読めない・ビルドや起動が落ちた回に、前の回の結果を今回のものとして読ませない
        let report = try reportURL(for: options.invocation)
        try discardPreviousReport(report)
        do {
            _ = try ReplayRecord.read(from: URL(fileURLWithPath: options.record))
        } catch {
            throw .recordUnreadable(reason: error.reason)
        }
        let directory = try options.invocation.directory
        let package = directory.appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: package.path) else {
            throw .packageNotFound(path: directory.path)
        }
        print("Tool: \(ToolVersion.describe())")
        let context = try RunCommand.context(
            in: directory, invocation: options.invocation,
            afterReading: ResourceDeclaration.checking(in: directory))
        if let notice = context.place.notice { print(notice) }
        let executable = try RunCommand.buildAndResolve(in: directory, context: context)
        try replay(executable, in: directory, record: options.record, report: report)
    }

    /// 結果のファイルの場所 (区画 `replay` の `report.json`)。子が書く先 (`ReplayPlayer.defaultReport`) と同じ計算。
    static func reportURL(for invocation: Invocation) throws(CommandFailure) -> URL {
        WorkDirectory.facet("replay", under: try invocation.facetBase()).appendingPathComponent("report.json")
    }

    /// 前の回が残した結果を消す。**消せなければ流さない** — 残った結果は今回のものと見分けが付かない。
    static func discardPreviousReport(_ report: URL) throws(CommandFailure) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: report.path) else { return }
        do {
            try manager.removeItem(at: report)
        } catch {
            throw .replayReportStale(path: report.path, reason: error.localizedDescription)
        }
    }

    /// 走らせて、今回の結果のファイルが書かれたことまで確かめる。**呼ぶ前に前の回の結果を消してある**
    /// (``discardPreviousReport(_:)``) ので、在る結果は今回の子が書いたものである。
    ///
    /// 子の終了コードは「照合がすべて一致したか」を言う。
    /// - 0 以外で終わって結果が在る: 子が食い違い・流せなかった理由を書いた (``CommandFailure/replayDiffered(report:ending:)``)
    /// - 0 以外で終わって結果が無い: 流す前に落ちた (GPU・起動・合図を読まない古い子)。ほかの道具の「子が失敗した」と
    ///   同じ失敗をそのまま返す
    /// - 0 で終わって結果が無い: 合図を読まずにウィンドウを開いて 0 で終わる古い版の子で、何も照らしていない
    static func replay(
        _ executable: URL, in directory: URL, record: String, report: URL,
        launch: (URL, URL, [String: String]) throws(CommandFailure) -> Void = { executable, directory, environment
            throws(CommandFailure) in
            try RunCommand.launch(executable, in: directory, environment: environment)
        }
    ) throws(CommandFailure) {
        try discardPreviousReport(report)
        let written = { FileManager.default.fileExists(atPath: report.path) }
        do {
            try launch(executable, directory, RunCommand.childEnvironment(replaying: record))
        } catch {
            guard written() else { throw error }
            switch error {
            case .sketchExited(let status):
                throw .replayDiffered(report: report.path, ending: .exited(status))
            case .sketchSignalled(let signal):
                throw .replayDiffered(report: report.path, ending: .signalled(signal))
            default:
                throw error
            }
        }
        guard written() else { throw .replayReportMissing(path: report.path) }
        print("Report: \(report.path)")
    }

    // MARK: - 引数

    /// 引数を解く。**最初の 1 つが記録** で、残りは `run` と同じ (場所・`-c`・`--scratch-path`)。
    ///
    /// - Parameter currentDirectory: 相対パスを解く基準。**打った場所である** — 子の作業ディレクトリはスケッチの場所
    ///   なので、記録は渡す前に絶対パスにする (`render` の `--out` と同じ・#2320)。
    static func parse(
        _ arguments: [String], currentDirectory: URL? = GivenPath.currentDirectory
    ) throws(CommandFailure) -> Options {
        if arguments.contains(where: { Arguments.helpSpellings.contains($0) }) { throw .helpRequested }
        guard let first = arguments.first, !first.hasPrefix("-"), !first.isEmpty else {
            throw .usage(
                "\(Command.name) \(Command.Verb.replay.rawValue) needs a record first:\n"
                    + "  \(Command.name) \(Command.Verb.replay.rawValue) take.json")
        }
        let record = try GivenPath.resolve(first, from: currentDirectory, isDirectory: false).path
        let (invocation, _) = try Invocation.parse(
            Array(arguments.dropFirst()), adding: [], from: currentDirectory)
        return Options(invocation: invocation, record: record)
    }
}
