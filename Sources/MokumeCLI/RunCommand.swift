// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// スケッチを作って走らせる。
enum RunCommand {
    /// 構成を渡さないときの名乗り。**道具立てへ渡す引数は変えない** — ここで名乗るのは
    /// 「この数字がどの土俵のものか」だけで、`BuildReport.configuration` と同じ言葉を使う。
    static let defaultConfigurationName = "debug"

    static func run(_ arguments: [String]) throws(CommandFailure) {
        let invocation = try Invocation.parse(arguments)
        let directory = invocation.directory
        let package = directory.appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: package.path) else {
            throw .packageNotFound(path: directory.path)
        }

        // **走らせる前に見る。** 宣言の抜けはビルドを通ってしまうので、ビルドの
        // 後では「通ったのに絵が出ない」形になる
        try ResourceDeclaration.check(in: directory)

        // どの道具で走らせているかを名乗る。**手元ビルドと配布版の取り違えは、解消済みの
        // 不具合を新しい不具合として起票させる** (#633 が実際にそうなった)。名乗りが help と
        // 切り分けの口にしか無いと、いちばん長く見ている画面に出ない (#684)
        print("道具: \(ToolVersion.describe())")
        if let notice = sharedSurfaceNotice(for: invocation) { print(notice) }

        try build(in: directory, configuration: invocation.configuration)
        let executable = try executablePath(in: directory, configuration: invocation.configuration)
        // 走らせるのは人なので、速さを名乗らせる。窓口はここを通らない。
        // **名乗る名前は、いま走らせる構成と同じ値から出す**
        try launch(executable, in: directory, reportingRate: invocation.configurationName)
    }

    /// 画面の出口が共有する面になっていることを名乗る 1 行。区画が無ければ `nil`。
    ///
    /// **黙って窓が出ないことを許さない。** 区画が在ればスケッチは窓を開かず共有面へ
    /// 差し出す。置いたのはふつう見張りで、見張りは終わるときに畳む — 残っているのは
    /// 畳めずに終わったときなので、そう言わないと「起動したのに何も出ない」になる。
    ///
    /// **見に行く先は、見張りが置く先と同じ計算から出す。** ここが自前で場所を組んで
    /// いたために、`MOKUME_WORK_DIR` を与えた環境ではまさにその「起動したのに何も
    /// 出ない」が名乗られないまま起きていた
    /// ([#791](https://github.com/mokume-metal/mokume/issues/791))。
    static func sharedSurfaceNotice(
        for invocation: Invocation, workDirectory: URL? = WorkDirectory.given
    ) -> String? {
        let base = invocation.facetBase(workDirectory: workDirectory)
        let facet = WatchCommand.viewportFacet(under: base)
        guard FileManager.default.fileExists(atPath: facet.path) else { return nil }
        // **在処をそのまま出す。** 基準は環境変数が動かせるので、`.mokume/…` とだけ
        // 言うとスケッチの場所を探して「無い」と読まれる (#791)
        return "画面の出口が共有する面になっている (\(facet.path) が在る) —"
            + " 窓は出ない。窓で見たいなら、その区画を消す"
    }

    /// 作り直す。出力はそのまま流す — 失敗したときに読むのは人なので、道具が
    /// 挟まって形を変えない方がよい。
    ///
    /// 構成を渡さないときは道具立ての既定に任せる。**既定を書き固めない** — ここが
    /// 名乗ると、道具立てが既定を変えたときに黙ってずれる。
    static func build(in directory: URL, configuration: String? = nil) throws(CommandFailure) {
        let status = try swift(
            ["build"] + configurationArguments(configuration), in: directory, capturing: false
        ).status
        guard status == 0 else { throw .buildFailed(status: status) }
    }

    /// 構成の指定を、道具立てへ渡す形にする。
    static func configurationArguments(_ configuration: String?) -> [String] {
        guard let configuration else { return [] }
        return ["-c", configuration]
    }

    /// 走らせるものの場所。
    ///
    /// **宣言された実行ファイルの product から名前を取る。** ビルドの出力を漁って
    /// それらしいものを選ぶと、product が増えたときに黙って別のものを起動する。
    static func executablePath(in directory: URL, configuration: String? = nil) throws(
        CommandFailure
    ) -> URL {
        let dump = try swift(["package", "dump-package"], in: directory, capturing: true).output
        guard let name = executableProductName(inDumpOf: dump) else {
            throw .noExecutable(path: directory.path)
        }
        let binPath = try swift(
            ["build", "--show-bin-path"] + configurationArguments(configuration), in: directory,
            capturing: true
        ).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(fileURLWithPath: binPath).appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw .noExecutable(path: url.path)
        }
        return url
    }

    /// `swift package dump-package` の中身から実行ファイルの product 名を取る。
    static func executableProductName(inDumpOf dump: String) -> String? {
        guard let data = dump.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let products = root["products"] as? [[String: Any]]
        else { return nil }
        for product in products {
            guard let name = product["name"] as? String else { continue }
            // 種別は {"executable": {...}} の形で入っている
            if let type = product["type"] as? [String: Any], type["executable"] != nil {
                return name
            }
        }
        return nil
    }

    /// 走らせる。終わるまで待ち、終了コードをそのまま引き継ぐ。
    ///
    /// - Parameter reportingRate: 速さを名乗らせるなら、**一緒に出す構成の名前**。
    ///   渡さなければスケッチは何も出さない ([ADR-0029] 決定 3)。
    ///
    /// [ADR-0029]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0029-post-run-surfaces.md
    static func launch(_ executable: URL, in directory: URL, reportingRate: String? = nil) throws(
        CommandFailure
    ) {
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        process.environment = childEnvironment(reportingRate: reportingRate)
        do {
            try process.run()
        } catch {
            throw .noExecutable(path: executable.path)
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            exit(process.terminationStatus)
        }
    }

    /// 子へ渡す環境。
    ///
    /// **読むのではなく運ぶ。** 親の環境をそのまま複製し、道具が決めるものだけを載せる —
    /// 世代の刻印 (観測が応答へ載せる) と、速さの名乗り (一緒に出す構成の名前)。渡され
    /// なかったものは**置かない**ので、受け取る側は「無ければ黙る」だけで済む。
    static func childEnvironment(
        _ base: [String: String] = ProcessInfo.processInfo.environment,
        stamp: String? = nil, reportingRate: String? = nil
    ) -> [String: String] {
        var environment = base
        if let stamp { environment[StartupReads.sourceStamp.key] = stamp }
        if let reportingRate { environment[StartupReads.frameRateNotice.key] = reportingRate }
        return environment
    }

    /// `swift` を呼ぶ。
    @discardableResult
    /// - Parameter discardingErrors: 道具立ての愚痴を捨てるか。**既定は流す** — 作り
    ///   直しの失敗はそこにしか出ないので、黙らせるのは出力そのものを人へ見せる呼び
    ///   出し (切り分けの口) だけにする。
    static func swift(
        _ arguments: [String], in directory: URL, capturing: Bool,
        discardingErrors: Bool = false
    ) throws(CommandFailure) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift"] + arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        if capturing {
            process.standardOutput = pipe
        }
        if discardingErrors {
            process.standardError = FileHandle.nullDevice
        }
        do {
            try process.run()
        } catch {
            throw .toolchainMissing("swift")
        }
        var output = ""
        if capturing {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            output = String(data: data, encoding: .utf8) ?? ""
        }
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
