// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import Synchronization
import mokume

/// 走らせているスケッチの番号。**居なければ 0。**
///
/// **シグナルのハンドラから読むので、置き場はグローバルに 1 つ。** ハンドラは文脈を
/// 捕まえられない ([#1171](https://github.com/mokume-metal/mokume/issues/1171))。
/// `private` にしないのは検査から読むため (`watchStopRequested` と同じ作法)。
nonisolated var runChildPID: pid_t {
    get { runChildPIDCell.load(ordering: .relaxed) }
    set { runChildPIDCell.store(newValue, ordering: .relaxed) }
}

/// ``runChildPID`` の実体。**受け口 (任意の糸で走る) が読み、main が書く**ので、素の変数ではなく
/// atomic にする (#3234 の反証)。受け口はこの実体を直に読む。
nonisolated let runChildPIDCell = Atomic<pid_t>(0)

/// 受けた終わりの合図の番号。**受けていなければ 0。**
nonisolated(unsafe) var runStopSignal: sig_atomic_t = 0

/// スケッチを作って走らせる。
enum RunCommand {
    /// 道具だけへ届いたら、スケッチへも渡す合図。`run` も `render` もこれを受ける。
    ///
    /// **道具の PID だけに送る経路で孤児が残る。** 既定のままだと道具だけが死に、
    /// スケッチは launchd に付け替えられて窓ごと残る — エージェントやスクリプトが止める
    /// 経路で実際に踏んだ ([#1171](https://github.com/mokume-metal/mokume/issues/1171))。
    ///
    /// **端末の Control + C (SIGINT) もこの経路である。** `Process` は子を別のプロセス
    /// グループに置く (`ps -o pgid` で確かめた) ので、端末が前面のグループへ配る SIGINT は
    /// 道具にしか届かない。受けずにいると道具だけがその場で終わり、スケッチが残る
    /// ([#1618](https://github.com/mokume-metal/mokume/issues/1618))。
    ///
    /// **無視で継いだ SIGINT には置かない。** 背面 (`&`) で起こされた起動の約束で、子も同じ
    /// 無視を継ぐので、両方が同じく受け流す (子の側の規則は `StopSignals` と同じ)。
    ///
    /// - Parameter current: いまの SIGINT の受け口。**検査から渡す** — 既定はこのプロセスのもの。
    nonisolated static func stopSignals(sigint current: sigaction = currentAction(SIGINT))
        -> [Int32]
    {
        StopSignals.isIgnored(current) ? [SIGTERM, SIGHUP] : [SIGTERM, SIGHUP, SIGINT]
    }

    /// その合図のいまの受け口。
    nonisolated static func currentAction(_ number: Int32) -> sigaction {
        var action = sigaction()
        sigaction(number, nil, &action)
        return action
    }

    /// 構成を渡さないときの名乗り。**道具立てへ渡す引数は変えない** — ここで名乗るのは
    /// 「この数字がどの土俵のものか」だけで、`BuildReport.configuration` と同じ言葉を使う。
    nonisolated static let defaultConfigurationName = "debug"

