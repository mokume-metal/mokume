// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 保存したら作り直して差し替える、その中身。
///
/// ループとシグナルの扱いは ``WatchCommand`` に置き、ここは判断だけを持つ —
/// 作り直しとプロセスの起動は差し替えられるようにしてあるので、検査は実際に
/// ビルドを走らせずに「何をどの順で決めるか」を確かめられる。
///
/// ## 所要時間を分けて測る
///
/// **合計だけを見ていると律速を推測で決めて外す。** 気付いてから始めるまで / 作り直し /
/// 差し替え / 新しい絵が出るまで の 4 つに分けて刻み、どの構成で測ったかも併せて出す。
/// 足し算と重なりは ``BuildReport/Timings`` が持つ。
@MainActor
final class WatchSession {
    /// 差し替えられる外側。
    struct Hooks {
        /// 作り直して、走らせるものの場所まで決める。
        ///
        /// **作り直しと解決を 1 本にしてある。** 別々の口にしていたときは、`live` が
        /// 一方にだけ構成や置き場を渡す形が書けてしまい、**名乗ったものと実際に起動する
        /// ものが食い違った** (#680 が構成で踏んだ形)。抱き合わせれば、その組み合わせを
        /// 書けなくできる。
        ///
        /// **待つのは main actor の外である。** 見張りは巡回の中からこれを呼ぶので、ここで
        /// 塞ぐと `swift build` のあいだ画面が凍る (#834)。
        ///
        /// **`@Sendable` にはしない。** 境界を越えるのは ``live(context:)`` の内側だけで、
        /// ここを送れる形にすると**検査の替え玉が main actor の数を数えられなくなる** —
        /// 外へ出す場所は 1 箇所に閉じておく。
        ///
        /// **起こせなければ投げる。** 記録の形へ直すのは ``WatchSession`` の側である —
        /// ここで直す形だった頃は、`try?` が理由を捨てて記録の `output` が空になった
        /// ([#1100](https://github.com/mokume-metal/mokume/issues/1100))。
        var rebuild: (URL) async throws(CommandFailure) -> RunCommand.Rebuilt
        /// 走らせる。世代の刻印と、速さの名乗り (一緒に出す構成の名前) を渡す。
        ///
        /// **起こせなければ投げる** (``rebuild`` と同じ)。記録の形へ直すのは ``WatchSession`` の
        /// 側である — `nil` を返す形だった頃は、`try?` が理由を捨て、記録には `launched: false`
        /// だけが残って `output` にも端末にも理由が出なかった
        /// ([#2521](https://github.com/mokume-metal/mokume/issues/2521))。
        var launch: (URL, URL, String?, String?) throws(CommandFailure) -> Process
        /// 時計の読み (秒)。**取るのは 2 つの読みの差だけである** — 記録に載るのは所要時間
        /// (`detect_ms` など) で、時刻そのものは書かない。
        ///
        /// **眠っている間は進まない時計で読む** (本番は `systemUptime`)。壁時計だと、眠りを
        /// 挟んだ所要時間が眠った分だけ膨らみ、時刻の巻き戻しで負になる — 記録の形
        /// (`Schemas/build-status.schema.json`) は 4 つの所要時間とも 0 以上を約束している
        /// ([#1940](https://github.com/mokume-metal/mokume/issues/1940))。
        var now: () -> Double
        /// 監視しているソースの世代。
        ///
        /// **待つのは main actor の外である** (``rebuild`` と同じ)。世代は資材の中身から導くので、
        /// 大きな資材を置いた・書き換えている間は 1 回に数百 ms かかる — main actor で取ると、
        /// そのあいだ道具の窓が止まる ([#2518](https://github.com/mokume-metal/mokume/issues/2518))。
        /// `@Sendable` にしない理由も ``rebuild`` と同じで、外へ出すのは ``live(resolver:running:stamps:)``
        /// の内側だけに閉じる。
        var stamp: (URL) async -> String?
        /// 走っている作り直しを止めると決め、いま走っている子を返す。**居なければ `nil`。**
        ///
        /// **撃つのは ``WatchSession`` である。** 期限つきで落とす判断はスケッチを止める
        /// 側と同じ 1 つを使う ([#1147](https://github.com/mokume-metal/mokume/issues/1147))。
        /// 既定は「何も走っていない」 — 替え玉の作り直しは子を起こさない。
        var stopRebuild: () -> Process? = { nil }

        /// 呼ばれ方から、導き手ごと組む。
        ///
        /// **見張りの口 (``WatchCommand``) はこれを使わない。** あちらは見張り始める前に
        /// 1 度導いて置き場を名乗る必要があるので、導き手を自分で組んで ``live(resolver:running:)``
        /// へ渡す — 組むのを 2 度にすると、初回だけ `swift` が余分に起きる (#1067)。
        static func live(in directory: URL, invocation: Invocation) -> Hooks {
            // **1 つを作り直しと止める口で分け持つ。** 止めると決めたら二度と起こさない —
            // 止めるのは見張りが終わるときだけなので、それで足りる (#1147)
            let running = RunningBuild()
            return live(
                resolver: .live(in: directory, invocation: invocation, running: running),
                running: running)
        }

        /// - Parameter resolver: 宣言から土台と置き場を導く者。**宣言が変わるまで持ち回る** —
        ///   導くのに `swift` を 2 本起こすので、作り直しのたびに払うと保存から絵が変わるまでに
        ///   丸ごと乗る ([#1067](https://github.com/mokume-metal/mokume/issues/1067))。
        /// - Parameter running: 走っている `swift` を掴む先。**導き手と同じものを渡す** —
        ///   止めると決めた後に導き直しが `swift` を起こすと、それが新しく置き場の鍵を握る (#1147)。
        /// - Parameter keepTime: 作り直しをまたいで作者の時計を渡すファイルの絶対パス (`watch --keep-time`)。
        ///   起こす子ごとに環境変数で渡す (``StartupReads/keepTime``・#2414)。省けば渡さない。
        /// - Parameter stamps: 世代の読み手。**1 つを持ち回る** — 属性の変わらないファイルを
        ///   巡回のたびに読み直さないための控えを持つ (資材の置き場の大きなファイル・#2312)。
        ///   渡すのは検査だけである (要約を塞いで、待っている間に main が進むかを見る)。
        static func live(
            resolver: BuildResolver, running: RunningBuild,
            stamps: SourceStamp.Reader = SourceStamp.Reader(), keepTime: String? = nil
        ) -> Hooks {
            Hooks(
                rebuild: { directory throws(CommandFailure) in
                    // **切り離して走らせる。** `RunCommand.rebuild` は隔離を外してあるので、
                    // ここで待っても main actor は空く — ADR-0010 決定 4 の「明示的に分離
                    // する」で、待ち行列は足していない (#834)
                    //
                    // **導き直しも同じ側で走らせる。** 宣言が変わった回に main actor で
                    // 導くと、そのあいだ画面が凍る (#1067)
                    //
                    // **誤りは `Result` に包んで持ち帰る。** `Task` の `value` は `any Error`
                    // を投げるので、そのまま投げると型が落ちる (ADR-0010 決定 7)
                    try await Task.detached(priority: .userInitiated) {
                        Result { () throws(CommandFailure) in
                            let resolved = try resolver.current()
                            return try RunCommand.rebuild(
                                in: directory, context: resolved.context, capturing: true,
                                running: running, binPath: resolved.binPath)
                        }
                    }.value.get()
                },
                launch: { executable, directory, stamp, rate throws(CommandFailure) in
                    let process = Process()
                    process.executableURL = executable
                    process.currentDirectoryURL = directory
                    // **管を 1 本引く。** 道具の窓が拾った出来事はここを通って子へ渡る
                    // ([ADR-0032] 決定 4)。継がずに親の標準入力を渡すと、書き込む先が
                    // 端末になってしまう
                    process.standardInput = Pipe()
                    // 観測は刻印を応答へそのまま載せる。読み手は刻印の変化で「保存した
                    // 内容が反映されたか」を待ち時間ではなく判定できる。組み立ては
                    // RunCommand が持つ — 子へ渡す環境の作り方を 2 通りにしない
                    //
                    // **窓の持ち主は自分だと伝える** (ADR-0032 決定 1)。子が共有面へ差し出し
                    // 上の管を読むのは、これと区画 `viewport` が揃ったときだけである。区画は
                    // 窓を出せたときだけ置くので、出せなかった回の子は自分の窓を開く (#2028)
                    process.environment = RunCommand.childEnvironment(
                        stamp: stamp, reportingRate: rate, viewportOwner: WatchSession.viewportOwnerName,
                        // **置き場の断片は元から読ませる** (#2517)。写しを読むと、元を保存しても
                        // 走らせたまま差し替わらない
                        assetOrigin: (try? resolver.current())?.context.assets.url?.path,
                        keepTime: keepTime)
                    do {
                        try process.run()
                    } catch {
                        // **起こせなかった理由を捨てない** (#2521)。読み分けは `run` の口と同じ
                        // 1 つを使う — 場所が使えないのか・走らせるものが無いのか・在るのに
                        // 起こせないのか (#2314)
                        //
                        // **消えた、と名乗ってよいのは、渡される実行ファイルが作り直しの直後に建てた
                        // ものだけだから** (#2522・`RunCommand.launch` の前提と同じ)
                        throw RunCommand.launchFailure(
                            of: process, error: error,
                            executableMissing: .executableVanished(path: executable.path))
                    }
                    return process
                },
                now: { ProcessInfo.processInfo.systemUptime },
                stamp: { directory in
                    // **切り離して読む。** 読み手は錠で控えを守るので、どのスレッドから読んでも
                    // よい。待っている間 main actor は空く (#2518)
                    await Task.detached(priority: .userInitiated) {
                        stamps.current(for: directory)
                    }.value
                },
                stopRebuild: { running.stop() })
        }
    }

    /// 子を止めた結果。
    nonisolated enum StopOutcome: Equatable, Sendable {
        /// 居なかった (まだ起こしていない・既に死んでいた)。
        case notRunning
        /// 頼んだら止まった。
        case terminated
        /// 頼んでも止まらないので、期限で強制的に落とした。
        case killed
        /// **強制終了しても消えなかった。** 置いていくしかない。
        ///
        /// `SIGKILL` は捕まえられないが、割り込めない待ち (GPU の中で固まった子など) に
        /// 入っているものは即座には消えない。**ここを `killed` と名乗ると「置いていかない」
        /// が黙って破れる**ので、別の結果として持つ (#732)。
        ///
        /// 番号を載せるのは、**残ったものを人が落とせるようにする**ためである
        /// (`scripts/orphan-processes.sh` が出すものと同じ数字)。
        case abandoned(pid: Int32)
    }

