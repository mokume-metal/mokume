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

        // **置き場は 1 度だけ決めて持ち回る。** 作り直しと実行ファイルの解決へ別々に
        // 判断を渡すと、片方が共有・片方がパッケージ直下という組み合わせになる
        let context = try context(in: directory, invocation: invocation)
        if let notice = context.place.notice { print(notice) }

        let executable = try buildAndResolve(in: directory, context: context)
        // 走らせるのは人なので、速さを名乗らせる。窓口はここを通らない。
        // **名乗る名前は、いま走らせる構成と同じ値から出す**
        try launch(executable, in: directory, reportingRate: context.configurationName)
    }

    /// 1 回の実行で 1 度だけ、置き場と構成と product を決める。
    ///
    /// **順序に意味がある。** 宣言 (`dump-package`) は置き場を 1 バイトも作らないので先に
    /// 読めるが、固定 (`Package.resolved`) は解決が済むまで存在しない。だから読めなかった
    /// ときだけ解決を 1 回打ち、それでも読めなければ共有しない — **推測して後から直す形は
    /// 採らない。** 推測は道具が最新でないときに必ず外れ、外れた置き場が 414MB のまま
    /// 掃除の当てなく残る。
    ///
    /// - Parameters:
    ///   - environment: 環境。**検査から渡せる形にしてある。**
    ///   - home: ホームディレクトリ。同上。
    static func context(
        in directory: URL, invocation: Invocation,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) throws(CommandFailure) -> BuildContext {
        let declared = try dumpPackage(in: directory)
        let product = declared?.executableProductName

        // **明示されたら理由を確かめない。** 選んだのは人である
        if let given = invocation.scratchPath {
            let url = URL(
                fileURLWithPath: NSString(string: given).expandingTildeInPath, isDirectory: true,
                relativeTo: directory)
            return BuildContext(
                configuration: invocation.configuration,
                place: .outside(url.standardizedFileURL, given: true), product: product)
        }

        // **宣言が読めないことを、断る理由にしない。** 壊した状態から直していく途中は
        // まさに見張っていてほしい場面である。共有はできないので、置き場は今までどおり
        // パッケージ直下に置く
        guard let declared else {
            return BuildContext(
                configuration: invocation.configuration,
                place: .inPackage(.unreadableManifest), product: nil)
        }

        let root = BuildDirectory.root(environment: environment, home: home)
        let toolchain = Toolchain.describe(in: directory)
        var pin = DependencyVersion.pin(forPackageAt: directory)
        var shareability = BuildDirectory.shareability(
            package: declared, pin: pin, toolchain: toolchain)
        // 足りないのが固定だけなら、1 回だけ解決して取り直す
        if shareability == .unshared(.unresolved) {
            resolveDependencies(in: directory, root: root)
            pin = DependencyVersion.pin(forPackageAt: directory)
            shareability = BuildDirectory.shareability(
                package: declared, pin: pin, toolchain: toolchain)
        }

        let place: BuildDirectory.Place
        switch shareability {
        case .unshared(let fallback):
            place = .inPackage(fallback)
        case .shareable(let name):
            let store = root.appendingPathComponent(name, isDirectory: true)
            switch BuildDirectory.claim(
                BuildDirectory.contestedNames(of: declared), for: directory, in: store)
            {
            case .free: place = .outside(store, given: false)
            case .taken(let owner): place = .inPackage(.nameTaken(by: owner))
            }
        }
        return BuildContext(
            configuration: invocation.configuration, place: place, product: product)
    }

    /// 依存を解決させて `Package.resolved` を書かせる。**失敗しても投げない** —
    /// 読めなければ共有しないだけで、ビルドそのものは次の段が同じ失敗を人へ見せる。
    ///
    /// **置き場は共有の 1 つに固定する。** 解決に積まれるのは依存の複製と prebuilt
    /// (実測 200MB) だけで、コンパイルの産物は 1 バイトも入らない — 取り違えようが
    /// 無いので、鍵で分ける理由が無い。
    private static func resolveDependencies(in directory: URL, root: URL) {
        let store = root.appendingPathComponent(
            BuildDirectory.resolveSegment, isDirectory: true)
        _ = try? swift(
            ["package", "resolve", "--scratch-path", store.path], in: directory,
            capturing: true, discardingErrors: true)
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

    /// 1 回の作り直しの結果。
    struct Rebuilt: Equatable {
        /// 作り直しの終了コード。
        let status: Int32
        /// 出力。**掴んだときだけ中身が入る** (流したときは空)。
        let output: String
        /// 走らせるもの。**建っていなければ `nil`** — 作り直しが通ったことと、走らせる
        /// ものが在ることは別である。
        let executable: URL?
        /// 出来上がりが置かれた場所。失敗を名乗るのに要る。
        let binPath: URL
    }

    /// 作り直して、走らせるものの場所を返す。
    ///
    /// ## 「在るか」ではなく「いま建ったか」を見る
    ///
    /// 置き場の計画が古いと、`swift build` は**「Build complete!」と言って実行ファイルを
    /// 1 つも作らない** ([#1055](https://github.com/mokume-metal/mokume/issues/1055) で
    /// 再現)。そのとき置き場に前の実行ファイルが残っていれば、存在を見るだけの検査は
    /// 通ってしまい、**中身が別のスケッチのものを起動する。**
    ///
    /// だから**先に消す。** 消えたものが建っていれば、それはこの作り直しの産物である。
    /// 代償は再リンク 1 回で、見張りは毎回ソースが変わるので追加の費用は無い
    /// (無変更のまま `run` を打ち直したときだけ増える)。
    ///
    /// - Parameter capturing: 出力を掴むか。**既定は流す** — 失敗の内容を読むのは人で、
    ///   道具が挟まって形を変えない方がよい。掴むのは記録へ載せる見張りだけである。
    static func rebuild(in directory: URL, context: BuildContext, capturing: Bool = false)
        throws(CommandFailure) -> Rebuilt
    {
        let bin = try binPath(in: directory, context: context)
        if let product = context.product {
            let executable = bin.appendingPathComponent(product, isDirectory: false)
            try? FileManager.default.removeItem(at: executable)
            try? FileManager.default.removeItem(
                at: bin.appendingPathComponent("\(product).dSYM", isDirectory: true))
        }

        let result = try swift(
            ["build"] + context.arguments, in: directory, capturing: capturing)

        // **名前が分からなかったときは、建った後に読み直す。** 宣言が直っていることが
        // あるためで、この経路の置き場は必ずパッケージ直下なので取り違えは起きない
        // (先に消せていないので「いま建った」までは言えないが、他人の産物も居ない)
        let product = context.product ?? (try? dumpPackage(in: directory))?.executableProductName
        guard let product else {
            return Rebuilt(status: result.status, output: result.output, executable: nil,
                binPath: bin)
        }
        let executable = bin.appendingPathComponent(product, isDirectory: false)
        let built = FileManager.default.isExecutableFile(atPath: executable.path)
        return Rebuilt(
            status: result.status, output: result.output, executable: built ? executable : nil,
            binPath: bin)
    }

    /// 作り直して、走らせるものを返す。**通らなければ投げる** (人へ見せる経路の形)。
    static func buildAndResolve(in directory: URL, context: BuildContext) throws(CommandFailure)
        -> URL
    {
        try executable(from: rebuild(in: directory, context: context), context: context,
            in: directory)
    }

    /// 作り直しの結果を、人へ見せる経路の形に読む。
    ///
    /// **3 つの失敗を混ぜない。** 作り直しが通らなかった / 通ったのに建っていない /
    /// そもそも走らせるものを決められない は、次の一手が違う。
    static func executable(from result: Rebuilt, context: BuildContext, in directory: URL)
        throws(CommandFailure) -> URL
    {
        guard result.status == 0 else { throw .buildFailed(status: result.status) }
        guard let executable = result.executable else {
            // 名前が分からないままだったのなら、宣言が読めていない — 走らせるものを
            // 決められないという、別の失敗である
            guard let product = context.product else {
                throw .noExecutable(path: directory.path)
            }
            throw .productNotBuilt(product: product, path: result.binPath.path)
        }
        return executable
    }

    /// 出来上がりが置かれる場所。**道具立てに聞く** — 置き場の中の構造を組み立てると、
    /// 道具立てが並びを変えた日に黙って別の場所を指す。
    static func binPath(in directory: URL, context: BuildContext) throws(CommandFailure) -> URL {
        let output = try swift(
            ["build", "--show-bin-path"] + context.arguments, in: directory, capturing: true
        ).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw .noExecutable(path: directory.path) }
        return URL(fileURLWithPath: output, isDirectory: true)
    }

    /// 構成の指定を、道具立てへ渡す形にする。
    static func configurationArguments(_ configuration: String?) -> [String] {
        guard let configuration else { return [] }
        return ["-c", configuration]
    }

    /// 走らせるものの場所。**建て直さずに、既に在るものを指す。**
    ///
    /// **宣言された実行ファイルの product から名前を取る。** ビルドの出力を漁って
    /// それらしいものを選ぶと、product が増えたときに黙って別のものを起動する。
    static func executablePath(in directory: URL, context: BuildContext) throws(CommandFailure)
        -> URL
    {
        guard let product = context.product else { throw .noExecutable(path: directory.path) }
        let url = try binPath(in: directory, context: context)
            .appendingPathComponent(product, isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw .noExecutable(path: url.path)
        }
        return url
    }

    /// パッケージの宣言を読む。**読めなければ `nil`。**
    ///
    /// 起こすのは重い (数百 ms) ので、同じ実行の中で 2 度要るときは呼び手が持ち回る。
    static func dumpPackage(in directory: URL) throws(CommandFailure) -> SwiftPM.Package? {
        let dump = try swift(["package", "dump-package"], in: directory, capturing: true).output
        return SwiftPM.package(inDumpOf: dump)
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
        // **窓の × は、確かめてから終わらせる。** 起こしたのが道具なので、押し間違いで
        // 消えるのは制作中の作品である ([#1120])。渡すのは自分の名乗りで、押した後どう
        // なるかを言う文面へそのまま入る
        //
        // [#1120]: https://github.com/mokume-metal/mokume/issues/1120
        process.environment = childEnvironment(
            reportingRate: reportingRate,
            confirmingCloseFor: "\(Command.name) \(Command.Verb.run.rawValue)")
        do {
            try process.run()
        } catch {
            throw .noExecutable(path: executable.path)
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw .sketchExited(status: process.terminationStatus)
        }
    }

    /// 子へ渡す環境。
    ///
    /// **読むのではなく運ぶ。** 親の環境をそのまま複製し、道具が決めるものだけを載せる —
    /// 世代の刻印 (観測が応答へ載せる) と、速さの名乗り (一緒に出す構成の名前)、そして
    /// 窓の × を確かめさせる合図。渡されなかったものは**置かない**ので、受け取る側は
    /// 「無ければ黙る」だけで済む。
    ///
    /// - Parameter confirmingCloseFor: 窓の × を押した人に確かめさせるなら、**自分の
    ///   名乗り**。見張り (`watch`) は渡さない — 子は窓を持たず、確認は道具の側が出す
    ///   ([ADR-0032] 決定 1)。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    static func childEnvironment(
        _ base: [String: String] = ProcessInfo.processInfo.environment,
        stamp: String? = nil, reportingRate: String? = nil, confirmingCloseFor tool: String? = nil
    ) -> [String: String] {
        var environment = base
        if let stamp { environment[StartupReads.sourceStamp.key] = stamp }
        if let reportingRate { environment[StartupReads.frameRateNotice.key] = reportingRate }
        if let tool { environment[StartupReads.closeConfirmation.key] = tool }
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