    static func run(_ arguments: [String]) throws(CommandFailure) {
        let invocation = try Invocation.parse(arguments)
        let directory = try invocation.directory
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
        print("Tool: \(ToolVersion.describe())")
        if let notice = try sharedSurfaceNotice(for: invocation) { print(notice) }

        // **置き場は 1 度だけ決めて持ち回る。** 作り直しと実行ファイルの解決へ別々に
        // 判断を渡すと、片方が共有・片方がパッケージ直下という組み合わせになる
        let context = try context(in: directory, invocation: invocation)
        if let notice = context.place.notice { print(notice) }

        let executable = try buildAndResolve(in: directory, context: context)
        // 走らせるのは人なので、速さを名乗らせる。窓口はここを通らない。
        // **名乗る名前は、いま走らせる構成と同じ値から出す**
        //
        // **窓の × は、確かめてから終わらせる。** 起こしたのが道具なので、押し間違いで
        // 消えるのは制作中の作品である ([#1120])。渡すのは自分の名乗りで、押した後どう
        // なるかを言う文面へそのまま入る
        //
        // [#1120]: https://github.com/mokume-metal/mokume/issues/1120
        try launch(
            executable, in: directory,
            environment: childEnvironment(
                reportingRate: context.configurationName,
                confirmingCloseFor: "\(Command.name) \(Command.Verb.run.rawValue)"))
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
    ///   - announce: 依存の解決を始める前に、その待ちを名乗る先 (#3427)。既定は標準出力へ 1 行。
    ///     **見張りは自分の書き方 (`WatchCommand.say`) を渡す** — 速さの行が書き換え続けている
    ///     最中に素の `print` で書くと、行の途中から続いて読めなくなる (#685)。
    ///   - resolver: 解決の `swift` を起こす手。**検査から偽の手を渡せる形にしてある。**
    ///
    /// ## main actor の外で走る
    ///
    /// **導き直しは作り直しの糸から来る。** 宣言が変わった回にここを main actor で走らせると、
    /// `dump-package` と `--show-bin-path` のあいだ画面が凍る — 作り直し本体を外へ出した
    /// のと同じ理由である ([#834](https://github.com/mokume-metal/mokume/issues/834)・
    /// [#1067](https://github.com/mokume-metal/mokume/issues/1067))。触るのは `Process` と
    /// `FileManager` と環境変数だけで、main actor の状態は読まない (ADR-0010 決定 4)。
    nonisolated static func context(
        in directory: URL, invocation: Invocation,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        announce: (String) -> Void = { print($0) },
        resolver: (_ arguments: [String], _ directory: URL) -> Void = launchResolve
    ) throws(CommandFailure) -> BuildContext {
        let declared = try dumpPackage(in: directory)
        let product = declared?.executableProductName
        // **束に写される置き場は宣言から決める** (#2517)。読めなければ決められない
        let assets =
            declared?.assetsOrigin(
                forProduct: product, in: directory, directoryName: ResourceDeclaration.directoryName)
            ?? .undecided

        // **明示されたら理由を確かめない。** 選んだのは人である。解く基準は走らせた場所で、
        // 解くのは ``Invocation`` の 1 か所 (#2323)
        if let given = try invocation.scratchDirectory {
            return BuildContext(
                configuration: invocation.configuration,
                place: .outside(given, given: true), product: product, assets: assets)
        }

        // **宣言が読めないことを、断る理由にしない。** 壊した状態から直していく途中は
        // まさに見張っていてほしい場面である。共有はできないので、置き場は今までどおり
        // パッケージ直下に置く
        guard let declared else {
            return BuildContext(
                configuration: invocation.configuration,
                place: .inPackage(.unreadableManifest), product: nil, assets: assets)
        }

        let root = try BuildDirectory.root(
            environment: environment, home: home, currentDirectory: invocation.currentDirectory)
        let toolchain = Toolchain.describe(in: directory)
        var pin = DependencyVersion.pin(forPackageAt: directory)
        var shareability = BuildDirectory.shareability(
            package: declared, pin: pin, toolchain: toolchain)
        // 足りないのが固定だけなら、1 回だけ解決して取り直す
        if shareability == .unshared(.unresolved) {
            resolveDependencies(in: directory, root: root, announce: announce, resolver: resolver)
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
            configuration: invocation.configuration, place: place, product: product, assets: assets)
    }

    /// 依存を解決させて `Package.resolved` を書かせる。**失敗しても投げない** —
    /// 読めなければ共有しないだけで、ビルドそのものは次の段が同じ失敗を人へ見せる。
    ///
    /// **置き場は共有の 1 つに固定する。** 解決に積まれるのは依存の複製と prebuilt
    /// (実測 200MB) だけで、コンパイルの産物は 1 バイトも入らない — 取り違えようが
    /// 無いので、鍵で分ける理由が無い。
    ///
    /// **始める前に 1 行名乗る** (#3427)。初回は依存を取りに行くので数秒かかり (空の置き場で
    /// 3.4 秒の実測)、`Tool:` の行の後が無音になる。名乗るのは始まりの 1 行だけで、
    /// 測れない進みは名乗らない。標準エラーを流して名乗りの代わりにしない — 捨てるのは、
    /// 失敗を次のビルドが見せる設計による。
    nonisolated private static func resolveDependencies(
        in directory: URL, root: URL, announce: (String) -> Void,
        resolver: (_ arguments: [String], _ directory: URL) -> Void
    ) {
        let store = root.appendingPathComponent(
            BuildDirectory.resolveSegment, isDirectory: true)
        announce(resolvingLine)
        resolver(["package", "resolve", "--scratch-path", store.path], directory)
    }

    /// 依存を解決する前に名乗る 1 行 (#3427)。
    nonisolated static let resolvingLine =
        "Resolving the sketch's dependencies… (the first one takes a while)"

    /// 本物の解決。標準出力を掴み、標準エラーを捨て、失敗しても投げない。
    nonisolated static func launchResolve(_ arguments: [String], in directory: URL) {
        _ = try? swift(arguments, in: directory, capturing: true, errors: .discard)
    }

    /// 見張りの区画が残っている場所で `run` したときに名乗る 1 行。区画が無ければ `nil`。
    ///
    /// **走らせるスケッチのライブラリの版で、起きることが違う** ([#2028])。いまの
    /// ライブラリは窓の持ち主の合図 (`StartupReads.viewportOwner`) が無ければ区画を見ずに
    /// 自分の窓を開き、そのことを自分で名乗る。合図を知らない古いライブラリは区画だけを
    /// 見て共有面へ差し出すので、**窓が出ず、ライブラリの側からは何も言わない** — 黙って
    /// 窓が出ないことを許さない (#791) ために、道具の側でも 1 行言う。いまのライブラリと
    /// 名乗りが 2 行重なるのは、版を推し量って黙るより害が小さい (どの版で変わったかを
    /// 道具は版の番号から言い切れない)。
    ///
    /// **見に行く先は、見張りが置く先と同じ計算から出す。** ここが自前で場所を組んで
    /// いたために、`MOKUME_WORK_DIR` を与えた環境では「起動したのに何も出ない」が
    /// 名乗られないまま起きていた ([#791](https://github.com/mokume-metal/mokume/issues/791))。
    ///
    /// [#2028]: https://github.com/mokume-metal/mokume/issues/2028
    static func sharedSurfaceNotice(
        for invocation: Invocation, workDirectory: URL? = WorkDirectory.given
    ) throws(CommandFailure) -> String? {
        let base = try invocation.facetBase(workDirectory: workDirectory)
        let facet = WatchCommand.viewportFacet(under: base)
        guard FileManager.default.fileExists(atPath: facet.path) else { return nil }
        // **在処をそのまま出す。** 基準は環境変数が動かせるので、`.mokume/…` とだけ
        // 言うとスケッチの場所を探して「無い」と読まれる (#791)
        return "\(facet.path) is there (left by mokume watch). A sketch on the current "
            + "mokume opens its own window anyway; one on an older mokume hands its frames "
            + "there and no window opens — update the mokume it depends on, or remove that facet"
    }

    /// 1 回の作り直しの結果。
    nonisolated struct Rebuilt: Equatable {
        /// 作り直しの終了コード。
        let status: Int32
        /// 出力。**掴んだときだけ中身が入る** (流したときは空)。
        let output: String
        /// 走らせるもの。**建っていなければ `nil`** — 作り直しが通ったことと、走らせる
        /// ものが在ることは別である。
        let executable: URL?
        /// 出来上がりが置かれた場所。失敗を名乗るのに要る。
        let binPath: URL
        /// この回が探した product の名前。**宣言が読めなければ `nil`。**
        ///
        /// **持ち回った名前ではなく、この回の名前である。** 見張りは宣言が変わった回に
        /// 導き直すので (``BuildResolver``)、セッション開始時の名前で「建っていない」と
        /// 名乗ると、`Package.swift` で product を改名した回に**前の名前**を出すことに
        /// なる ([#1067](https://github.com/mokume-metal/mokume/issues/1067))。
        let product: String?
        /// 宣言を読み直したときに、道具立てが答えなかった・答えが読めなかった理由。**それ以外は `nil`。**
        ///
        /// **`product == nil` が 3 つを混ぜていた** (#2575): 宣言に実行ファイルが無い・宣言が読めない・
        /// 道具立てが答えなかった。人へ見せる口は、この理由があればそれを名乗り、「Package.swift を
        /// 見よ」とは言わない。持ち回った `nil` (見張りを続けるための値) とは別に、**この回に読み直して
        /// 分かったことだけ**を持つ。
        var declarationFailure: CommandFailure? = nil
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
    ///
    /// ## main actor の外で走る
    ///
    /// `Package.swift` は全ターゲットへ `.defaultIsolation(MainActor.self)` を敷いているので、
    /// 黙っていればここも main actor 隔離になる — そして見張りは**巡回の中からこれを呼ぶ**
    /// ので、`swift build` を待つ間じゅう画面が凍る
    /// ([#834](https://github.com/mokume-metal/mokume/issues/834))。
    ///
    /// 隔離を外すのは ADR-0010 決定 4 の「main actor の外で進める処理は明示的に分離する」で、
    /// **触るのは `Process` と `FileManager` だけ**である (main actor の状態は読まない)。
    ///
    /// - Parameter running: 走っている `swift` を外から止められるように掴む先。**見張りだけが
    ///   渡す** — 終わるときに作り直しを止める者は見張りにしか居ない
    ///   ([#1147](https://github.com/mokume-metal/mokume/issues/1147))。
    /// - Parameter binPath: 既に分かっている置き場。**渡されたら道具立てに聞き直さない** —
    ///   聞くのに `swift` を 1 本起こすので、作り直しのたびに払うと保存から絵が変わるまでに
    ///   丸ごと乗る (手元の実測で 315 ms・[#1067](https://github.com/mokume-metal/mokume/issues/1067))。
    ///   持ち回ってよいかを判断するのは呼び手で、見張りは ``BuildResolver`` がそれを担う。
    nonisolated static func rebuild(
        in directory: URL, context: BuildContext, capturing: Bool = false,
        running: RunningBuild? = nil, binPath: URL? = nil
    )
        throws(CommandFailure) -> Rebuilt
    {
        // **`??` で畳まない。** 右辺が投げるので、まとめると誤りの型が `any Error` へ落ちる
        // (typed throws・ADR-0010 決定 7 と同じ理由)
        let bin: URL
        if let binPath {
            bin = binPath
        } else {
            bin = try self.binPath(in: directory, context: context, running: running)
        }
        if let product = context.product {
            for previous in previousArtifacts(of: product, in: bin) {
                try? FileManager.default.removeItem(at: previous)
            }
        }

        // **診断は stderr にしか出ない。** 掴む形 (watch) では混ぜないと、記録に
        // 失敗の本文が載らない (#731)
        let result = try swift(
            ["build"] + context.arguments, in: directory, capturing: capturing,
            errors: .merge, running: running)

        // **名前が分からなかったときは、建った後に読み直す。** 宣言が直っていることが
        // あるためで、この経路の置き場は必ずパッケージ直下なので取り違えは起きない
        // (先に消せていないので「いま建った」までは言えないが、他人の産物も居ない)
        let (product, declarationFailure) = try productAfterBuild(
            context: context, in: directory, running: running)
        guard let product else {
            return Rebuilt(status: result.status, output: result.output, executable: nil,
                binPath: bin, product: nil, declarationFailure: declarationFailure)
        }
        return Rebuilt(
            status: result.status, output: result.output,
            executable: builtExecutable(named: product, in: bin), binPath: bin, product: product)
    }

    /// 作り直しの後に使う product の名前。**宣言が読めていなければ、建った後に読み直す。**
    ///
    /// **読めなかった理由を捨てない** (#2575)。`try?` は起こせなかった・場所が使えない失敗を
    /// `nil` に化かし、人には「走らせるものが無い (Package.swift を見よ)」と届いた。道具立てが
    /// 答えなかった回・答えが読めなかった回は、名前を `nil` のまま、**その理由を返す** — 宣言が
    /// 読めないまま進む形は変えず (作り直しは通っている)、人へ見せる口が「Package.swift を見よ」と
    /// 言う代わりに理由を名乗れるようにする。
    ///
    /// - Parameter declaring: 宣言を読む口。**検査から偽の答えを渡せる形にしてある。**
    nonisolated static func productAfterBuild(
        context: BuildContext, in directory: URL, running: RunningBuild? = nil,
        declaring: (URL, RunningBuild?) throws(CommandFailure) -> Declaration = {
            directory, running throws(CommandFailure) in
            try declaration(in: directory, running: running)
        }
    ) throws(CommandFailure) -> (product: String?, failure: CommandFailure?) {
        if let known = context.product { return (known, nil) }
        let read = try declaring(directory, running)
        return (read.package?.executableProductName, read.failure)
    }

    /// 作り直しが先に消してよい、置き場 `bin` の直下にある自分の前の産物。
    ///
    /// **消してよいのは `<product>` と `<product>.dSYM` だけで、どちらも置き場の直下にあるときに
    /// 限る** (消す理由は「前の版が残ると、いま建ったかを言えない」で、置き場の外へ出る理由は
    /// 無い)。product の名前は `Package.swift` から来るので、`..`・`.` や `/` を含む名前は
    /// 置き場の外・置き場そのものを指し、そのまま `removeItem` に渡すと置き場の親や置き場を
    /// 丸ごと消す ([#2502](https://github.com/mokume-metal/mokume/issues/2502)・実測した)。
    /// 外れたものは消さずに作り直しへ進む (消せなかった回と同じ扱い)。
    ///
    /// `bundle` の `assemble` が「作る場所が `--out` の直下でなければ何も消さない」を名前の検めと
    /// 独立に置くのと同じ形である (#2309・#2504)。
    nonisolated static func previousArtifacts(of product: String, in bin: URL) -> [URL] {
        [product, "\(product).dSYM"].compactMap { directChild($0, of: bin) }
    }

    /// 置き場 `bin` の直下にある `name` の場所。**直下でなければ `nil`。**
    ///
    /// **ファイルの在る・無しに左右されない、字面だけの判定にする。** `standardizedFileURL` は
    /// 在るパスの先頭 `/private` を外し、在らないパスはそのまま返すので、`/tmp`・`/var` 配下の置き場
    /// で、行き先の無い symlink (`bin/<product>` が dangling) を従来は消せたのに守りが空を返した。
    /// `bin` に `name` を足した字面を `.`・`..` を畳んで部品に割り、親の部品列が `bin` の
    /// 部品列と等しく、最後の部品が名前そのものであることを見る。`sub/../victim` は畳むと
    /// `bin` の直下を指すが、最後の部品が名前と違うので外れる。返すのは畳まない `bin/<name>` で、
    /// OS が解く先は `bin` の中の 1 部品になる。
    nonisolated static func directChild(_ name: String, of bin: URL) -> URL? {
        let home = foldedComponents(of: bin.path)
        let target = foldedComponents(of: bin.path + "/" + name)
        guard !name.isEmpty, !name.contains("\0"), target.last == name,
            Array(target.dropLast()) == home
        else { return nil }
        return bin.appendingPathComponent(name, isDirectory: false)
    }

    /// パスを `/` で割り、`.` を落とし `..` を 1 つ戻す。
    nonisolated private static func foldedComponents(of path: String) -> [String] {
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(part))
            }
        }
        return parts
    }

    /// 作り直しで建った実行ファイル。**無ければ `nil`。**
    ///
    /// 「建った」と言うのは、置き場の直下にある**通常のファイルで実行できるもの**だけである。
    /// `isExecutableFile` はディレクトリにも真を返すので、直下を指さない名前 (`..`・`sub/../victim`)
    /// や、ディレクトリを指す名前を通すと、消さなくなった分だけ `bin` の親などが「建った実行
    /// ファイル」として返る ([#2502](https://github.com/mokume-metal/mokume/issues/2502))。
    nonisolated static func builtExecutable(named product: String, in bin: URL) -> URL? {
        guard let url = directChild(product, of: bin) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: url.path)
        else { return nil }
        return url
    }

    /// 作り直して、走らせるものを返す。**通らなければ投げる** (人へ見せる経路の形)。
    static func buildAndResolve(in directory: URL, context: BuildContext) throws(CommandFailure)
        -> URL
    {
        try executable(from: rebuild(in: directory, context: context), in: directory)
    }

    /// 作り直しの結果を、人へ見せる経路の形に読む。
    ///
    /// **3 つの失敗を混ぜない。** 作り直しが通らなかった / 通ったのに建っていない /
    /// そもそも走らせるものを決められない は、次の一手が違う。
    ///
    /// **名前は結果から読む。** 作り直しが探したのと同じ名前で名乗らないと、宣言が
    /// 変わった回に前の名前で「建っていない」と言うことになる (#1067)。
    static func executable(from result: Rebuilt, in directory: URL)
        throws(CommandFailure) -> URL
    {
        guard result.status == 0 else { throw .buildFailed(status: result.status) }
        guard let executable = result.executable else {
            // 名前が分からないままだったのなら、宣言が読めていない — 走らせるものを
            // 決められないという、別の失敗である
            guard let product = result.product else {
                // 読み直して分かった理由があれば、それを名乗る (#2575)。無ければ、宣言に実行
                // ファイルが無い
                if let failure = result.declarationFailure { throw failure }
                throw .noExecutable(path: directory.path)
            }
            // **在るのに起こせないものを「建っていない」と言わない** (#2521)。作り直しは
            // 実行できるものだけを「建った」と返すので、実行ビットの無い成果物もここへ来る
            if let reason = unrunnableProduct(product, in: result.binPath) {
                throw .cannotLaunch(tool: product, place: directory.path, reason: reason)
            }
            throw .productNotBuilt(product: product, path: result.binPath.path)
        }
        return executable
    }

    /// 作り直しが「建った」と返さなかった product が、置き場に**在るのに起こせない**なら、その
    /// 理由 (在処を含む 1 行)。無ければ `nil` (本当に建っていない)。
    ///
    /// **置き場の直下を指す名前だけを見る。** `/` や `.`・`..` を含む名前は置き場の外や置き場
    /// そのものを指すので、そこに在るものを「起こせない成果物」とは言わない。
    nonisolated static func unrunnableProduct(_ product: String, in bin: URL) -> String? {
        guard !product.isEmpty, !product.contains("/"), product != ".", product != ".." else {
            return nil
        }
        guard case .unrunnable(let reason) = standing(
            of: bin.appendingPathComponent(product, isDirectory: false))
        else { return nil }
        return reason
    }

    /// 出来上がりが置かれる場所。**道具立てに聞く** — 置き場の中の構造を組み立てると、
    /// 道具立てが並びを変えた日に黙って別の場所を指す。
    nonisolated static func binPath(
        in directory: URL, context: BuildContext, running: RunningBuild? = nil
    )
        throws(CommandFailure) -> URL
    {
        let asked = ["build", "--show-bin-path"] + context.arguments
        // **愚痴を混ぜない。** 出力はファイルパスとして解くので、警告 1 行で別の
        // 場所を指すことになる (#731)
        let answer = try swift(
            asked, in: directory, capturing: true, errors: .inherit, running: running)
        return try binPath(from: answer, asking: asked)
    }

    /// `--show-bin-path` の答えを読む。**検査から偽の子の答えを渡せる形にしてある** —
    /// 聞く側は `/usr/bin/env swift` を書き固めている (#731)。
    ///
    /// **終了コードを見る。** 0 で終わって道を答えたときだけ読み、それ以外は道具立てが
    /// 答えなかったと名乗る。空の出力だけを見て ``CommandFailure/noExecutable(path:)`` と
    /// 読んでいた頃は、道具立てが引数を断った回を「Package.swift に実行ファイルが無い」と
    /// 言っていた ([#2316](https://github.com/mokume-metal/mokume/issues/2316))。
    ///
    /// - Parameter arguments: 聞いたときに `swift` へ渡したもの。答えなかったときに名乗る。
    nonisolated static func binPath(
        from answer: (status: Int32, output: String), asking arguments: [String]
    ) throws(CommandFailure) -> URL {
        let output = answer.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard answer.status == 0, !output.isEmpty else {
            throw .toolchainFailed(
                command: (["swift"] + arguments).joined(separator: " "), status: answer.status)
        }
        return URL(fileURLWithPath: output, isDirectory: true)
    }

    /// 構成の指定を、道具立てへ渡す形にする。
    nonisolated static func configurationArguments(_ configuration: String?) -> [String] {
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
        let bin = try binPath(in: directory, context: context)
        guard let built = builtExecutable(named: product, in: bin) else {
            throw .noExecutable(path: bin.appendingPathComponent(product).path)
        }
        return built
    }

    /// パッケージの宣言を読んだ結果。
    nonisolated enum Declaration: Equatable {
        /// 読めた。
        case declared(SwiftPM.Package)
        /// 道具立てが答えなかった (0 以外で終わった)。`Package.swift` を道具立てが読めなかった
        /// 回もここへ来る — 理由は道具立てが標準エラーで名乗っている。
        case unanswered(status: Int32)
        /// 0 で終わったが、出力が宣言として読めなかった (道具立てが JSON の形を変えた日)。
        case unreadable

        /// 読めなかった回の名乗り。**宣言の不備として名乗らない** (#2483)。読めたなら `nil`。
        var failure: CommandFailure? {
            switch self {
            case .declared: nil
            case .unanswered(let status):
                .toolchainFailed(command: RunCommand.dumpCommand, status: status)
            case .unreadable: .declarationUnreadable(command: RunCommand.dumpCommand)
            }
        }

        /// 読めた宣言。**読めなければ `nil`** — 見張りが宣言の壊れた状態でも続けるための形。
        var package: SwiftPM.Package? {
            guard case .declared(let package) = self else { return nil }
            return package
        }
    }

    /// 宣言を読むために `swift` へ聞くこと。答えなかったときに名乗る。
    nonisolated static let dumpCommand = "swift package dump-package"

    /// パッケージの宣言を読む。**読めなければ `nil`。**
    ///
    /// `nil` は「宣言が読めない」として見張りを続けるための形で、`run` / `watch` / `render` は
    /// そのまま持ち回る (壊した状態から直していく途中は、まさに見張っていてほしい)。**読めなかった
    /// 理由が要る口は ``declaration(in:running:)`` を使う** (`bundle` — #2483)。
    ///
    /// 起こすのは重い (数百 ms) ので、同じ実行の中で 2 度要るときは呼び手が持ち回る。
    nonisolated static func dumpPackage(
        in directory: URL, running: RunningBuild? = nil
    ) throws(CommandFailure) -> SwiftPM.Package? {
        try declaration(in: directory, running: running).package
    }

    /// パッケージの宣言を読み、**読めなかった理由を分けて返す**。
    ///
    /// 起こせなかった・場所が使えない・道具立てが無い回は、子を起こす口が読み分けたとおり投げる。
    /// 道具立てが答えなかった回 (0 以外での終了) と、答えたが読めない回は、値で返す — 続けるか
    /// 止めるかは呼び手が決める。
    nonisolated static func declaration(
        in directory: URL, running: RunningBuild? = nil
    ) throws(CommandFailure) -> Declaration {
        // **愚痴を混ぜない。** 出力は JSON として厳密に解くので、警告 1 行で黙って
        // 読めなくなる (#731)
        let answer = try swift(
            ["package", "dump-package"], in: directory, capturing: true, errors: .inherit,
            running: running)
        return declaration(from: answer)
    }

    /// `dump-package` の答えを読む。**検査から偽の子の答えを渡せる形にしてある。**
    ///
    /// **終了コードを先に見る。** 0 以外で終わった回の出力は JSON でなく、`nil` に畳むと、
    /// 道具立てが答えなかったことが「宣言が読めない」→「走らせるものが無い」と読み替わる
    /// ([#2483](https://github.com/mokume-metal/mokume/issues/2483)・`binPath(from:asking:)` と
    /// 同じ根)。
    nonisolated static func declaration(from answer: (status: Int32, output: String))
        -> Declaration
    {
        guard answer.status == 0 else { return .unanswered(status: answer.status) }
        guard let package = SwiftPM.package(inDumpOf: answer.output) else { return .unreadable }
        return .declared(package)
    }

    /// 走らせる。終わるまで待ち、終了コードをそのまま引き継ぐ。**合図で落ちた子は、シェルの
    /// `$?` と同じ `128 + 番号` で名乗る** (``CommandFailure/sketchSignalled(signal:)``・#2315)。
    ///
    /// **前提: 渡す実行ファイルは、呼び元が作り直して建ったことを確かめたものだけである**
    /// (`run`・`render` は ``buildAndResolve(in:context:)``、`watch` は ``rebuild(in:context:capturing:running:binPath:)``
    /// の直後)。だから起こす時点で無ければ、宣言のせいではなく消えたのであり、
    /// ``CommandFailure/executableVanished(path:)`` が「build の直後には在った」と名乗る
    /// ([#2522](https://github.com/mokume-metal/mokume/issues/2522))。**作り直しを通らない呼び元を足す
    /// ときは、この名乗りが成り立つかを確かめる** — 成り立たなければ呼び元が名乗りを選べる形にする。
    ///
    /// - Parameter environment: 子へ渡す環境 (``childEnvironment(_:stamp:reportingRate:confirmingCloseFor:rendering:viewportOwner:assetOrigin:)``)。
    ///   **何を載せるかは口が決める** — `run` は速さの名乗りと × の確認を、`render` は書き出しの
    ///   頼みを載せる。待ち方と合図の運び方は口によらず同じなので、ここは 1 本にする。
    /// - Parameter signals: 道具が受けて子へ渡す合図。既定は ``stopSignals(sigint:)`` で、
    ///   **呼ぶたびにいまの SIGINT の受け口を見て決める。**
    static func launch(
        _ executable: URL, in directory: URL, environment: [String: String] = childEnvironment(),
        forwarding signals: [Int32] = stopSignals()
    ) throws(CommandFailure) {
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        process.environment = environment

        // **起こす前に受け口を置く。** ハンドラ関数の設定は exec で既定へ戻るので子には
        // 引き継がれない (無視 `SIG_IGN` にすると引き継がれ、スケッチが合図を無視する)。
        // 戻すのは検査のため — 本番の道具はこの後すぐ終わる
        let previous = installStopForwarding(signals)
        defer { restoreStopHandlers(previous) }
        let exited = ExitWait(for: process)
        do {
            try process.run()
        } catch {
            // **起こせなかった理由を、走らせるものの不在と決めつけない** (#2314 — 道具の側と
            // 同じ読み替え)。ここへ来る実行ファイルは宣言済みで、作り直しの直後に建ったことを
            // 確かめたものなので、無いなら消えたのであって、`Package.swift` の宣言のせいではない
            // (#2522)。**この前提は今の呼び元 (`run`・`render`・`watch`) のもの** — 作り直しを通らない
            // 呼び元が増えたら、ここと ``CommandFailure/executableVanished(path:)`` の文面を見直す
            throw launchFailure(
                of: process, error: error,
                executableMissing: .executableVanished(path: executable.path))
        }
        // **番号を置いてから印を見る。** 置く前に来た合図はハンドラが子へ撃てていないので、
        // ここで拾う。逆順にすると、見た後・置く前に来た合図を誰も子へ渡さない
        runChildPID = process.processIdentifier
        if runStopSignal != 0 { process.terminate() }
        exited.wait()
        runChildPID = 0
        // **合図で止めた回は、終了コードを見ずに名乗る。** 子は渡した SIGTERM で後始末を
        // 済ませて 0 で終わることも、済ませずに 15 で落ちることもある (#1219)。後者を
        // `sketchExited` で名乗ると「スケッチ自身の出力を読め」になる
        if runStopSignal != 0 { throw .stopped(signal: runStopSignal) }
        switch ChildEnding(of: process) {
        case .exited(0): return
        case .exited(let status): throw .sketchExited(status: status)
        // **合図の番号を終了コードとして名乗らない** (#2315)。`terminationStatus` は合図で落ちた子に
        // 合図の番号を返すので、`fatalError` の SIGTRAP が「code 5」になり、`exit(5)` と見分けがつかない
        case .signalled(let signal): throw .sketchSignalled(signal: signal)
        }
    }

    /// 終わりの合図を受けたら、走らせているスケッチへ SIGTERM を渡す受け口を置く。
    ///
    /// **ハンドラでは印を立てて `kill` を撃つだけにする** (どちらも async-signal-safe)。
    /// `kill` が書く errno は、入口で退避して出口で戻す (#3234)。
    /// 子が消えれば待ちが戻り、後は ``launch(_:in:environment:forwarding:)`` が終わらせる。
    ///
    /// **子が SIGTERM に応えなければ、道具も待ち続ける。** 孤児は残らず道具ごと見えて
    /// いるので、見張りのような期限つきの強制終了は踏まれてから足す (ADR-0008)。
    ///
    /// - Parameter signals: 受け口を置く合図。
    /// - Returns: 置き換えた合図と、置き換える前の受け口。``restoreStopHandlers(_:)`` へ渡す。
    static func installStopForwarding(_ signals: [Int32] = stopSignals())
        -> [(number: Int32, previous: sigaction)]
    {
        runStopSignal = 0
        return signals.map { number in
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { received in
                // **割り込んだ先の errno を変えずに戻る** (#3234)。`kill` は失敗すると errno を
                // 書くので、退避して戻さないと、割り込まれた呼び出しの後に errno を読む側が
                // この受け口の失敗を自分のものと読む
                let saved = errno
                defer { errno = saved }
                runStopSignal = received
                // **宛先を確かめてから撃つ。** `kill(0, …)` は自分のプロセスグループごと
                // 落とす (`WatchSession` の強制終了と同じ注意)
                let pid = runChildPIDCell.load(ordering: .relaxed)
                if pid > 0 { kill(pid, SIGTERM) }
            }
            // 受け口が待ちへ割り込んでも、呼び出しが `EINTR` で失敗して見えないようにする
            action.sa_flags = SA_RESTART
            var previous = sigaction()
            sigaction(number, &action, &previous)
            return (number, previous)
        }
    }

    /// ``installStopForwarding(_:)`` が置き換えた受け口を戻す。
    static func restoreStopHandlers(_ replaced: [(number: Int32, previous: sigaction)]) {
        for (number, previous) in replaced {
            var previous = previous
            sigaction(number, &previous, nil)
        }
    }

    /// 子へ渡す環境。
    ///
    /// **読むのではなく運ぶ。** 親の環境をそのまま複製し、道具が決めるものだけを載せる —
    /// 世代の刻印 (観測が応答へ載せる) と、速さの名乗り (一緒に出す構成の名前)、窓の × を
    /// 確かめさせる合図、書き出しの頼み、そして窓の持ち主。渡されなかったものは**置かない**
    /// ので、受け取る側は「無ければ黙る」だけで済む。
    ///
    /// - Parameter confirmingCloseFor: 窓の × を押した人に確かめさせるなら、**自分の
    ///   名乗り**。見張り (`watch`) は渡さない — 子は窓を持たず、確認は道具の側が出す
    ///   ([ADR-0032] 決定 1)。
    /// - Parameter rendering: 窓を開かずに書き出させるなら、その頼み (`render` だけが渡す)。
    ///   値の形は読み手と同じ型 (`RenderRequest`) が組むので、ここでは綴らない。**渡さなければ、
    ///   親の環境に在っても落とす** (``viewportOwner`` と同じ・#2481)。
    /// - Parameter viewportOwner: 子の窓を道具が持つなら、**自分の名乗り** (`watch` だけが
    ///   渡す)。子は区画 `viewport` も在れば窓を開かずに共有面へ差し出し、標準入力の管を
    ///   読む ([ADR-0032] 決定 1・4)。
    ///
    ///   **渡さなければ、親の環境に在っても落とす。** 窓の持ち主は起こした道具にしか
    ///   決められないので、見張りの子が起こした孫や、見張りの子の環境から打った `run` へ
    ///   継がせると、区画が在るだけで居合わせた実行が窓と管を奪う形に戻る
    ///   ([#2028](https://github.com/mokume-metal/mokume/issues/2028))。
    /// - Parameter assetOrigin: 資材の置き場の元 (`Sources/<target>/assets`) の絶対パス (`watch` だけが
    ///   渡す)。子は置き場の断片を束の写しではなくここから読み、保存で走らせたまま差し替える
    ///   ([#2517](https://github.com/mokume-metal/mokume/issues/2517))。**渡さなければ、親の環境に
    ///   在っても落とす** (``viewportOwner`` と同じ)。
    /// - Parameter keepTime: 作り直しをまたいで作者の時計を渡すファイルの絶対パス (`watch --keep-time` だけが
    ///   渡す)。子は最初の枚の前にここから前の世代の作者の時計を読み、必要なときに自分のを書く
    ///   (``StartupReads/keepTime``・[#2414](https://github.com/mokume-metal/mokume/issues/2414))。
    ///   **渡さなければ、親の環境に在っても落とす** — 旗の無い `watch`・`run`・`render` は 0 秒から始まる。
    ///
    /// **区画の基準 (`MOKUME_WORK_DIR`) だけは、道具が解いた絶対パスに置き換えて運ぶ。**
    /// 相対の値は読む側の作業ディレクトリから解かれる (`WorkDirectory.given`) が、子は作業
    /// ディレクトリをスケッチに替えて起こされるので、そのまま運ぶと道具 (走らせた場所から
    /// 解く) と子 (スケッチから解く) が別の区画を見る — 観測も入力も黙って噛み合わない
    /// (#2323 の反証)。道具が見ている区画に子を揃える。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    static func childEnvironment(
        _ base: [String: String] = ProcessInfo.processInfo.environment,
        stamp: String? = nil, reportingRate: String? = nil, confirmingCloseFor tool: String? = nil,
        rendering request: RenderRequest? = nil, viewportOwner: String? = nil,
        assetOrigin: String? = nil, keepTime: String? = nil
    ) -> [String: String] {
        var environment = base
        if let workDirectory = WorkDirectory.given(environment: base) {
            environment[StartupReads.workDirectory.key] = workDirectory.path
        }
        if let stamp { environment[StartupReads.sourceStamp.key] = stamp }
        if let reportingRate { environment[StartupReads.frameRateNotice.key] = reportingRate }
        if let tool { environment[StartupReads.closeConfirmation.key] = tool }
        // **渡さなければ、親の環境に在っても落とす** (`viewportOwner` と同じ)。書き出しの頼みは起こした
        // 道具にしか決められない。シェルに残った読めない値は `run`・`watch` の子を毎回落とし、読める値は
        // 窓を開かずに書き出させる (#2481)
        environment[StartupReads.render.key] = request?.environmentValue
        environment[StartupReads.viewportOwner.key] = viewportOwner
        // **これも渡さなければ落とす。** 置き場の元は見張りが自分の足元から決める値で、見張りの子が
        // 起こす `run` などへ継がせると、別のスケッチの断片をこの置き場から読みかねない (#2517)
        environment[StartupReads.assetOrigin.key] = assetOrigin
        // **これも渡さなければ落とす。** 時計を運ぶ旗は `watch --keep-time` だけのもので、旗の無い実行や `render` の子へ
        // 継がせると、別の世代の時計から始まってしまう (#2414)
        environment[StartupReads.keepTime.key] = keepTime
        return environment
    }

    /// 子の愚痴 (stderr) をどう扱うか。**3 つは排他である。**
    ///
    /// 旗を 2 本並べると「捨てながら混ぜる」という意味の無い組み合わせが表せてしまう
    /// ので、1 つの型で持つ ([#731])。
    ///
    /// [#731]: https://github.com/mokume-metal/mokume/issues/731
    nonisolated enum ErrorStream {
        /// 端末へそのまま流す。**既定** — 人が見ている経路。
        case inherit
        /// 捨てる。出力そのものを人へ見せる呼び出し (切り分けの口) だけで使う。
        case discard
        /// 掴んだ出力へ混ぜる。**作り直しの経路だけが使う。**
        ///
        /// `swiftc` の診断も SwiftPM 自身の診断も stderr に出るので、混ぜないと記録
        /// (``BuildReport/output``) に失敗の本文が載らない。窓口から見ると「失敗した」
        /// だけが届く。
        case merge
    }

    /// `swift` を呼ぶ。
    @discardableResult
    /// - Parameter errors: 子の愚痴の行き先。**混ぜてよいのは作り直しだけ** — 出力を
    ///   パスや JSON として解く呼び出しに混ぜると、警告 1 行で解けなくなる。
    ///   - running: 起こした子を外から止められるように掴む先 (``RunningBuild``)。
    nonisolated static func swift(
        _ arguments: [String], in directory: URL, capturing: Bool,
        errors: ErrorStream = .inherit, running: RunningBuild? = nil
    ) throws(CommandFailure) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = envURL
        process.arguments = ["swift"] + arguments
        process.currentDirectoryURL = directory
        return try capture(process, capturing: capturing, errors: errors, running: running)
    }

    /// 子を起こし、掴む形なら出力を読み切ってから待つ。
    ///
    /// **管の配線をここだけに置くのは、検査から任意の子を渡せるようにするためである**
    /// ([#731])。`swift(_:in:capturing:errors:)` は実行するものを `/usr/bin/env swift`
    /// に固定しているので、そちらからは偽の道具立てを渡せない。
    ///
    /// [#731]: https://github.com/mokume-metal/mokume/issues/731
    ///
    /// - Parameter running: 起こした子を掴ませる先。**止められた後は起こさずに投げる。**
    nonisolated static func capture(
        _ process: Process, capturing: Bool, errors: ErrorStream, running: RunningBuild? = nil
    )
        throws(CommandFailure) -> (status: Int32, output: String)
    {
        let pipe = Pipe()
        if capturing {
            process.standardOutput = pipe
        }
        switch errors {
        case .inherit:
            break
        case .discard:
            process.standardError = FileHandle.nullDevice
        case .merge:
            // **同じ管へ繋ぐので、2 つの流れの順序は保証されない** (子の側で別々に
            // 緩衝される)。順序を保つ機構は足さない — 読みたいのは診断の中身である。
            // 掴まないなら混ぜる先が無いので、流しっぱなしにする
            if capturing { process.standardError = pipe }
        }
        let exited = ExitWait(for: process)
        let launched: Bool
        do {
            if let running {
                launched = try running.launch(process)
            } else {
                try process.run()
                launched = true
            }
        } catch {
            // **起こせなかったことを、道具が無いことと決めつけない** (#2314)。`env` 越しなら
            // 道具の不在は下の 127 で分かる。ここに来るのは、たいてい作業ディレクトリの問題である
            throw launchFailure(
                of: process, error: error,
                executableMissing: .toolchainMissing(toolName(of: process)))
        }
        guard launched else { throw .rebuildStopped }
        defer { running?.finished() }
        var output = ""
        if capturing {
            // **読み切ってから待つ。** 逆順にすると、出力が管を埋めた時点で子が書けなく
            // なって止まる
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            output = String(data: data, encoding: .utf8) ?? ""
        }
        exited.wait()
        // **道具が無いことを、道具の失敗と取り違えない。** `/usr/bin/env` 自体は必ず起動
        // できるので、上の catch には届かない — `env` は探したものが無いと 127 で終わる。
        // 見逃すと空の出力が「宣言が読めない」「走らせるものが無い」と読まれ、原因が
        // 道具立てなのに Package.swift を疑わせる
        // ([#1157](https://github.com/mokume-metal/mokume/issues/1157))
        let ending = ChildEnding(of: process)
        if process.executableURL == envURL, ending == .exited(commandNotFound) {
            throw .toolchainMissing(toolName(of: process))
        }
        // **合図で落ちた子は `128 + 番号` で返す** (#2315)。呼び手は終了コードとして名乗り・記録する
        // (`buildFailed`・`build-status` の `status`)。合図の番号のままだと、5 で終わった回と区別がつかない
        return (ending.shellStatus, output)
    }

    /// 子を起こせなかった理由を読む。**実行ファイルの不在と言うのは、それが無いときだけ** (#2314)。
    ///
    /// `Process.run()` の失敗は、作業ディレクトリが無いときも実行ファイルが無いときも
    /// `NSFileNoSuchFileError` で、違うのは `NSFilePath` に名指しした場所だけである。入れない
    /// 場所 (`chmod 000` の親の下) でも同じ「無い」になる。名指しの綴りを比べ合わせる形は
    /// 採らない — 何が無いのかは言えても、なぜ入れないのかは載っていない。だから**失敗の後に
    /// 場所と実行ファイルを stat し直して**決める (``GivenPath/Presence``)。`swift` は
    /// `/usr/bin/env` 越しに起こすので env 自体は必ず在り、起動の失敗はたいてい作業ディレクトリ
    /// の問題である — それを「swift が無い」と言うと、Xcode を入れ直す方向へ人を遠ざける
    /// (`DoctorCommand` の規律 3 と同じ向き)。
    ///
    /// **限界: 起こした時点と確かめた時点の間に場所が消えたり戻ったりすると、読み分けが
    /// 変わる** (確かめた時点の姿を名乗る)。
    ///
    /// - Parameter executableMissing: 実行ファイルが無かったときの失敗。**在るのに実行できない
    ///   ときには使わない** — 「走らせるものが無い」と言うと、在るものを探しに行かせる (#2521)。口ごとに名乗りが違う
    ///   (道具なら ``CommandFailure/toolchainMissing(_:)``、スケッチなら
    ///   ``CommandFailure/noExecutable(path:)``)。
    nonisolated static func launchFailure(
        of process: Process, error: any Error, executableMissing: CommandFailure
    ) -> CommandFailure {
        let tool = toolName(of: process)
        // 起こす場所が決まっていなければ、子は走らせた場所で動く。それが読めなければ、使えない場所
        // として名乗る。**この枝は今の呼び元からは辿れない** (`launch`・`capture`・見張りの起動は
        // どれも `currentDirectoryURL` を据える) が、据え忘れた口が足されたときに、作業ディレクトリが
        // 消えた回を「在らない場所」と誤って言わないための受け皿である
        guard let place = process.currentDirectoryURL ?? GivenPath.currentDirectory else {
            return .placeUnusable(
                tool: tool, place: "(the directory this was run from)",
                presence: .unreachable(reason: "the directory this was run from cannot be read"))
        }
        let presence = GivenPath.Presence.of(place)
        guard presence == .directory else {
            return .placeUnusable(tool: tool, place: place.path, presence: presence)
        }
        guard let executable = process.executableURL else { return executableMissing }
        // **在るのに起こせないものを「無い」と言わない** (#2521)。`Process.run()` は実行ビットの
        // 無いファイル・探索権の無いディレクトリの下・宛先の無い symlink のどれにも「The file
        // doesn’t exist」(下に POSIX の誤り無し) を投げるので、誤りの文面からは原因が取れない —
        // stat し直した事実で名乗る
        switch standing(of: executable) {
        case .missing: return executableMissing
        case .unrunnable(let reason):
            return .cannotLaunch(tool: tool, place: place.path, reason: reason)
        case .runnable:
            return .cannotLaunch(tool: tool, place: place.path, reason: launchReason(of: error))
        }
    }

    /// 走らせるものの在り方。``standing(of:)`` が読む。
    nonisolated enum Standing: Equatable {
        /// 何も無い (`ENOENT` で、symlink でもない)。
        case missing
        /// 在るが、起こせない。`reason` は在処を含む 1 行。
        case unrunnable(reason: String)
        /// 在り、実行できる (起こせなかったのなら、理由は起こした側の誤りにある)。
        case runnable
    }

    /// 走らせるものを stat し直して、在り方を決める
    /// ([#2521](https://github.com/mokume-metal/mokume/issues/2521))。
    ///
    /// **「無い」と言うのは、stat が `ENOENT` を返し、symlink でもないときだけ** — 作業
    /// ディレクトリの側の ``GivenPath/Presence/of(_:)`` と同じ読み分けである。辿り着けない
    /// (`EACCES` など)・宛先の無い symlink・ディレクトリ・実行ビットが無い、は在るものなので、
    /// 「無い」と言うと在るものを探しに行かせる。
    ///
    /// **限界: 起こした時点と確かめた時点の間に変わると、確かめた時点の姿を名乗る。**
    nonisolated static func standing(of executable: URL) -> Standing {
        let path = executable.path
        var info = stat()
        guard stat(path, &info) == 0 else {
            let code = errno
            guard code == ENOENT else {
                return .unrunnable(reason: "\(path) cannot be reached (\(GivenPath.errorText(code)))")
            }
            var link = stat()
            return lstat(path, &link) == 0
                ? .unrunnable(reason: "\(path) is a symbolic link to something that is not there")
                : .missing
        }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            return .unrunnable(reason: "\(path) is a directory, not a program")
        }
        guard access(path, X_OK) == 0 else {
            return .unrunnable(
                reason: "\(path) is not executable (\(GivenPath.errorText(errno)))")
        }
        return .runnable
    }

    /// 起こせなかった事情の文面 (場所でも実行ファイルの不在でもないとき)。
    ///
    /// **POSIX の事情 (失敗そのものか、`NSUnderlyingErrorKey` を辿った先) なら、その番号から
    /// C の文面を引く** (``GivenPath/errorText(_:)``)。Foundation の説明は言語の設定に左右
    /// されうるが、道具が話す言葉は英語である (ADR-0038 決定 1・2)。
    ///
    /// **例外: POSIX の事情を持たない誤り** (下に POSIX の誤りを持たない Cocoa の誤り — たとえば
    /// `NSFileNoSuchFileError` だけのもの) は、引ける番号が無いので `localizedDescription` に
    /// 落とす。その文面は言語の設定で変わりうる。
    ///
    /// 番号の取り出し方は本体と 1 つ (``Diagnostics/posixCode(in:)``・#2839)。
    nonisolated static func launchReason(of error: any Error) -> String {
        guard let code = Diagnostics.posixCode(in: error) else { return (error as NSError).localizedDescription }
        return GivenPath.errorText(code)
    }

    /// 道具立てを探させる口。**`PATH` を引くのは `env` に任せる。**
    nonisolated static let envURL = URL(fileURLWithPath: "/usr/bin/env")

    /// `env` が「探したものが見つからなかった」ときの終了コード (POSIX)。
    ///
    /// **`env` 越しに起こしたときだけ読む。** 任意の子の 127 は、その子が決めた意味である。
    nonisolated static let commandNotFound: Int32 = 127

    /// 起こそうとした道具の名前。`env` 越しなら `env` が探す名前、そうでなければ実行ファイル名。
    nonisolated static func toolName(of process: Process) -> String {
        if process.executableURL == envURL, let tool = process.arguments?.first {
            return tool
        }
        return process.executableURL?.lastPathComponent ?? "swift"
    }
}