    /// 子が、道具の知らないところで消えたこと。
    ///
    /// **道具が止めた終わり方 (``StopOutcome``) とは別の出来事である。** あちらは道具が
    /// 起こした結果を名乗るもので、こちらは**誰も頼んでいないのに居なくなった**ことを言う。
    struct Departure: Equatable {
        /// 終了コード。合図で落ちたときは合図の番号。
        var status: Int32
        /// 落ちたのか (`true`)、自分から終わったのか (`false`)。
        ///
        /// **読む人が次にすることが変わる。** 落ちたのなら端末を遡る先があり、自分から
        /// 終わったのならスケッチの側にそう書いてある。
        var wasSignalled: Bool
        /// **最初の絵を出す前に**、失敗で (0 以外の終了コードか合図で) 終わったか
        /// ([#3172](https://github.com/mokume-metal/mokume/issues/3172))。
        ///
        /// 走っていた子が自分で消えたのとは別の出来事で、**起こせなかった**回として扱う。終了コード 0 で
        /// 終わった子は、絵を出す前でも含めない — 自分から終わるのは起動の失敗ではない。
        var failedToStart = false
        /// 起動できなかった回に、前の版を残して現役に戻したか。**戻したなら、前の版の頼みも台でそのまま効く。**
        var keptPrevious = false
        /// 起動できなかった回の記録 (`failedToStart` のときだけ)。**区画に書いたのと同じもの**で、端末とプレビューの
        /// 言葉はここから組む。手前に作り直しの失敗の記録が挟まっていたときは書かないが、言葉の材料としては持つ。
        var report: BuildReport?
    }

    /// 止まるのを待つ上限 (秒)。
    ///
    /// **3 秒という値に意味があるのではなく、桁が離れていることに意味がある** — 素直に
    /// 終わるスケッチは数ミリ秒で消え、応えないものは永久に消えない。人が「固まった」と
    /// 感じる前に決着する側へ寄せる。
    static let defaultStopTimeout: TimeInterval = 3

    /// 見張りを**終えるとき**に、止まるのを待つ上限 (秒)。
    ///
    /// **撮っていた動画を閉じ終えるまで待つ** ([#1219])。スケッチは `SIGTERM` を受けると
    /// 後始末 (動画を閉じる) を済ませてから終わるが、それは 3 秒に収まらない — 閉じる側の
    /// 期限 (``RecordingDeadline/longestFinishSeconds``) の上に、いつもの ``defaultStopTimeout``
    /// を足す。数字を写さないのは、閉じる側の期限が動いたときに黙って割れないためである。
    ///
    /// **延ばすのは終えるとき (``end()``) だけ。** 差し替えと作り直しの中断は保存のたびに
    /// 払う待ちなので ``defaultStopTimeout`` のまま置く — 応えないスケッチがあると、保存のたびにその分固まる
    /// ([#732](https://github.com/mokume-metal/mokume/issues/732))。差し替えで閉じきれなかった
    /// 動画は、次の世代が撮り直す。
    ///
    /// [#1219]: https://github.com/mokume-metal/mokume/issues/1219
    static let defaultFinishTimeout: TimeInterval =
        RecordingDeadline.longestFinishSeconds + defaultStopTimeout

    /// 強制終了した後に、消えるのを待つ上限 (秒)。
    ///
    /// **短く取る。** `SIGKILL` は届けば即座に効くので、ここで長く待って得るものが無い —
    /// この待ちは差し替えのたびにも払うので、最悪値をそのぶん押し上げる。
    static let killGrace: TimeInterval = 0.5

    /// スケッチのパッケージの場所。ビルドと世代の判定はここで行う。
    let directory: URL
    /// 区画の基準。**パッケージの場所とは別の軸** — スケッチは `MOKUME_WORK_DIR` に従って
    /// 観測を書くので、作り直しの記録も同じ側へ置かないと読み手から見て割れる (#331)。
    let facetBase: URL
    /// 見張り始めたときの土台 (構成と置き場と product)。
    ///
    /// **構成だけを持っていた頃は、置き場を足したときに片方だけ渡す形が書けた。**
    /// 抱き合わせた値で持てば、作り直しと解決が必ず同じものから出る。
    ///
    /// **作り直しはこれを読まない。** 宣言は編集されうるので、作り直しが使う土台は
    /// ``BuildResolver`` が宣言の世代ごとに導く (#1067)。ここに残っているのは、
    /// 宣言によらないもの (構成の名乗り) と、**導く前に倒れた回**の置き場だけである。
    let context: BuildContext
    /// 名乗るときの構成の名前。選ばれていなければ既定の名前。
    var configurationName: String { context.configurationName }

    /// 子の窓を持つ道具としての名乗り (`StartupReads.viewportOwner` の値)。
    nonisolated static let viewportOwnerName = "\(Command.name) \(Command.Verb.watch.rawValue)"
    private var hooks: Hooks

    /// いま走らせている子。
    ///
    /// **入れ替わったら、消えたことの名乗りは畳む。** 止めるのも差し替えるのもここを通る
    /// ので、印を下ろす場所はこの 1 つで足りる (``departed()``)。
    private(set) var child: Process? {
        didSet { hasNamedDeparture = false }
    }

    /// 止めている最中の ``child``。**死んでから ``child`` を外すまでの間、``departed()`` が
    /// 「勝手に消えた」と名乗らないための印である** ([#2576](https://github.com/mokume-metal/mokume/issues/2576))。
    private var stoppingChild: Process?

    /// 作り直し (`hooks.rebuild`) の中か。**止められる作り直しは、ここに居る間だけである。**
    ///
    /// ``isRebuilding`` は子の差し替えまで含めて立つので、差し替えの最中に作り直しを止めようと
    /// すると、走っている作り直しが無いのに「止めた」記録が建ち終えた回に付く。
    private var isBuilding = false

    /// 退役待ちの子。**画面が新しい世代へ入れ替わるまで、走らせておく。**
    ///
    /// 止めてから起こすと、新しい子が最初のフレームを焼くまで絵が途切れる (手元では
    /// **417 ms**・[#1142](https://github.com/mokume-metal/mokume/issues/1142))。順序を入れ替えて
    /// **重ねるのは 1 世代だけ**で、次の差し替えが来たときに残っていたらそこで必ず止める。
    ///
    /// **消えたことは名乗らない。** 止めるつもりで生かしているので、``departed()`` が見るのは
    /// ``child`` だけである。
    private(set) var outgoing: Process?

    /// 世代を重ねるか。**窓を出せた見張りだけが重ねる。**
    ///
    /// 入れ替わりの合図は道具の窓から来るので ([ADR-0032] 決定 1)、窓が出せなかった実行では
    /// 誰も知らせてくれない — そこでは今までどおり、止めてから起こす。
    var overlapsGenerations = false

    /// 道具の窓へ、「いま映している世代を手放した」と伝える口 ([#2983](https://github.com/mokume-metal/mokume/issues/2983))。
    ///
    /// 台は、畳まれた世代・もう居ない世代のカーソルの頼み (捕まえる・隠す) を、読み直す契機が来ないまま
    /// 持ち続ける。受け取れない世代の知らせ (#2928) は台が自分で気付くが、次の 3 つは台を通らないので、
    /// ここから伝える — 倒れた子 (``retireAfterFallback()``)・子の離脱 (``departed()``)・乗り換えの合図が来ない
    /// まま次の保存が来て映っている世代を畳んだ回 (``rebuild``)。窓を出せた見張りだけが繋ぐ
    /// (``WatchCommand``)。**頼みを下ろすだけで、最後の絵も入力の宛先も変えない。**
    ///
    /// **引数は、手放す世代の子の番号である** (#2982)。台は、いま映している世代の目録が名乗る番号と照合し、
    /// 手放す世代でなければ当てない (映っている生きた世代の頼みを手放させない)。まだ採っていない目録も、
    /// 手放した番号のものは生まれたときから手放した扱いにする (離脱の知らせが台の拍より先に来ても、死んだ子へ
    /// 乗り換えて頼みを読まない)。
    var relinquishesDisplay: ([Int32]) -> Void = { _ in }

    /// 世代の子の番号。居なければ空。
    private func generationPIDs(of process: Process?) -> [Int32] {
        process.map { [$0.processIdentifier] } ?? []
    }

    /// 新しい絵が出るまでを測っている、差し替えを始めた時刻。**測らない回は `nil`。**
    ///
    /// 置くのは ``finish(_:)`` の中だけで、どの記録を書いても置き直す — 起こした後に
    /// 作り直しの失敗や途中停止の記録で上書きされたら、待っていた数字の行き先はもう無い。
    private var firstFrameSince: Double?
    /// 最後に起こした世代が、まだ画面へ乗り換わっていないか。
    private var awaitingPromotion = false
    /// 乗り換えの合図を 1 度でも受けたか。
    ///
    /// **受けるまでの合図は、絵が出た時点を指さない。** 出している世代が無い台は 1 枚目を
    /// 待たずに乗り換える (`SharedFrameStage.promoteIfReady()`) ので、最初に目録を置いた
    /// 世代の合図は「絵が出た」ではなく「目録が読めた」になる。
    private var hasSeenPromotion = false

    /// 1 枚目の絵を道具の窓に出した世代の子の番号 ([#3172](https://github.com/mokume-metal/mokume/issues/3172))。
    ///
    /// **「絵を出す前に終わった」の根拠はこれである。** 乗り換えの合図 (``hasSeenPromotion``) は使えない —
    /// 出している世代が無い台は 1 枚目を待たずに乗り換えるので、最初の世代の合図は「目録が読めた」で、
    /// `setup()` の前に来る。起こした世代が生きている間だけ覚える (``generationShown(pid:)``・
    /// ``launchChild(_:)``)。
    private var shownPIDs: Set<Int32> = []
    /// 最後に起こした子の道具の名前。起動できなかった回の理由に使う。
    private var launchedTool: String?

    /// 消えたことを既に名乗ったか。**子が入れ替わると下りる。**
    private var hasNamedDeparture = false
    /// いま作り直しているか。
    ///
    /// **作り直しが main actor を塞がなくなったので、印が要る。** 巡回は 0.25 秒ごとに
    /// 来るので、これが無いと 1 つの変化に対して何本もの `swift build` が並ぶ (#834)。
    private(set) var isRebuilding = false
    /// 終われと言われたか。
    ///
    /// **作り直しを待っている間に、巡回が抜けうる。** 待ちが main actor の外へ出たので、
    /// 合図を受けた巡回はビルドの終わりを待たずに畳まれる (#834) — そこで子を起こすと、
    /// **誰も止めない子が残る** (#454 の孤児と同じ形)。
    ///
    /// 立てるのは口の側 (``WatchCommand/step(_:viewer:stopped:)``) である。**``stop()`` では
    /// 立てない** — あれは差し替えのたびにも通るので、終わりの意味を載せると保存のたびに立つ。
    private(set) var stopRequested = false
    /// 作り直しを途中で止めたときに書いた記録。**立っていたら、作り直しの続きは何も決めない。**
    ///
    /// 止めた作り直しも、いずれ終了コードを持って戻ってくる — そこで失敗として書き直すと、
    /// 「途中で止めた」が「壊れていた」に化ける (#1147)。
    private var stoppedReport: BuildReport?
    /// いまの作り直しを始めた時刻。止めた回の所要時間に使う。
    private var rebuildStartedAt: Double?
    /// 止まるのを待つ上限 (秒)。**検査から縮める** — 既定で待つと、期限を確かめる検査が
    /// そのぶん遅くなる。
    let stopTimeout: TimeInterval
    /// 見張りを終えるときに、止まるのを待つ上限 (秒)。**検査から縮める** (``stopTimeout`` と
    /// 同じ理由)。
    let finishTimeout: TimeInterval
    /// 直前に子を止めたときの結果。**差し替えのときも入る。**
    ///
    /// 名乗るのは口の側である — このクラスは判断だけを持ち、出力を持たない。期限に
    /// 掛かったことは保存のたびにも起こりうるので、終わるときだけ見ても足りない (#732)。
    private(set) var lastStop: StopOutcome?
    /// 最後に作り直したときのソースの世代。
    private(set) var lastStamp: String?
    /// 直近の作り直しの結果。
    private(set) var lastReport: BuildReport?
    /// 変化に気付いた時刻。作り直しの直前に消す。
    private var noticedAt: Double?

