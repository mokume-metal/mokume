// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 外とやりとりするファイルの置き場。
///
/// [ADR-0018] 決定 2 のとおり、**基準の解決はここ 1 箇所**にある。既定はプロセスの
/// 作業ディレクトリだが、環境変数 `MOKUME_WORK_DIR` があればそれを基準にする。
///
/// 作業ディレクトリは起動のされ方で変わり (端末から / アプリケーションとして /
/// ログイン項目から)、変わったことは書き込み失敗としてしか現れない。基準を外から
/// 与えられれば、どんな起動のされ方でも道具が場所を指定できる。
///
/// **基準 (``base`` / ``given``) はプロセス起動時に一度だけ評価する。** 走っている間に
/// 基準が動くと、同じ要求がどこへ応答されたのか追えなくなる。一度きりなのは基準だけで、
/// 場所を組み立てる口も、そこに在るかを見る口 (``directoryExists(at:)``) も、呼ばれる
/// たびに今を答える。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
///
/// **main actor には置かない。** 見張りの作り直しは巡回とは別の糸から進むので、
/// そこから辿るものが隔離されていると待ちが main actor へ戻ってしまう
/// ([#1067](https://github.com/mokume-metal/mokume/issues/1067)・ADR-0010 決定 4)。
nonisolated public enum WorkDirectory {
    /// 環境変数の名前。**一覧から取る** — 起動の瞬間に読むものは
    /// ``StartupReads`` が正典で、ここに綴りを書き写さない (#380)。
    static let environmentKey = StartupReads.workDirectory.key

    /// やりとりのファイルを置く親。
    public static let base: URL = resolve(environment: ProcessInfo.processInfo.environment)

    /// 環境変数で**与えられた**基準。与えられていなければ `nil`。
    ///
    /// 道具は自分の既定値 (スケッチのパッケージの場所など) を持っているので、`base` の
    /// 「無ければ作業ディレクトリ」では当てはまらないことがある。**規則はここ 1 箇所に
    /// 置いたまま**、既定値だけを呼ぶ側に選ばせるための口である。
    public static let given: URL? = given(environment: ProcessInfo.processInfo.environment)

    /// `<base>/.mokume`。
    public static var root: URL { root(under: base) }

    /// 与えた基準の下の `.mokume`。
    ///
    /// **基準を外から渡せる形も要る。** 道具は自分の作業ディレクトリではなく、見張って
    /// いるスケッチの側の基準へ置く — 割れると両者は別の区画を見る (#331)。綴りは
    /// ここ 1 箇所に保つ。
    public static func root(under base: URL) -> URL {
        base.appendingPathComponent(".mokume", isDirectory: true)
    }

    /// `<base>/.mokume/<name>`。用途ごとの区画。
    public static func facet(_ name: String) -> URL {
        facet(name, under: base)
    }

    /// 与えた基準の下の区画。
    public static func facet(_ name: String, under base: URL) -> URL {
        root(under: base).appendingPathComponent(name, isDirectory: true)
    }

    /// 区画の中の要求ファイル。
    ///
    /// **綴りはここ 1 箇所。** 書く側 (スケッチ) と読む側 (道具) が別々にリテラルを持つと、
    /// 片方を動かした瞬間に互いが別のファイルを見る — 要求は置かれるのに、応答は永久に
    /// 返らない ([#988](https://github.com/mokume-metal/mokume/issues/988))。
    public static func requestURL(under facet: URL) -> URL {
        facet.appendingPathComponent("request.json")
    }

    /// 区画の中の応答ファイル (``requestURL(under:)`` と同じ理由で、綴りはここ 1 箇所)。
    public static func reportURL(under facet: URL) -> URL {
        facet.appendingPathComponent("report.json")
    }

    /// 区画の中の錠ファイル。区画に応える権利 (``FacetClaim``) を表す。
    ///
    /// **点で始める。** 読み手が区画を覗いたときに要求・応答・絵と並んで目に入らないようにする
    /// ためで、中身は空のまま置かれる。
    nonisolated static func claimURL(under facet: URL) -> URL {
        facet.appendingPathComponent(".claim")
    }

    /// 区画 `viewport` の中の、**共有面へ差し出せずに自分の窓へ倒れた**ことを道具へ知らせる目印
    /// ([#2350](https://github.com/mokume-metal/mokume/issues/2350))。
    ///
    /// 倒れた子が自分の pid で置き、見張りは乗り換えを待っている子の pid の目印を見る。**中身は
    /// 空で、在ることが知らせである** (JSON ではないので `Schemas/` に仕様は無い)。pid を名前に
    /// 持つので、前の世代の目印を新しい世代のものと取り違えず、時計も要らない。点で始めるのは
    /// ``claimURL(under:)`` と同じ理由 (読み手が区画を覗いたときに目録と並んで目に入らない)。
    ///
    /// **綴りはここ 1 箇所。** 置く側 (子) と見る側 (見張り) が別のプロセスで、片方だけ動かすと
    /// 知らせは永久に届かない (``requestURL(under:)`` と同じ理由)。
    package static func fellBackURL(forProcess pid: Int32, under facet: URL) -> URL {
        facet.appendingPathComponent(".fell-back.\(pid)")
    }

    /// 見張りが作り直しの結果を置く区画の名前。**綴りはここ 1 つ** — 書く側 (見張り) と、起動に
    /// 失敗した子が理由を置く側 (``noteStartFailure(_:forProcess:under:)``) が別のプロセスである。
    package static let buildFacetName = "build"

    /// 区画 `build` の中の、**起動できなかった子が自分の理由を置く**ファイル
    /// ([#3169](https://github.com/mokume-metal/mokume/issues/3169))。
    ///
    /// 子が自分の pid で置き、見張りは終わった子の pid のものを読んで消す。**中身は理由の全文 (UTF-8 の
    /// 文字列) で、JSON ではない** (`Schemas/` に仕様は無い・``fellBackURL(forProcess:under:)`` と同じ)。
    /// pid を名前に持つので、前の子の理由を次の子のものと取り違えず、時計も要らない。点で始めるのは
    /// 記録 (`status.json`) と並んで読み手の目に入らないため。
    ///
    /// **子の標準エラーを親が読み解く形は取らない。** 理由は子が自分で渡す。
    package static func startFailureURL(forProcess pid: Int32, under facet: URL) -> URL {
        facet.appendingPathComponent(".start-failure.\(pid)")
    }

    /// 起動できなかった理由 (全文) を、見張りの区画 `build` へ置く。
    ///
    /// **置くのは、見張りに起こされた子だけである。** 見張りの外の実行 (`mokume run`・`render`・手で起こした
    /// 子) が前の見張りの残した区画に置くと、読む者も掃く者も居ないファイルが溜まる。起こし方は
    /// ``SharedFrameSurface/launchOwner`` (`MOKUME_VIEWPORT_OWNER`) が伝える — 見張りは窓の有る無しに
    /// よらず子へ渡す。
    ///
    /// **区画が既に在るときだけ置く。** `build` は見張りが子を起こす前に作るもので、子が作ると、無い場所に
    /// 区画を生やすことになる (区画の有無は他の区画では「効かせる」印である・ADR-0018 決定 2)。
    /// 書けない場所では黙って諦める — 理由は標準エラーに出ている。
    ///
    /// - Parameters:
    ///   - text: 理由の全文。
    ///   - base: 区画の基準。検査から差し替える。
    ///   - owner: 子を起こした窓を持つ道具の名乗り (``SharedFrameSurface/launchOwner``)。**無ければ置かない。** 検査から渡す。
    package static func noteStartFailure(
        _ text: String, forProcess pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        under base: URL = WorkDirectory.base, owner: String?
    ) {
        guard owner != nil else { return }
        let facet = facet(buildFacetName, under: base)
        guard directoryExists(at: facet) else { return }
        try? Data(text.utf8).write(
            to: startFailureURL(forProcess: pid, under: facet), options: .atomic)
    }

    /// 区画 `build` の中の、**まだ最初の絵を出していない子**の印
    /// ([#3222](https://github.com/mokume-metal/mokume/issues/3222))。
    ///
    /// 子が `Sketch.main()` の頭で自分の pid で置き (``markStarting(forProcess:under:owner:)``)、最初の絵を出したら消す。見張りも、読んだ子の印は消す。**中身は空で、在ることが知らせである**
    /// (JSON ではない・``fellBackURL(forProcess:under:)`` と同じ)。見張りは終わった子の印が残っていれば、その子は
    /// 最初の絵を出す前に終わったと読む — 台 (道具の窓) が最初の絵を知らせてくれない、窓の無い見張りと自分の窓に
    /// 倒れた子のための合図である。
    ///
    /// **「出した」ではなく「まだ出していない」を運ぶ。** 道具と別の版のライブラリで組まれた子は印を置かない。
    /// 「出した」を要求すると、そういう子が長く走った後に落ちても「起動できなかった」と言い切ってしまう。
    /// 印を置かない子は今までどおり読まれる。
    ///
    /// **綴りはここ 1 箇所** (置く側の子と見る側の見張りが別のプロセス)。
    package static func startingURL(forProcess pid: Int32, under facet: URL) -> URL {
        facet.appendingPathComponent(".starting.\(pid)")
    }

    /// このプロセスが起動中であることを、見張りの区画 `build` に置く。
    ///
    /// **置くのは、見張りに起こされた子だけで、区画が既に在るときだけである** (``noteStartFailure(_:forProcess:under:owner:)``
    /// と同じ規則)。書けなければ黙って諦める — 印が無い子は今までどおり読まれる。
    ///
    /// - Parameters:
    ///   - base: 区画の基準。検査から差し替える。
    ///   - owner: 子を起こした窓を持つ道具の名乗り (``SharedFrameSurface/launchOwner``)。**無ければ置かない。**
    package static func markStarting(
        forProcess pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        under base: URL = WorkDirectory.base, owner: String?
    ) {
        guard owner != nil else { return }
        let facet = facet(buildFacetName, under: base)
        guard directoryExists(at: facet) else { return }
        _ = FileManager.default.createFile(
            atPath: startingURL(forProcess: pid, under: facet).path, contents: Data())
    }

    /// 最初の絵を出したので、起動中の印を消す。**印が無ければ何もしない。**
    package static func clearStarting(
        forProcess pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        under base: URL = WorkDirectory.base
    ) {
        let url = startingURL(forProcess: pid, under: facet(buildFacetName, under: base))
        try? FileManager.default.removeItem(at: url)
    }

    /// その場所がディレクトリとして在るか。
    ///
    /// **ファイルが在るだけでは真にしない。** 区画は必ずディレクトリなので、同じ名前の
    /// ファイルを「在る」と読むと、要求を置けないまま待ちに入ることになる。
    ///
    /// **いつ呼んでも今を答える。** 区画を見るのは起動の瞬間だけ、という規律
    /// ([#227](https://github.com/mokume-metal/mokume/issues/227)) は呼ぶ側 (`makeIfEnabled`)
    /// が持つ。ここはその規律を知らない。
    ///
    /// **区画に限らない。** 面の仕様の置き場を選ぶ道具もこれを通るので、受けるのは
    /// 「場所」であって区画ではない。
    ///
    /// 1 本にしてあるのは、`ObjCBool` の受け渡しが書き間違えると**常に `false`** になる
    /// 形だからである (`&isDirectory` を渡し忘れる・`.boolValue` を見ない)。区画が在るのに
    /// 「無い」と読むと、観測も入力もつまみも黙って効かなくなり、症状は「触っても応えない」
    /// としか出ない ([#988](https://github.com/mokume-metal/mokume/issues/988))。
    public static func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// `<base>/.mokume/state`。ライブラリが自分の続きを置く場所。
    ///
    /// **区画ではない。** 区画は「利用者が作ったときだけ有効」という switch を持つが
    /// ([ADR-0018] 決定 2)、ここに置くものは既定で効く。両者を同じ入れ物に置くと、
    /// 既定で効くものが区画を作った時点で switch が死ぬ。
    ///
    /// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
    static var state: URL { root.appendingPathComponent("state", isDirectory: true) }

    /// 合わせた値の保存先。
    static var savedParams: URL { state.appendingPathComponent("params.json") }

    /// 与えられた環境から基準を決める (検査から呼べる形)。
    static func resolve(environment: [String: String]) -> URL {
        given(environment: environment)
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    /// 環境変数が与えた基準の解き方の結果。
    package enum Resolution: Equatable {
        /// 基準を与えていない。
        case unset
        /// 絶対パスに解けた。
        case place(URL)
        /// 相対の綴りなのに、基準にする作業ディレクトリが読めない (消えた)。`spelling` は打たれた綴り。
        ///
        /// **相対のまま返さない。** 作業ディレクトリが消えたプロセスでは `currentDirectoryPath` が
        /// 空文字列を返し、そこから作った URL は基準を持たない。そのまま `relativeTo:` に使うと、
        /// 絶対パスにしたはずの基準が相対のまま出る ([#2497](https://github.com/mokume-metal/mokume/issues/2497))。
        case unreadable(spelling: String)
    }

    /// 作業ディレクトリを読む。**読めない (消えた) 回は `nil`。**
    ///
    /// 作業ディレクトリを消したプロセスでは `FileManager.currentDirectoryPath` が空文字列を返す
    /// (実測)。読み取りは検査から差し替えられる形にしてある。
    package static func currentDirectory(
        reading path: () -> String = { FileManager.default.currentDirectoryPath }
    ) -> URL? {
        let text = path()
        return text.isEmpty ? nil : URL(fileURLWithPath: text, isDirectory: true)
    }

    /// 環境変数が与えた基準を、**読めない作業ディレクトリを呼び手へ返す形**で解く。
    ///
    /// 絶対パス (`~` 展開後) は作業ディレクトリに触れず通る。相対パスは `currentDirectory` を
    /// 基準に絶対化し、基準が読めなければ ``Resolution/unreadable(spelling:)`` を返す。
    package static func resolution(
        environment: [String: String], currentDirectory: URL? = currentDirectory()
    ) -> Resolution {
        guard let given = environment[environmentKey], !given.isEmpty else { return .unset }
        let expanded = NSString(string: given).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return .place(URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL)
        }
        guard let currentDirectory else { return .unreadable(spelling: given) }
        return .place(
            URL(fileURLWithPath: expanded, isDirectory: true, relativeTo: currentDirectory)
                .standardizedFileURL)
    }

    /// 与えられた環境が基準を指定しているか (検査から呼べる形)。
    ///
    /// 相対パスと `~` 始まりは、読み取り側の作業ディレクトリを基準に絶対化する。作業ディレクトリが
    /// 読めない回に相対の綴りが来たときは、**断れる口を持たないここでは**従来どおり相対のまま返す
    /// (スケッチの側。断るのは道具の入口で、``resolution(environment:currentDirectory:)`` を読む)。
    public static func given(environment: [String: String]) -> URL? {
        switch resolution(environment: environment) {
        case .unset: return nil
        case .place(let url): return url
        case .unreadable(let spelling):
            let expanded = NSString(string: spelling).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
    }
}