/// 走っている作り直しの `swift` を、外から止められるように掴んでおく先。
///
/// **見張りは作り直しを待たずに終われる** (#834) ので、終わるときに走っている `swift build` を
/// 止める者が要る。止めないと子は launchd に付け替えられて残り、`.build` の鍵を握ったまま
/// **起こし直した見張りを待たせる** — 手元の実測では、止めた直後に起こし直した見張りが
/// `Another instance of SwiftPM is already running` で待たされた
/// ([#1147](https://github.com/mokume-metal/mokume/issues/1147))。
///
/// **撃つのは呼ぶ側である。** ここは「いま何が走っているか」と「止めると決めたか」だけを
/// 持つ — 期限つきで落とす判断はスケッチを止める側 (`WatchSession`) に 1 つだけある。
///
/// **`@unchecked Sendable` の根拠は鍵である。** 作り直しは main actor の外で子を起こし、止める
/// のは main actor なので、状態は 2 つの糸から触られる。触る場所はすべて `lock` の中にある。
nonisolated final class RunningBuild: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Process?
    private var stopped = false

    init() {}

    /// 止められていなければ起こし、掴む。
    ///
    /// **起動と登録を 1 つの鍵に入れる。** 隙間で止められると、止める側は起動していない
    /// `Process` を受け取る — それに `terminate()` を打つと道具ごと落ちる。
    ///
    /// - Returns: 起こしたか。**止めると決めた後は起こさない** — 作り直しは `swift` を
    ///   何度か呼ぶので、止めた後の 2 本目が新しく鍵を握ることになる。
    func launch(_ process: Process) throws -> Bool {
        try lock.withLock {
            guard !stopped else { return false }
            try process.run()
            current = process
            return true
        }
    }

    /// 起こした子が終わった。
    func finished() {
        lock.withLock { current = nil }
    }

    /// 止めると決め、いま走っている子を返す。**居なければ `nil`。**
    func stop() -> Process? {
        lock.withLock {
            stopped = true
            return current
        }
    }
}