    /// 速さを名乗らせるか。**既定は名乗らせない** — 人が見ている前でだけ足す付け足しで、
    /// 機械が読む経路 (窓口) の出力は 1 バイトも変えない ([ADR-0029] 決定 5 の 2 番目)。
    let reportsRate: Bool

    /// 作り直しを**始めるとき**に呼ばれる。`initial` は最初の 1 回か。
    ///
    /// **知らせるだけで、判断も出力もここではしない。** 何を言うかは口の側が決める。
    ///
    /// なぜ要るか: 作り直しは終わってからしか名乗らないので、その間**画面が 1 文字も
    /// 動かない**。使う側からは「見張れていない」と「作り直している」の区別が付かず、
    /// 実際にそう読まれた ([#695](https://github.com/mokume-metal/mokume/issues/695))。
    var willRebuild: (_ initial: Bool) -> Void = { _ in }

    /// 見張りを終えるときに、子が ``stopTimeout`` を越えてもまだ終わっていないと呼ばれる。
    /// 引数はこの先さらに待つ上限 (秒)。**1 度だけ呼ぶ。**
    ///
    /// **知らせるだけで、出力は口の側が決める** (``willRebuild`` と同じ)。長く待つのは撮って
    /// いた動画を閉じているからで、黙っていると「固まった」と読まれる — ``defaultStopTimeout``
    /// が 3 秒で決着させていたのは、まさにその読まれ方を避けるためだった ([#1219])。
    ///
    /// [#1219]: https://github.com/mokume-metal/mokume/issues/1219
    var willWaitForFinish: (_ remaining: TimeInterval) -> Void = { _ in }

    /// - Parameter hooks: 差し替える外側。**渡さなければ、呼ばれ方から組む** —
    ///   既定引数では作れない (場所が決まるのは初期化の中である)。
    /// - Parameter invocation: 呼ばれ方。`hooks` を渡さないときだけ要る。
    init(
        directory: URL, context: BuildContext, facetBase: URL? = nil,
        reportsRate: Bool = false, hooks: Hooks? = nil,
        invocation: Invocation = Invocation(),
        stopTimeout: TimeInterval = WatchSession.defaultStopTimeout,
        finishTimeout: TimeInterval = WatchSession.defaultFinishTimeout
    ) {
        self.directory = directory
        self.facetBase = facetBase ?? directory
        self.context = context
        self.reportsRate = reportsRate
        self.hooks = hooks ?? .live(in: directory, invocation: invocation)
        self.stopTimeout = stopTimeout
        self.finishTimeout = finishTimeout
    }

    /// 見張りを終える手続き (``WatchCommand/finish(_:)``) がどこまで進んだか。
    ///
    /// **終わりの経路は 2 つある** (巡回を抜けるとき・道具立ての終了)。どちらからも、止める待ちを
    /// 窓を開いたまま (main actor を塞がずに) 済ませてから抜けるので、2 度目の呼び手は
    /// 済んだことを知る必要がある ([#2576](https://github.com/mokume-metal/mokume/issues/2576))。
    enum FinishStage { case idle, running, done }
    var finishStage = FinishStage.idle

    /// 世代を待っているか。
    ///
    /// **世代を取る仕事が main actor を塞がなくなったので、印が要る** (#2518)。取るのに
    /// 巡回の間隔 (0.25 秒) より長くかかると、印が無ければ次の巡回が同じ読みを重ねて起こす —
    /// 大きな資材を書き換えている間は、読み終わる前に次の読みが積み上がる。
    private(set) var isStamping = false

    /// 1 巡する。変化が無ければ何もしない。
    ///
    /// **作り直している間に来た巡回は、何もせずに戻る。** 作り直しはもう main actor を
    /// 塞がないので、巡回は 0.25 秒ごとに来続ける — 印が無ければ同じ変化に対して
    /// 何本もの `swift build` が並ぶ (#834)。
    ///
    /// **その間に保存された内容は落ちない。** 世代の刻印を更新するのは作り直しの側なので、
    /// 作り直しが終わった次の巡回が新しい刻印を見つけ、もう 1 度だけ作り直す。
    ///
    /// **順番待ちは気付いた時刻に含める。** 印を見るのを「気付いた時刻」を置いた**後**に
    /// するのは、そうしないと順番待ちの時間が 3 つの数字のどこにも出ないためである —
    /// 保存から絵が変わるまでの説明が付かなくなる。
    ///
    /// **世代を待っている間に来た巡回も、何もせずに戻る** (#2518)。世代を取る仕事は main
    /// actor の外で走るので、待っている間も巡回は来続ける。
    ///
    /// **世代を待って戻ったら、終われと言われていないかを見直す。** 合図を見るのは口の側
    /// (``WatchCommand/step(_:viewer:stopped:)``) で、待っている間に来た合図はこの巡回を
    /// 止められない — 見直さないと、終われと言われた後に作り直しを始める (#834 の順序)。
    @discardableResult
    func tick() async -> BuildReport? {
        guard !isStamping else { return nil }
        let stamp = await takeStamp()
        guard !stopRequested, stamp != lastStamp else { return nil }
        if noticedAt == nil { noticedAt = hooks.now() }
        guard !isRebuilding else { return nil }
        return await rebuildAndReplace(stamp: stamp)
    }

    /// 最初の 1 回。変化を待たずに作って走らせる。
    ///
    /// **最初の世代も main actor の外で取る** (#2518)。初回は控えが無いので、資材をすべて読む。
    ///
    /// **世代を待って戻ったら、終われと言われていないかを見直す** (``tick()`` と同じ)。最初の
    /// 世代を待つのはいちばん長い回で、その間に来た合図を見ないと、終われと言われた後に
    /// 作り直しを始めると名乗って `swift build` を起こす。始めなかったことは記録に書く —
    /// 書かないと区画には前の見張りの記録が残る (#1147 と同じ理由)。
    @discardableResult
    func start() async -> BuildReport {
        let stamp = await takeStamp()
        guard !stopRequested else {
            return finish(
                .failed(
                    status: 128 + SIGINT, output: Self.notStartedNotice, stamp: lastStamp,
                    configuration: configurationName,
                    timings: .init(detectMs: nil, buildMs: 0, relaunchMs: nil)))
        }
        return await rebuildAndReplace(stamp: stamp, initial: true)
    }

    /// 最初の作り直しを始める前に終われと言われた回の記録の本文。**失敗とは違う言葉で始める**
    /// (``stoppedRebuildNotice`` と同じ理由)。
    static let notStartedNotice =
        "Nothing was built, because watching ended before the first build started — this is not "
        + "a build failure"

    /// 世代を取る。**取っている間は印を立てる** (``isStamping``)。
    ///
    /// - Returns: いまの世代。読めるファイルが 1 つも無ければ `nil`。
    private func takeStamp() async -> String? {
        isStamping = true
        defer { isStamping = false }
        return await hooks.stamp(directory)
    }

    /// 終われと言われたことを覚える。
    ///
    /// **合図を読むのは口の側で、ここは覚えるだけである。** 何を合図とするか (シグナル・
    /// 窓の ×) を知っているのは ``WatchCommand`` で、このクラスは判断だけを持つ。
    func noteStopRequested() { stopRequested = true }

    /// 走らせている子へ 1 行渡す。
    ///
    /// **書けなくても何も起きない。** 見張りは子を頻繁に入れ替えるので、既に居ない相手へ
    /// 書くことは必ず起きる。溜めて後から流す形は採らない — 入力は古くなると意味が
    /// 変わる (どこを指していたかは、いまの絵に対してしか意味が無い)。
    ///
    /// 呼ぶ側は既定で `SIGPIPE` を無視しておく必要がある ([WatchCommand] が置く) —
    /// 無視しないと、畳まれた管へ書いた**こちらが死ぬ**。
    ///
    /// **塞がらない。** ここは NSView の出来事から main で同期に呼ばれるので、待つと
    /// 窓・保存の検出・巡回がまとめて止まる。読まない子でも戻れるのは、迎えるときに
    /// 書き口へ印を立ててあるからである (``unblockWriting(to:)``)。
    func send(_ line: String) {
        // **画面に出ている世代へ送る。** 退役待ちが居る間は、まだ前の世代が映っている —
        // 入れ替わりと退役は同じ合図で起きるので、宛先は画面と一致する (#1142)
        let target = outgoing ?? child
        guard let pipe = target?.standardInput as? Pipe, let data = line.data(using: .utf8) else {
            return
        }
        // **失敗を握り潰す。** 相手が畳んだ (EPIPE)・管が一杯 (EAGAIN) のどちらでも、
        // することは同じ「この 1 件を捨てる」である
        //
        // **1 度だけ書く。** 道具立ての `FileHandle.write(contentsOf:)` は、書けなかった
        // ぶんをどう扱うか (投げるか・回り続けるか) が内部に依る — 塞がらないことが
        // ここの要点なので、`write(2)` を 1 回呼んで戻り値の扱いを自分で持つ (#1296)
        //
        // **半分だけ書かれることは無い。** 1 件は PIPE_BUF (512 バイト) より十分に小さく、
        // 非閉塞の管への書き込みはその大きさまで「全部書く」か EAGAIN で何も書かないかの
        // どちらかである — 捨てた 1 件が、次の 1 件の頭に継ぎ足される形にはならない
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        _ = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    }

    /// 迎えた子の**書き口**を、塞がない形にする。
    ///
    /// **子が読み口に立てた印は、ここに効かない。** 管の両端は別の open file description
    /// なので、`StandardInputEvents` の `O_NONBLOCK` が変えるのは子の `read` だけである。
    /// 親が立てないと、読まない子へ書き続けたとき管の容量 (64KB) が埋まった次の `write`
    /// が戻らず、**見張りの main が永久に塞がる** (#1296)。
    ///
    /// **起こす側ではなく、ここで立てる。** 管を引くのは ``Hooks/launch`` だが、書き口を
    /// 持つのは親である — 替え玉の外側で起こした子にも同じ不変条件が要る。
    private func unblockWriting(to process: Process?) {
        guard let pipe = process?.standardInput as? Pipe else { return }
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
    }

    /// 子が、道具の知らないところで消えていたら 1 度だけ返す。
    ///
    /// **見張りは子の生死を見ていなかった。** 見ていたのは世代の刻印だけなので、走らせて
    /// いるスケッチが自分で終わっても落ちても、道具は何も言わずに回り続ける — 窓は道具の
    /// ものなので画面には残り、止まった絵のまま次の保存を待つ
    /// ([#1103](https://github.com/mokume-metal/mokume/issues/1103))。
    ///
    /// **道具が自分で止めた回は返らない。** 終わるときも保存による差し替えも ``stop()``
    /// を通り、そこは止め終えたら ``child`` を `nil` にする。止めている最中 (待つあいだは
    /// 子が死んでも ``child`` が残る) は ``stoppingChild`` と止めている子の一覧で弾く。だから
    /// **「子は居るのに走っていない」だけが、誰も頼んでいない消え方**である。
    ///
    /// **1 度きりなのは、巡回が 0.25 秒ごとに回るからである。** 消えた状態はそのまま続く
    /// ので、印を持たないと同じ 1 行を毎秒 4 回出し続ける。印は子が入れ替われば下りる。
    ///
    /// **最初の絵を出す前に失敗で終わった子は、走っていた子が消えたのではなく、起こせなかった回である**
    /// ([#3172](https://github.com/mokume-metal/mokume/issues/3172))。根拠は「その子が 1 枚目を出したか」
    /// (``generationShown(pid:)``) で、乗り換えの合図ではない。この回は前の版を現役に戻し
    /// (``Departure/keptPrevious``)、記録を起こせなかった回の形で書き直す。終了コード 0 の子は含めない。
    ///
    /// 名乗るのは口の側である — このクラスは判断だけを持ち、出力を持たない。
    func departed() -> Departure? {
        // **道具が止めている最中の子は、消えたと名乗らない。** 止める待ちが main actor を塞がなく
        // なったので、子が死んでから ``child`` を外すまでの間に巡回が来る (#2576)
        guard let gone = child, !gone.isRunning, !hasNamedDeparture, gone !== stoppingChild,
            !isBringingDown(gone)
        else { return nil }
        hasNamedDeparture = true
        var departure: Departure
        switch ChildEnding(of: gone) {
        case .exited(let status): departure = Departure(status: status, wasSignalled: false)
        case .signalled(let signal): departure = Departure(status: signal, wasSignalled: true)
        }
        // **最初の絵を出す前に、失敗で終わった子は、起こせなかった回である** (#3172)。終了コード 0 は
        // 自分から終わったので、絵を出す前でも含めない
        guard !hasShownFirstFrame(gone), departure.wasSignalled || departure.status != 0 else {
            // 映っている世代が消えた回も、乗り換えを待つ世代が消えて前の世代を畳む回も、台は手放した世代の
            // 頼みを持ち続ける (#2983)。**消えた子の番号を渡す** — 台はまだ採っていないその子の目録も、
            // 生まれたときから手放した扱いにする (#2982)。畳まれる前の世代の番号も添える
            relinquishesDisplay([gone.processIdentifier] + generationPIDs(of: outgoing))
            return departure
        }
        departure.failedToStart = true
        departure.keptPrevious = restorePreviousGeneration(afterLosing: gone)
        departure.report = recordFailedStart(of: gone, departure)
        return departure
    }

    /// その子が、道具の窓に 1 枚目の絵を出したか。
    ///
    /// **窓の無い見張りでは、誰も知らせてくれない** (``overlapsGenerations``)。そこは子が自分の窓を持つので、
    /// 出したものとして扱い、今までどおり「自分で消えた」と読む。
    private func hasShownFirstFrame(_ process: Process) -> Bool {
        !overlapsGenerations || shownPIDs.contains(process.processIdentifier)
    }

    /// 道具の窓が、世代の 1 枚目の絵を出した ([#3172](https://github.com/mokume-metal/mokume/issues/3172))。
    ///
    /// 窓ごとに知らせが来る (作品の窓とプレビュー) ので、2 度呼ばれる。控えるだけで、冪等である。
    ///
    /// - Parameter pid: 1 枚目を出した世代の目録が名乗った子の番号。名乗らない子 (古いライブラリ) は
    ///   `nil` で、最後に起こした子のものと読む (他の合図の推定と同じ)。
    func generationShown(pid: Int32?) {
        guard let pid = pid ?? child?.processIdentifier else { return }
        shownPIDs.insert(pid)
    }

    /// 起こせなかった子の代わりに、映っていた前の世代を現役へ戻す。
    ///
    /// **戻せるのは、1 枚目を出していて、生きていて、道具が止めている最中でない前の世代だけである。** 1 枚も出して
    /// いない前の世代は、台が次の目録 (消えた子の目録) で控えを捨てていて、映せない。戻したときは**台へ手放すのは
    /// 消えた子だけ**にする — 前の版の `noCursor()` とポインタの捕まえは、そのまま効く。戻さないときは、今までどおり
    /// 前の世代の頼みも手放し、口の側が前の世代を畳む。
    ///
    /// - Returns: 前の版を残したか。
    private func restorePreviousGeneration(afterLosing gone: Process) -> Bool {
        guard let previous = outgoing, previous.isRunning, previous !== stoppingChild,
            !isBringingDown(previous), shownPIDs.contains(previous.processIdentifier)
        else {
            relinquishesDisplay([gone.processIdentifier] + generationPIDs(of: outgoing))
            return false
        }
        relinquishesDisplay([gone.processIdentifier])
        child = previous
        outgoing = nil
        awaitingPromotion = false
        // 戻した子が後で消えたときは、また名乗る (``child`` が入れ替わると印は下りる)
        return true
    }

    /// 起動できなかった回を、作り直しが通って子を起こせなかった回 (``BuildReport/notStarted(reason:buildOutput:stamp:configuration:timings:)``)
    /// の形で書く ([#3172](https://github.com/mokume-metal/mokume/issues/3172))。
    ///
    /// **直前の記録が、その子を起こした回 (`ok`・`launched`) のときだけ上書きする。** その子を起こした後に
    /// 作り直しが通らなかった回の記録 (`ok: false`) は、直すべきものを本文に持つので消さない。
    ///
    /// - Returns: 端末とプレビューの言葉の材料にする記録。書かなかったときも、同じ形のものを返す。
    private func recordFailedStart(of gone: Process, _ departure: Departure) -> BuildReport {
        let reason = Self.failedStartReason(
            tool: launchedTool ?? context.product ?? "sketch", place: directory.path,
            departure: departure)
        guard let last = lastReport, last.ok, last.launched else {
            return .notStarted(
                reason: reason, buildOutput: "", stamp: lastStamp, configuration: configurationName,
                timings: .init(detectMs: nil, buildMs: 0, relaunchMs: nil))
        }
        var timings = last.timings
        timings.firstFrameMs = nil
        return finish(
            .notStarted(
                reason: reason, buildOutput: last.output, stamp: last.stamp,
                configuration: last.configuration, timings: timings))
    }

    /// 最初の絵を出す前に終わった子の、起こせなかった理由。
    ///
    /// **既存の「起こせなかった」と同じ頭で言う** (``CommandFailure/cannotLaunch(tool:place:reason:)``)。
    /// プレビューの短縮もこの頭を見る。子の標準エラーは親が読み解かない — どう終わったかだけを言い、
    /// 理由の全文は子が端末へ出している。
    static func failedStartReason(tool: String, place: String, departure: Departure) -> String {
        let how =
            departure.wasSignalled
            ? "it crashed (signal \(departure.status))" : "it exited with code \(departure.status)"
        return CommandFailure.cannotLaunch(
            tool: tool, place: place, reason: "\(how) before drawing its first frame"
        ).message
    }

    /// 映っている前の世代 (``outgoing``) が自分で終わった・落ちたとき、台へその番号で伝える
    /// ([#2983](https://github.com/mokume-metal/mokume/issues/2983))。
    ///
    /// ``departed()`` は ``child`` だけを見る。乗り換えを待つ間に映っている前の世代が消えても、台は消えた
    /// 世代の頼みを持ち続ける。**1 世代につき 1 度だけ伝える。** 止めている最中の世代 (道具が畳む回) は
    /// 畳む側の口が伝えるので、ここでは見ない。
    func relinquishIfOutgoingDeparted() {
        guard let gone = outgoing, !gone.isRunning, gone !== stoppingChild, !isBringingDown(gone),
            gone !== relinquishedOutgoing
        else { return }
        relinquishedOutgoing = gone
        relinquishesDisplay([gone.processIdentifier])
    }

    /// 消えたことを台へ伝え済みの前の世代。
    private var relinquishedOutgoing: Process?

    /// 走らせているものを終わらせる。
    ///
    /// **期限を持つ。** 頼んで止まらなければ強制的に落とす — 子は人が書いたスケッチなので、
    /// `SIGTERM` を捕まえて戻らない形はいつでも作れる。期限が無いと**終われないだけでなく、
    /// 保存のたびに固まる**: 差し替えもこの経路を通るからである
    /// ([#732](https://github.com/mokume-metal/mokume/issues/732))。
    ///
    /// **待つあいだ main actor を塞がない** ([#2576](https://github.com/mokume-metal/mokume/issues/2576))。
    /// 応えない子では最大 3.5 秒かかるので、main の上で眠って待つと、保存のたびに窓の描き直しも
    /// × の問いも止まる。**戻るのは止め終えてからである** — 止めてから次の子を起こす順序は
    /// 呼ぶ側が持つ。
    ///
    /// - Returns: 3 通りの結果。呼ぶ側はそれぞれを別の出来事として名乗れる。
    @discardableResult
    func stop() async -> StopOutcome { await stop(timeout: stopTimeout) }

    /// 見張りを**終えるときに**、走らせているものを終わらせる。
    ///
    /// ``stop()`` との違いは待つ長さだけで、撮っていた動画を閉じ終えるまで待つ
    /// (``finishTimeout``・[#1219])。**差し替えは ``stop()`` を通る** ので、延ばすのはこちらに
    /// 限る — 分けておかないと、窓を持たない見張りでは保存のたびに長く待つ。
    ///
    /// [#1219]: https://github.com/mokume-metal/mokume/issues/1219
    @discardableResult
    func end() async -> StopOutcome { await stop(timeout: finishTimeout) }

    private func stop(timeout: TimeInterval) async -> StopOutcome {
        // **退役待ちも置いていかない。** 入れ替わりの合図が来る前に終わることがある。子と並べて
        // 止める — 順に待つと、退役の子が応えないあいだ現役の子へ頼みが届かない
        let retiring = Task { await self.retireOutgoing() }
        // **止めている間に、持っている子が入れ替わりうる。** 待つあいだ main actor を手放すので、
        // 差し替えの途中に終わりが来ると同じ子を 2 つの口が止めに行く (止め方は 1 つに畳まれる)。
        // 後から戻ったほうが、先に起こされた次の子を手放さないように、止めた相手を覚えておく
        let leaving = child
        stoppingChild = leaving
        let outcome = await bringDown(leaving, timeout: timeout)
        if child === leaving { child = nil }
        if stoppingChild === leaving { stoppingChild = nil }
        lastStop = outcome
        _ = await retiring.value
        // **誰が始めた止めでも、済むまで戻らない。** 戻った後は置いていく子が居ない、が
        // 終えるときの約束である (#454)
        await settle()
        return outcome
    }

    /// 走っているものを、**待つあいだ main actor を塞いで**終わらせる。
    ///
    /// **プロセスが終わる直前の後始末だけが使う** (``WatchCommand/teardown(_:_:created:)``)。
    /// 通常の終わり方 (巡回を抜けるとき・Dock やログアウトの終了) は ``end()`` を窓を開いた
    /// まま済ませてから抜けるので、ここへは来ない。それでも置いていかないために、残って
    /// いるものがあれば止め方は同じ手順 (``Shutdown``) で止める。検査の後始末にも使う。
    ///
    /// - Parameter timeout: 頼んでから強制終了へ進むまでの上限 (秒)。省けば ``stopTimeout``。
    @discardableResult
    func stopBlocking(timeout: TimeInterval? = nil) -> StopOutcome {
        if isRebuilding, let build = hooks.stopRebuild() {
            bringDownBlocking(build, timeout: stopTimeout, interrupting: true)
        }
        if let leaving = outgoing {
            outgoing = nil
            bringDownBlocking(leaving, timeout: stopTimeout)
        }
        let outcome = bringDownBlocking(child, timeout: timeout ?? stopTimeout)
        child = nil
        lastStop = outcome
        return outcome
    }

    /// 走っている作り直しを、途中で止める。
    ///
    /// **見張りは作り直しを待たずに終われる** (#834) ので、止めないと `swift build` は
    /// launchd に付け替えられて残る。自分から消えるのは閉じた管へ次の 1 行を書いたとき
    /// なので、残る長さは出力が途切れている長さで決まり、その間 `.build` の鍵を握って
    /// **起こし直した見張りを待たせる** (手元で実測・[#1147](https://github.com/mokume-metal/mokume/issues/1147))。
    ///
    /// **止めたことを記録に書く。** 書かないと区画には前の回の記録が残り、読み手は
    /// 何が起きたかを読めない。失敗 (`ok: false`) として書くが、**本文の先頭で「途中で
    /// 止めた」と名乗る** — 建っていない回を `output` で名乗った #1066 と同じ形で、
    /// 読み手が要るのは分岐する欄ではなく「なぜ絵が変わらないか」の本文である。
    ///
    /// - Returns: 作り直していなければ `nil`。止めた子の結果は ``bringDown(_:timeout:interrupting:)`` と同じ
    ///   分け方で、**`.notRunning` は「止めると決めたが、その瞬間に走っている `swift` が
    ///   無かった」** (作り直しは `swift` を何度か呼ぶ) — 次の 1 本は起こされない。
    @discardableResult
    func stopRebuilding() async -> StopOutcome? {
        // **作り直しの中だけを止める。** 差し替えの最中 (作り直しは建ち終えている) に止めた記録を
        // 書くと、建ち終えた回が「途中で止めた」ことになる。そこは差し替えの側が、終われと言われた
        // ことを見て起こさずに抜ける (#2576)
        guard isRebuilding, isBuilding, stoppedReport == nil, rebuildStop == nil else { return nil }
        let running = hooks.stopRebuild()
        // **止めている間に、作り直しが戻ってくる。** 止めた子は終了コードを持って戻るので、
        // 記録を書き終える前に作り直しの続きが走ると、止めた記録を失敗で書き直してしまう
        // (#1147)。待つあいだ main actor を手放すので、続きの側が ``rebuildStop`` を待てる形に
        // しておく ([#2576](https://github.com/mokume-metal/mokume/issues/2576))
        let stopping = Task { () -> StopOutcome in
            let outcome = await self.bringDown(
                running, timeout: self.stopTimeout, interrupting: true)
            // **終わっていない子の終了コードは読まない** (読むと例外で落ちる)。置いていった回と、
            // 走っている子が無かった回は、止めた合図の慣習の値で書く
            let status =
                running.flatMap { $0.isRunning ? nil : ChildEnding(of: $0).shellStatus }
                ?? (128 + SIGINT)
            let report = BuildReport.failed(
                status: status, output: Self.stoppedRebuildNotice, stamp: self.lastStamp,
                configuration: self.configurationName,
                timings: .init(
                    detectMs: nil,
                    buildMs: self.rebuildStartedAt.map { (self.hooks.now() - $0) * 1000 } ?? 0,
                    relaunchMs: nil))
            self.stoppedReport = self.finish(report)
            return outcome
        }
        rebuildStop = stopping
        let outcome = await stopping.value
        rebuildStop = nil
        return outcome
    }

    /// 作り直しを途中で止めた回の記録の本文。**失敗とは違う言葉で始める。**
    ///
    /// 建たなかった回の本文は道具立ての出力で始まり、端末の要約は `Build failed:` で
    /// 始まる — そのどちらとも読み違えないように、止めたことと理由を先頭に置く (#1147)。
    static let stoppedRebuildNotice =
        "The rebuild was stopped partway because watching ended — this is not a build failure, "
        + "and nothing was found wrong with the source"

    /// 退役待ちを止める。
    ///
    /// **何度呼んでもよい。** 入れ替わりの合図は窓ごとに来る (作品の窓とプレビューは独立に
    /// 見ている) ので、同じ入れ替えで 2 度呼ばれる。止めている最中に来た 2 度目は、同じ子を
    /// 重ねて止めずに、止め終わるのを待って戻る (名乗りは最初の 1 度だけ)。
    ///
    /// **待つあいだ main actor を塞がない** ([#2576](https://github.com/mokume-metal/mokume/issues/2576))。
    /// 合図は窓の側から main に来るので、ここで眠ると窓の描き直しがその間止まる。
    ///
    /// - Returns: 止めた結果。居なければ `nil` — **名乗るのは口の側**なので、期限に掛かった
    ///   ことを言うために返す (#732 の規律は差し替えの経路にも効く)。
    @discardableResult
    func retireOutgoing() async -> StopOutcome? {
        var outcome: StopOutcome?
        if let leaving = outgoing, !isBringingDown(leaving) {
            // **止め終えるまで ``outgoing`` を残す。** 外すと、待っている間の入力 (``send(_:)``) が
            // まだ画面に出ている世代ではなく、次の世代へ届く
            outcome = await bringDown(leaving, timeout: stopTimeout)
            if outgoing === leaving { outgoing = nil }
        }
        // 止めている最中の他の口があれば、それが済むまで待つ (戻った後は、畳むはずの世代が居ない)
        await settle()
        // 退役のたびに古い目印を掃く (#2350)。**乗り換えを待っている世代の目印は残す** — まだ見ていない
        sweepFellBackMarkers(keeping: awaitingPromotion ? child?.processIdentifier : nil)
        return outcome
    }

    // MARK: - 子を止める

    /// 止めている最中の子。**子ごとに 1 つの止め方に畳む。**
    ///
    /// 待つあいだ main actor を手放すので、同じ子を止める口が重なる — 差し替えの途中に終わりが
    /// 来る・入れ替わりの合図が窓ごとに 2 度来る。重ねて `SIGTERM` を撃つと、後始末の最中の子が
    /// もう 1 度後始末に入る。後から来た口は、先の止め方の結果を待つ。
    private var shutdowns: [ObjectIdentifier: Task<StopOutcome, Never>] = [:]

    /// 作り直しを止めている最中の仕事。**作り直しの続きは、これが済むまで結果を使わない。**
    private var rebuildStop: Task<StopOutcome, Never>?

    private func isBringingDown(_ process: Process) -> Bool {
        shutdowns[ObjectIdentifier(process)] != nil
    }

    /// 止めている最中の子がすべて止まるまで待つ。
    private func settle() async {
        while let pending = shutdowns.values.first { _ = await pending.value }
    }

    /// 1 つの子を落とす。**期限を持つ。**
    ///
    /// 呼び手が 3 つある (終わるとき・退役させるとき・作り直しを止めるとき) ので、判断は
    /// ここ 1 つに置く — 刻みの細かさも `StopOutcome` の分け方も、割れない。**期限だけは
    /// 呼び手が渡す** — 終わるときだけ、撮っていた動画を閉じ終えるまで待つ (#1219)。
    ///
    /// **待つのは main actor の外である** ([#2576](https://github.com/mokume-metal/mokume/issues/2576))。
    /// 頼む (合図を撃つ) のはここ、main actor の上で済ませ、期限を数えて待つ仕事は切り離して走らせる —
    /// main の上で眠ると、応えない子では最大 3.5 秒、窓の描き直しも × の問いも止まる。切り離す
    /// 側で待つので、期限は main の込み具合に左右されない (``Hooks/rebuild`` が作り直しを
    /// main の外で待つのと同じ分担)。
    ///
    /// **同じ子を止める口が重なったら、後から来た口は先の止め方に従う。** 先の期限で決着し、
    /// 結果も先のものを受け取る — 差し替えの ``stop()`` (3 秒) の最中に ``end()`` が来ても、
    /// 動画を閉じる分の延長は効かない。止める口が同期だった頃も、先の ``stop()`` が塞いでいる
    /// 間に ``end()`` は呼べなかったので、順に 3 秒待ってからの終わりになり、結果は同じである。
    ///
    /// - Parameter timeout: 頼んでから、強制終了へ進むまでの上限 (秒)。``stopTimeout`` を
    ///   越える分を待つときは、越えた時点で ``willWaitForFinish`` を 1 度呼ぶ。
    /// - Parameter interrupting: 頼むのに `SIGTERM` ではなく `SIGINT` を使うか。**作り直し
    ///   (`swift build`) だけが使う。** SwiftPM が畳みの処理を持つのは `SIGINT` の側で、
    ///   `SIGTERM` では本体だけが死んで `swift-driver` と `swift-frontend` が launchd に
    ///   付け替えられて残る。手元の実測では `SIGINT` は配下ごと 0.4 秒で消え、`SIGTERM` は
    ///   配下が 1〜4.5 秒残った ([#1147](https://github.com/mokume-metal/mokume/issues/1147))。
    private func bringDown(
        _ running: Process?, timeout: TimeInterval, interrupting: Bool = false
    ) async -> StopOutcome {
        guard let running, running.isRunning else { return .notRunning }
        let key = ObjectIdentifier(running)
        if let pending = shutdowns[key] { return await pending.value }
        // **頼むのは、ここで同期に済ませる。** 切り離す仕事が走り出すのを待つと、頼んだ後に
        // 呼び手へ制御が戻る前に、別の口が同じ子を止めに入れる
        let runner = ShutdownRunner(
            Shutdown(
                running, timeout: timeout, stopTimeout: stopTimeout, killGrace: Self.killGrace,
                interrupting: interrupting))
        let task = Task { () -> StopOutcome in
            let outcome = await runner.run { remaining in
                Task { @MainActor in self.willWaitForFinish(remaining) }
            }
            // **値を返す前に外す。** 待っていた口が戻ったとき、もう居ないものを待ち続けない
            self.shutdowns[key] = nil
            return outcome
        }
        shutdowns[key] = task
        return await task.value
    }

    /// ``bringDown(_:timeout:interrupting:)`` の、main actor を塞ぐ版。
    ///
    /// **プロセスが終わる直前の後始末 (``stopBlocking(timeout:)``) だけが使う。** 手順は同じ
    /// ``Shutdown`` で、待ち方だけが違う。
    @discardableResult
    private func bringDownBlocking(
        _ running: Process?, timeout: TimeInterval, interrupting: Bool = false
    ) -> StopOutcome {
        guard let running, running.isRunning else { return .notRunning }
        var shutdown = Shutdown(
            running, timeout: timeout, stopTimeout: stopTimeout, killGrace: Self.killGrace,
            interrupting: interrupting)
        while true {
            switch shutdown.poll(now: DispatchTime.now()) {
            case .finished(let outcome): return outcome
            case .extending(let remaining): willWaitForFinish(remaining)
            case .waiting: break
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    /// ``Shutdown`` を、main actor の外で最後まで進める。
    ///
    /// **専用の待ち行列と時計の刻みで進める。** `Task.sleep` で回す形は、async の仕事を回す
    /// 共有の枠 (協調スレッドプール) に載る — その枠が他の仕事で埋まっている間は刻みが遅れ、
    /// 期限を越えて待つことになる。期限は子を落とすための数字なので、他の仕事の込み具合に
    /// 左右されない足場に置く。
    ///
    /// **1 つの仕事だけが触る。** ``bringDown(_:timeout:interrupting:)`` が頼んだ手順を 1 度だけ
    /// 渡し、刻みの中でだけ進める — 値は 2 つの隔離を渡るが、同時に 2 か所から触られることは無い。
    private nonisolated final class ShutdownRunner: @unchecked Sendable {
        private var shutdown: Shutdown

        init(_ shutdown: Shutdown) { self.shutdown = shutdown }

        /// - Parameter extending: 最初の期限を越えて、さらに待つと決めたときに呼ぶ (1 度だけ)。
        ///   **待ち行列の上で呼ばれる** ので、main actor に用があれば呼ぶ側が渡す。
        func run(extending: @escaping @Sendable (TimeInterval) -> Void) async -> StopOutcome {
            await withCheckedContinuation { continuation in
                let queue = DispatchQueue(label: "mokume.watch.shutdown", qos: .userInitiated)
                let timer = DispatchSource.makeTimerSource(queue: queue)
                // **細かく刻む。** 差し替えのときもここを通るので、粗いと保存の反映が
                // そのぶん遅れて見える
                timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
                timer.setEventHandler {
                    switch self.shutdown.poll(now: DispatchTime.now()) {
                    case .finished(let outcome):
                        timer.cancel()
                        continuation.resume(returning: outcome)
                    case .extending(let remaining): extending(remaining)
                    case .waiting: break
                    }
                }
                timer.resume()
            }
        }
    }

    /// 子を止める手順。**待たずに進める。**
    ///
    /// 頼む → 期限まで待つ → (終えるときだけ) 後始末の分を延ばして待つ → 強制終了する →
    /// 消えるのを待つ、の順で、``poll(now:)`` を呼ぶたびに 1 歩だけ進める。**待ち方 (眠るか・
    /// 他の仕事へ手放すか) は呼ぶ側が決める** ので、同じ手順を main を塞ぐ版と塞がない版が
    /// 分け持つ ([#2576](https://github.com/mokume-metal/mokume/issues/2576))。
    ///
    /// **期限は、眠っている間は進まない時計 (`DispatchTime`) で測る。** 壁時計 (`Date`)
    /// は機械が眠っている間も進むので、待っている最中に蓋を閉じて開けると、起きた瞬間に
    /// 期限を越えたと読み、後始末の途中の子を `SIGKILL` で落とす ([#1940])。待つ相手の
    /// 時計も同じ種類である — 動画を閉じる側 (`MovieWriter`) も背圧の待ち (`Backpressure`)
    /// も `DispatchTime` で期限を置くので、``defaultFinishTimeout`` がそれを覆う関係は、
    /// 待つ側が同じ種類の時計で測ってはじめて眠りを挟んでも崩れない ([#1219])。
    ///
    /// **時計は ``Hooks`` に載せない。** 差し替えられた時計で測ると、期限が永久に来ないか
    /// 即座に来るかのどちらかになる (検査の時計は 0 を返す) — ここで見ているのは
    /// 「実際にどれだけ待ったか」であって、記録に載る所要時間 (``Hooks/now``) ではない。
    /// 本番では両方とも眠りで進まない時計だが、検査が差し替えるのは後者だけである。
    ///
    /// [#1940]: https://github.com/mokume-metal/mokume/issues/1940
    /// [#1219]: https://github.com/mokume-metal/mokume/issues/1219
    nonisolated struct Shutdown {
        /// 1 歩進めた結果。
        enum Poll: Equatable {
            /// まだ待つ。
            case waiting
            /// 最初の期限を越えたので、さらにこの秒数まで待つ。**1 度だけ返す。**
            case extending(TimeInterval)
            /// 決着した。
            case finished(StopOutcome)
        }

        private enum Phase {
            /// 頼んだ。期限まで待つ。
            case asked(until: DispatchTime)
            /// 後始末の分を延ばして待つ (終えるときだけ)。
            case extended(until: DispatchTime)
            /// 強制終了した。消えるのを待つ。
            case killed(until: DispatchTime, pid: Int32)
        }

        private let process: Process
        private let extra: TimeInterval
        private let killGrace: TimeInterval
        private var phase: Phase

        /// 頼む。**ここで合図を撃つ。**
        init(
            _ process: Process, timeout: TimeInterval, stopTimeout: TimeInterval,
            killGrace: TimeInterval, interrupting: Bool, now: DispatchTime = .now()
        ) {
            if interrupting { process.interrupt() } else { process.terminate() }
            let first = min(timeout, stopTimeout)
            self.process = process
            self.extra = timeout > first ? timeout - first : 0
            self.killGrace = killGrace
            self.phase = .asked(until: now + first)
        }

        /// 1 歩進める。**消えたことは、期限より先に見る** — 期限の瞬間に終わった子を落とさない。
        mutating func poll(now: DispatchTime) -> Poll {
            switch phase {
            case .asked(let until):
                if !process.isRunning { return .finished(.terminated) }
                guard now >= until else { return .waiting }
                guard extra > 0 else { return kill(now) }
                phase = .extended(until: now + extra)
                return .extending(extra)
            case .extended(let until):
                if !process.isRunning { return .finished(.terminated) }
                guard now >= until else { return .waiting }
                return kill(now)
            case .killed(let until, let pid):
                // **消えたことを確かめる。** 捕まえられない合図でも、割り込めない待ちに入って
                // いるものは即座には消えない — 確かめずに名乗ると、置いていったものを
                // 「止めた」と言うことになる (#732)
                if !process.isRunning { return .finished(.killed) }
                guard now >= until else { return .waiting }
                return .finished(.abandoned(pid: pid))
            }
        }

        private mutating func kill(_ now: DispatchTime) -> Poll {
            // **宛先を確かめてから撃つ。** 起動していない `Process` の番号は 0 で、
            // `kill(0, …)` は**自分のプロセスグループごと**落とす。呼ぶ側の guard が弾いている
            // 形だが、暗黙に頼らない
            let pid = process.processIdentifier
            if pid > 0, process.isRunning { Darwin.kill(pid, SIGKILL) }
            phase = .killed(until: now + killGrace, pid: pid)
            return .waiting
        }
    }

    private func rebuildAndReplace(stamp: String?, initial: Bool = false) async -> BuildReport {
        isRebuilding = true
        defer { isRebuilding = false }
        let detectMs = noticedAt.map { (hooks.now() - $0) * 1000 }
        noticedAt = nil
        // **前の巡回の止め方を持ち越さない。** 作り直しが通らなければこの回は子を止めない
        // ので、消さずにおくと**何も止めていない回に**「強制終了した」と名乗ることになる
        lastStop = nil

        // **始めることを、始める前に言う。** 作り直しはこの流れを塞ぐので、後から言うと
        // 待っている間が無言になる (#695)
        willRebuild(initial)

        // **始める前に置く。** 壊れたままのソースで作り直しを繰り返さないため (直したら
        // 世代が変わるので、そのとき次の作り直しが走る) であり、かつ**作り直しの最中に来た
        // 巡回が、いま作り直している世代を「変化」と読まない**ためである。
        //
        // 終わってから置いていた頃は、初回の作り直し (いちばん長い) の最中に来た巡回が
        // 変化だと読んで「気付いた時刻」を置き、それが次の保存まで残った — 記録の
        // `detect_ms` に、保存を待っていた時間がまるごと乗る (手元では 12 秒を実測)。
        // 作り直しが main actor を塞がなくなって、初めて巡回がそこへ来るようになった (#834)
        lastStamp = stamp

        let buildStarted = hooks.now()
        rebuildStartedAt = buildStarted
        let rebuilt: RunCommand.Rebuilt
        isBuilding = true
        do throws(CommandFailure) {
            rebuilt = try await hooks.rebuild(directory)
        } catch {
            // **起こせなかったことを、作り直しの失敗と同じ顔にする。** 終了コードは 1 に
            // 倒し、**理由は本文に載せる** — 顔だけ揃えて理由を捨てていた頃は、記録の
            // `output` が空になり、読み手にも端末にも「失敗した」しか届かなかった (#1100)
            rebuilt = RunCommand.Rebuilt(
                status: 1, output: error.message, executable: nil,
                binPath: context.directory(under: directory), product: context.product)
        }
        let buildMs = (hooks.now() - buildStarted) * 1000
        isBuilding = false

        // **止めている最中なら、止め終えてから見る。** 止めた子は終了コードを持って戻るので、
        // 記録を書き終える前に下を読むと、止めた記録が失敗で書き直される (#1147)。止める待ちが
        // main actor を塞がなくなったので、続きが先に走りうる ([#2576](https://github.com/mokume-metal/mokume/issues/2576))
        _ = await rebuildStop?.value

        // **途中で止めた回は、戻ってきた結果で何も決めない。** 止めた子の終了コードで
        // 失敗を書き直すと、止めた記録が「壊れていた」に化ける。子も起こさない — 止めるのは
        // 見張りが終わるときだけである (#1147)
        if let stoppedReport { return stoppedReport }

        // **在るのに起こせない成果物を「建っていない」と言わない** (#2521)。作り直しは実行
        // できるものだけを「建った」と返すので、実行ビットの無い成果物は下の「建っていない」へ
        // 落ちていた。通ったのに起こせない回として名乗り、走っているものは落とさない
        if rebuilt.status == 0, rebuilt.executable == nil, let product = rebuilt.product,
            let reason = RunCommand.unrunnableProduct(product, in: rebuilt.binPath)
        {
            let failure = CommandFailure.cannotLaunch(
                tool: product, place: directory.path, reason: reason)
            return finish(
                .notStarted(
                    reason: failure.message, buildOutput: rebuilt.output, stamp: stamp,
                    configuration: configurationName,
                    timings: .init(detectMs: detectMs, buildMs: buildMs, relaunchMs: nil)))
        }

        // **通ったことと、走らせるものが在ることは別である。** 置き場を他の誰かと
        // 共有していると、作り直しが「通った」のに実行ファイルが建っていないことが
        // 起きる (#1055)。そこを成功として記録すると、症状は「作り直したと出たのに
        // 絵が止まっている」になり、**記録のどこにも理由が出ない** (#1066)
        guard rebuilt.status == 0, let executable = rebuilt.executable else {
            // **走っているものは落とさない。** 直前の版が動き続けるのが、
            // 作り直しが失敗したときに最も助かる振る舞いである
            return finish(
                .failed(
                    status: rebuilt.status,
                    output: unbuiltNotice(rebuilt) ?? rebuilt.output, stamp: stamp,
                    configuration: configurationName,
                    timings: .init(detectMs: detectMs, buildMs: buildMs, relaunchMs: nil)))
        }

        // **終われと言われた後は、起こさない。** ここへ来るのは作り直しを待っている間に
        // 巡回が畳まれた回で、起こしても止める者がもう居ない (#834)。作り直し自体は通って
        // いるので、記録には通ったと書いて「起こしていない」だけを名乗る
        //
        // **起こさなかった理由を本文の頭で名乗る** (#2521)。`launched: false` だけでは、
        // 起こせなかった回と見分けが付かない
        func notStartedForStopping() -> BuildReport {
            finish(
                .notStarted(
                    reason: Self.stopRequestedNotice, buildOutput: rebuilt.output, stamp: stamp,
                    configuration: configurationName,
                    timings: .init(detectMs: detectMs, buildMs: buildMs, relaunchMs: nil)))
        }
        guard !stopRequested else { return notStartedForStopping() }

        let relaunchStarted = hooks.now()
        // **どの世代の合図か区別できる回だけ測る。** 前の世代がまだ乗り換わらずに生きて
        // いると、次の合図はそちらのものかもしれない。新しいライブラリの子は目録が子の番号を名乗り、
        // 合図は待っている世代のものだけを受ける (``generationPromoted(pid:)``・#2982) が、番号を
        // 名乗らない古いライブラリの子は印が無いので、ここでは区別できる回だけを測る
        let measuresFirstFrame =
            overlapsGenerations && hasSeenPromotion
            && !(awaitingPromotion && child?.isRunning == true)
        if overlapsGenerations {
            // **止めるのは、新しい世代が画面に出てからである** (#1142)。合図が来ないまま
            // 次の保存が来た回は、ここで必ず止める — 重ねるのは 1 世代だけである
            // **映っている世代が、まだ乗り換えを待っている回だけ。** 乗り換えの合図の後は、止め終えるまで
            // `outgoing` が残るが、台は既に新しい子へ映している — そこで伝えると、生きて映っている世代の
            // 頼みを手放させる (#2983)
            let displayedGenerationRetired = outgoing != nil && awaitingPromotion
            let retiredPIDs = generationPIDs(of: outgoing)
            await retireOutgoing()
            // **映っていた世代を、乗り換えの合図が来ないまま畳んだ回** — 台は畳まれた世代の頼みを持ち続け、
            // 読み直す契機も来ない (#2983)
            // **待った後にもう 1 度、乗り換えを待っているかを見る。** 止めている間に台が次の世代へ乗り換えて
            // (合図が走って待ちが下りて) いれば、映っているのは生きている新しい世代である。番号を名乗る世代は
            // 台が番号で外すが、名乗らない世代 (古いライブラリ) は、ここで外さないと手放させてしまう
            if displayedGenerationRetired && awaitingPromotion { relinquishesDisplay(retiredPIDs) }
            if let early = interruptedWhileStopping(notStarted: notStartedForStopping) {
                return early
            }
            outgoing = child
            child = nil
        } else {
            await stop()
            if let early = interruptedWhileStopping(notStarted: notStartedForStopping) {
                return early
            }
        }
        // **起こせなかった理由は記録の本文の頭へ載せる** (#2521)。作り直しの出力はその後に
        // 続ける — 建っていない回 (``unbuiltNotice(_:)``) と同じ形で、読み手は頭の行で
        // 何が起きたかを読める
        // **新しい子を起こす前に、古い目印を掃く** (#2350)。後の子が同じ pid を巡り当てても、倒れたと読まれない
        sweepFellBackMarkers(keeping: nil)
        // **絵を出したと覚えるのは、生きている世代のぶんだけ。** 番号は使い回されるので、居なくなった世代の
        // 覚えを残すと、同じ番号の新しい子を、もう絵を出したと読む (#3172)
        shownPIDs.formIntersection([child, outgoing].compactMap { $0?.processIdentifier })
        launchedTool = executable.lastPathComponent
        var launchFailure: CommandFailure?
        do throws(CommandFailure) {
            child = try hooks.launch(
                executable, directory, stamp, reportsRate ? configurationName : nil)
        } catch {
            child = nil
            launchFailure = error
        }
        // **書き口を塞がない形にしてから渡す。** 入力が来るのは窓が出た後なので、ここで
        // 立てておけば「読まない子へ書いて固まる」回は作れない (#1296)
        unblockWriting(to: child)
        let relaunchMs = (hooks.now() - relaunchStarted) * 1000
        awaitingPromotion = overlapsGenerations && child != nil

        let timings = BuildReport.Timings(
            detectMs: detectMs, buildMs: buildMs, relaunchMs: relaunchMs)
        let report: BuildReport =
            if let launchFailure {
                .notStarted(
                    reason: launchFailure.message, buildOutput: rebuilt.output, stamp: stamp,
                    configuration: configurationName, timings: timings)
            } else {
                .launched(
                    output: rebuilt.output, stamp: stamp, configuration: configurationName,
                    timings: timings)
            }
        return finish(
            report, firstFrameSince: measuresFirstFrame && child != nil ? relaunchStarted : nil)
    }

    /// 前の子を止めている間に、作り直しを止める・見張りを終える頼みが来ていないかを見る。
    ///
    /// **止める待ちが main actor を塞がなくなったので、その間に終わりが来うる**
    /// ([#2576](https://github.com/mokume-metal/mokume/issues/2576))。来ていたら次の子を起こさない —
    /// 起こしても止める者がもう居ない (#454 の孤児と同じ形)。
    ///
    /// - Returns: 起こさずに抜けるなら、その回の記録。続けてよければ `nil`。
    private func interruptedWhileStopping(notStarted: () -> BuildReport) -> BuildReport? {
        if let stoppedReport { return stoppedReport }
        return stopRequested ? notStarted() : nil
    }

    /// 次の世代が画面へ乗り換わった。**新しい絵が出るまでを記録へ足し、退役待ちを畳む。**
    ///
    /// 合図は窓ごとに来る (作品の窓とプレビューは独立に見ている) ので、同じ入れ替えで
    /// 2 度呼ばれる。測るのは最初の 1 度だけで、退役は冪等である。
    ///
    /// **記録は書き直す。** 起こし終えた時点の記録は既に置いてあるので、同じ区画へ
    /// 丸ごと原子的に置き直す — 別のファイルへ書き足すと、読み手は形を 2 つ知ることになる。
    ///
    /// **測らない回** (``BuildReport/Timings/firstFrameMs`` が空になる):
    /// - 窓を出せない実行 — そもそも合図が来ない
    /// - まだ 1 度も合図を受けていない間に起こした世代 (初回を含む) — 合図が絵を指さない
    ///   (``hasSeenPromotion``)
    /// - 前の世代が乗り換わらずに生きているうちに差し替えた回 — どちらの合図か分からない
    /// - 起こした後に別の記録で上書きされた回
    ///
    /// - Returns: 退役待ちを止めた結果。**名乗るのは口の側**である (``retireOutgoing()``)。
    @discardableResult
    func generationPromoted(pid: Int32? = nil) async -> StopOutcome? {
        // **合図が名乗った子が、待っている世代でなければ受けない** ([#2982](https://github.com/mokume-metal/mokume/issues/2982))。
        // 保存を続けた回、前の世代 (C) が 1 枚焼いて乗り換えた合図は、待っている次の世代 (D) のものでは
        // ない。待ちを下ろして C を畳むと、D が倒れても受け取れなくても、見張りはもう待っていないので
        // 何もせず、道具の窓には畳まれた C の絵が凍る。映る世代が変わっただけなので、待ちも前の世代も
        // そのままにする。番号を名乗らない合図 (古いライブラリの子) は今までの推定
        if let pid, awaitingPromotion, let waiting = child, pid != waiting.processIdentifier {
            return nil
        }
        // **時刻は退役より先に取る。** 退役は期限つきで子の終わりを待つので、後に取ると
        // 止める待ちが絵の出た時刻に乗る
        let now = hooks.now()
        hasSeenPromotion = true
        awaitingPromotion = false
        if let since = firstFrameSince, var report = lastReport {
            report.timings.firstFrameMs = (now - since) * 1000
            finish(report)
        }
        return await retireOutgoing()
    }

    /// 起こした子が共有面を作れず自分の窓へ倒れたと知らされていたら、**乗り換えの合図を待たずに**
    /// 前の世代を退役させる ([#2350](https://github.com/mokume-metal/mokume/issues/2350))。
    ///
    /// 前の世代を畳むのは、道具の窓が新しい世代の目録を採った合図 (``generationPromoted()``) だけ
    /// だった。倒れた子は目録を置かないので合図が来ず、前の世代 (道具の窓に映る) と倒れた子 (自分の
    /// 窓) が次の保存か見張りの終わりまで並走し、道具の窓が拾った出来事は前の世代へ送られ続けた。
    /// 倒れた子は「乗り換えた」とみなす — 保存した版を走らせるのが見張りの目的で、重ねるのは 1 世代
    /// だけという規律 (``outgoing``) とも合う。代償は、道具の窓には絵が出ず (最後の絵が残る)、絵と
    /// 入力は子の窓に移ること。
    ///
    /// **知らせは子が区画へ置く目印である** (``WorkDirectory/fellBackURL(forProcess:under:)``)。**乗り換え
    /// を待っている世代の pid のものだけを見る** — 前の世代や、死んだ世代の目印を新しい世代のものと
    /// 取り違えない。見た目印は消す。
    ///
    /// ``generationPromoted()`` とは別の口である。あちらは「新しい絵が出た」ことを記録へ足し
    /// (``hasSeenPromotion``)、こちらは絵が道具の窓に出ていないので、足さない。
    ///
    /// - Returns: 知らされていなければ `nil`。知らされたなら、前の世代を畳んだかと、その結果
    ///   (**名乗るのは口の側**・``retireOutgoing()``)。
    func retireAfterFallback() async -> (previous: FallbackPrevious, outcome: StopOutcome?)? {
        guard awaitingPromotion, let waiting = child else { return nil }
        let facet = WatchCommand.viewportFacet(under: facetBase)
        let marker = WorkDirectory.fellBackURL(forProcess: waiting.processIdentifier, under: facet)
        guard FileManager.default.fileExists(atPath: marker.path) else { return nil }
        try? FileManager.default.removeItem(at: marker)
        // **倒れた子は自分の窓に絵を出す**ので、絵を出す前に終わった子とは読まない (#3172)。台からの合図は来ない
        shownPIDs.insert(waiting.processIdentifier)
        // 倒れた子は目録を置かないので、台は前の世代 (畳まれる) を映したまま頼みを持ち続ける (#2983)。
        // **前の世代を止めた後に伝える** — 止める前に伝えると、止まるまでに書く 1 枚で台が読み直す
        // 倒れた子 (自分の窓を開く) は目録を置かないので、台が採ることは無い。手放す世代に含めてよい
        return await retireAsPromoted(letGo: [waiting.processIdentifier])
    }

    /// 起こした子の絵を道具の窓が受け取れないと知らされていたら、**乗り換えの合図を待たずに**
    /// 前の世代を退役させる ([#2928](https://github.com/mokume-metal/mokume/issues/2928))。
    ///
    /// 知らされる形は、目録が読めない・目録は読めたが番号の面を引けない (``UndeliverableGeneration``)
    /// の 2 つで、どちらも道具の側で決まる失敗である。同じ目録を読み直しても変わらない (目録の書き手は
    /// 原子的に置く) ので、時計は要らない。**1 枚も焼かない形はここへ来ない** — `setup()` が長いのと
    /// 固まったのとは時計なしに見分けられず、前の世代を畳むと絵が凍る (ADR-0032 決定 3)。
    /// 倒れた子 (``retireAfterFallback()``) と同じく、**乗り換えたとみなす**。代償は、道具の窓には
    /// 最後の絵が残り、窓の入力は絵の出ない新しい子へ届くこと。
    ///
    /// **乗り換えを待っている、生きている世代のぶんだけ受ける。** 知らせは世代の印を持たないので、
    /// 待っていない回 (前の世代・次の世代・重ねない見張り) は何もしない。子が既に居ない回は
    /// 「子の離脱」の口 (``departed()``) が畳む — ここでも名乗ると二重になる。窓ごとに知らせが来るので
    /// (作品の窓とプレビューは独立に目録を読む)、2 度目は待ちが下りていて何もしない。
    ///
    /// - Parameter pid: 知らせが読めた目録の子の番号。**あれば、待っている世代でなければ受けない** (#2982)。
    /// - Returns: 受けなかったなら `nil`。受けたなら、前の世代を畳んだかと、その結果
    ///   (**名乗るのは口の側**・``retireOutgoing()``)。
    func retireAfterUndeliverable(
        waiting: Process?, pid: Int32? = nil
    ) async -> (previous: FallbackPrevious, outcome: StopOutcome?)? {
        // **知らせを受けた時点の世代と、いまの世代が同じときだけ。** 知らせは世代の印を持たず、`Task` で
        // 遅れて捌かれる — 作り直しの続きが先に走ると、前の世代 (C) の知らせが次の世代 (D) に当たる
        // (``waitingGeneration``)。**止めている最中・終えている最中も受けない** (``departed()`` と同じ関所):
        // 見張りを終える間に名乗ったり畳んだりすると、止める順序を横から割る
        guard let waiting, waiting === child, awaitingPromotion, waiting.isRunning,
            !stopRequested, waiting !== stoppingChild, !isBringingDown(waiting)
        else { return nil }
        // **目録が名乗った子が、待っている世代でなければ受けない** (#2982)。読めない目録・番号を名乗らない
        // 子 (古いライブラリ) は `nil` で、上の「知らせを受けた時点の世代」の照合だけに頼る
        if let pid, pid != waiting.processIdentifier { return nil }
        return await retireAsPromoted()
    }

    /// 乗り換えを待っている、最後に起こした世代。待っていなければ `nil`。
    ///
    /// **窓の知らせを受けた時点で、同期に控える** — 捌くのは `Task` で遅れるので、その間に世代が
    /// 入れ替わっても、知らせが出た世代を ``retireAfterUndeliverable(waiting:)`` が見分けられる。
    var waitingGeneration: Process? { awaitingPromotion ? child : nil }

    /// 乗り換えを待つ世代を、窓へ乗り換えたものとみなして、前の世代を畳む。
    ///
    /// ``retireAfterFallback()`` と ``retireAfterUndeliverable()`` の共通の尾。
    /// ``generationPromoted()`` とは違い、**新しい絵は出ていない**ので記録へは足さない
    /// (``hasSeenPromotion`` も立てない)。
    private func retireAsPromoted(letGo extraLetGo: [Int32] = []) async -> (
        previous: FallbackPrevious, outcome: StopOutcome?
    ) {
        awaitingPromotion = false
        // **測らない。** 道具の窓に新しい絵は出ないので、待っていた数字の行き先は無い
        firstFrameSince = nil
        let hadOutgoing = outgoing != nil
        let retiredPIDs = generationPIDs(of: outgoing)
        let outcome = await retireOutgoing()
        // **畳んだ前の世代を台へ伝える。** 台が畳んだ世代を映しているかもしれない (台は乗り換えを待たせた
        // 世代より先に、前の世代の次の世代へ乗り換えうる)。乗り換えを待っている世代は、これから書くので
        // 含めない (#2983)
        if hadOutgoing || !extraLetGo.isEmpty { relinquishesDisplay(extraLetGo + retiredPIDs) }
        // **畳んだ結果で言う。** 畳めずに置いていく (`abandoned`) ときに、止めたとは言えない
        let previous: FallbackPrevious =
            switch (hadOutgoing, outcome) {
            case (false, _): .none
            case (true, .abandoned?): .left
            case (true, _): .stopped
            }
        return (previous, outcome)
    }

    /// 倒れた子が出たとき、前の世代がどうなったか (``retireAfterFallback()``)。
    enum FallbackPrevious: Equatable {
        /// 前の世代は居なかった (最初の子)。
        case none
        /// 前の世代を畳んだ。
        case stopped
        /// 前の世代を畳めず、置いていく (``StopOutcome/abandoned(pid:)``)。
        case left
    }

    /// 区画 `viewport` の中の、倒れた知らせの目印を掃く ([#2350](https://github.com/mokume-metal/mokume/issues/2350))。
    ///
    /// **古い目印を残さない。** 目印は子の pid が名前で、見た目印は ``retireAfterFallback()`` が消す。
    /// 見ずに残った目印 (道具の知らない世代・見る前に消えた子) があると、あとで同じ pid を巡り当てた
    /// 健全な子が、倒れたと読まれて前の世代を畳まれる。**新しい子を起こす前**と**退役のとき**に掃く。
    ///
    /// - Parameter keeping: 掃かない pid。乗り換えを待っている世代の目印は、まだ見ていないので残す。
    private func sweepFellBackMarkers(keeping pid: Int32?) {
        let facet = WatchCommand.viewportFacet(under: facetBase)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: facet.path) else {
            return
        }
        let kept = pid.map { WorkDirectory.fellBackURL(forProcess: $0, under: facet).lastPathComponent }
        let prefix = WorkDirectory.fellBackURL(forProcess: 0, under: facet).lastPathComponent
            .dropLast()  // `.fell-back.`
        for name in names where name.hasPrefix(prefix) && name != kept {
            try? FileManager.default.removeItem(at: facet.appendingPathComponent(name))
        }
    }

    /// 終われと言われた後に作り直しが通った回の、起こさなかった理由。
    ///
    /// **起こせなかった回と言葉を分ける** (#2521)。どちらも `ok: true, launched: false` で、
    /// 違いは理由にしか出ない。要約 (``BuildReport/summary``) もこの理由を見て言い分ける。
    static var stopRequestedNotice: String { BuildReport.stopRequestedNotice }

    /// 起こさなかった (起こせなかった) 理由を頭に置き、作り直しの出力を後に続ける。
    ///
    /// **理由を先に置き、最初の空行で区切る。** 作り直しの出力は長く、末尾に置いた理由は
    /// 読まれない。理由は空行を含まない (複数行のことはある・`placeUnusable` は 2 行) ので、
    /// 最初の空行までが理由になる (schema の `output` の説明)。**組むのは
    /// ``BuildReport/notStarted(reason:buildOutput:stamp:configuration:timings:)`` だけである。**
    static func notLaunched(_ reason: String, _ buildOutput: String) -> String {
        buildOutput.isEmpty ? reason : reason + "\n\n" + buildOutput
    }

    /// 前の版がまだ走っていて、画面に出ているか。**終われと言われた後は数えない。**
    ///
    /// 起こせなかった回に端末で「前の版のまま待つ」と名乗るかを決める (#2521)。窓のある見張り
    /// (``overlapsGenerations``) は前の世代を退役待ちに残してから起こすので、起こせなくても
    /// 前の版が走り続ける。窓の無い見張りは起こす前に止めるので、走っていない。在るのに
    /// 起こせない成果物の回は、差し替えに入らないので走り続ける。
    var keepsPreviousRunning: Bool {
        !stopRequested && (outgoing ?? child)?.isRunning == true
    }

    /// 「通ったのに建っていない」ことを、記録の中で名乗る。
    ///
    /// **終了コードだけでは区別が付かない。** 作り直しが 0 で終わったのに実行ファイルが
    /// 無い回は、出力に `Build complete!` としか書かれていない — 読み手 (切り分けの口と
    /// 窓口) がそれを見ても、何が起きたのか分からない。
    private func unbuiltNotice(_ rebuilt: RunCommand.Rebuilt) -> String? {
        guard rebuilt.status == 0, rebuilt.executable == nil else { return nil }
        // **この回が探した名前で名乗る。** 見張りは宣言が変わった回に導き直すので、
        // 始めたときの名前を持ち回ると、product を改名した回に**前の名前**で
        // 「建っていない」と言うことになる (#1067)
        guard let product = rebuilt.product else {
            // **読み直して分かった理由があれば、それを名乗る** (#2575)。道具立てが答えなかった回を
            // 「Package.swift を見よ」と言わない
            if let failure = rebuilt.declarationFailure {
                return "\(failure.message)\n\n\(rebuilt.output)"
            }
            return """
                Cannot find anything to run: \(directory.path)
                Check that Package.swift declares an executable in products

                \(rebuilt.output)
                """
        }
        return """
            The build succeeded, but \(product) was never built: \(rebuilt.binPath.path)
            A stale plan left in the build directory can do this — remove that directory
            and try again

            \(rebuilt.output)
            """
    }

    /// - Parameter firstFrameSince: この記録の世代について、新しい絵が出るまでを測るなら
    ///   差し替えを始めた時刻。**渡さなければ待ちを捨てる。**
    @discardableResult
    private func finish(_ report: BuildReport, firstFrameSince: Double? = nil) -> BuildReport {
        self.firstFrameSince = firstFrameSince
        lastReport = report
        write(report)
        return report
    }

    /// 結果を区画へ置く。観測と同じ流儀 (原子的に書く)。
    private func write(_ report: BuildReport) {
        AtomicFile.publishJSON(report, to: BuildReport.statusURL(under: facetBase), "the build record")
    }
}
