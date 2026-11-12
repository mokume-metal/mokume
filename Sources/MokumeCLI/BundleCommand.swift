// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import MokumeDiagnostics
import mokume

/// 作品を、作者以外の環境で動く形に束ねる。
///
/// ## どこまで保証するか
///
/// **1 段目 —「自分の別の機械で起動して絵が出るところまで」**。署名は名前を持たない
/// もの (ad-hoc) を当てるだけなので、受け取った側は初回に自分で許可を与えることになる。
/// 名前のある署名と公証は次の段で、実需が立ってから ([ADR-0029] 決定 4)。
///
/// 「配れます」ではなく段で名乗るのは、**期待と実装をずらさない**ためである。
///
/// ## 何を入れるか
///
/// **正典はパッケージが宣言した資材**で、ソースを走査して推測しない。推測は当たって
/// いるうちは楽で、外したときに**黙って欠ける** — 配った先で絵が出ないという形でしか
/// 表に出ない。だから宣言から必要な包みを導き、組み上がりに入っていることを確かめてから
/// 終える。
///
/// [ADR-0029]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0029-post-run-surfaces.md
enum BundleCommand {
    /// 束ねるときの構成。**最適化した側で束ねる** — 配るものを開発中の構成で出すと、
    /// 受け取った側が見るのは本来の速さではない。
    static let configuration = "release"

    /// 宣言が無いときに名乗る下限。ライブラリ自身が要求する版と同じ。
    static let defaultMinimumSystemVersion = "26.0"

    /// 署名に使う名前を外から与える環境変数。
    ///
    /// **証明書の名前は持っている人の環境の性質**であって、束ねるたびに変わる値では
    /// ない。だから引数ではなく環境から受け取る — 区画の基準と同じ形である
    /// ([ADR-0018] 決定 2)。
    ///
    /// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
    static let signIdentityKey = "MOKUME_SIGN_IDENTITY"

    /// 既定の置き場。
    ///
    /// **組み上げた場所 (`.build`) の中には置かない。** 配る前の確かめ方が「組み上げた
    /// 場所を退避して起動する」なので、そこへ置くと確かめる対象ごと退避してしまう。
    /// 配るものは、組み上げの中間物とは寿命が違う。
    static let defaultOutputDirectory = "bundle"

    struct Options {
        var path: String
        var out: String?

        /// スケッチの場所。**走らせた場所から解いた絶対パス** (``GivenPath``) — `dump-package`
        /// と `swift build` の作業ディレクトリへこのまま渡る (#2314)。
        ///
        /// - Parameter base: 走らせた場所。検査から渡せる形にしてある。
        func directory(from base: URL? = GivenPath.currentDirectory) throws(CommandFailure) -> URL {
            try GivenPath.resolve(path, from: base)
        }

        /// 置き場。渡されなければ `nil` (スケッチの下の ``defaultOutputDirectory``)。
        /// **場所と同じく、走らせた場所から解いた絶対パス** (``GivenPath``)。
        ///
        /// - Parameter base: 走らせた場所。検査から渡せる形にしてある。
        func outDirectory(from base: URL? = GivenPath.currentDirectory) throws(CommandFailure) -> URL? {
            guard let out else { return nil }
            return try GivenPath.resolve(out, from: base)
        }
    }

    static func run(_ arguments: [String]) throws(CommandFailure) {
        let options = try parse(arguments)
        let directory = try options.directory()
        // **ビルドの前に解く。** 走らせた場所が読めない回の誤りを、数分のビルドの後で知らせない
        let out =
            try options.outDirectory()
            ?? directory.appendingPathComponent(defaultOutputDirectory, isDirectory: true)
        guard
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Package.swift").path)
        else { throw .packageNotFound(path: directory.path) }

        let identity = try AppIdentity.read(in: directory)
        identity.warnIfExample()
        // **許可の文言も、ビルドの前に見る。** 使うのに無いと、止まるのは配った先になる
        try DeviceUse.check(in: directory, identity: identity)
        // **作り直す先が自分の出力でなければ、ビルドの前に止まる** (#2500)。消せないと分かるのは
        // 数分のビルドの後ではなく、いまでよい。前の回の残りの片付け (退けたまま止まった前の版を戻す) も
        // ここで済ませる — ビルドが通った後だけにすると、コンパイルの誤りで止まる回が続くあいだ、前の版が
        // 隠れたまま残る (#3981)
        _ = try prepare(for: identity, in: out)
        // **紙も同じ約束で、ビルドの前に見る** (#3054)。`.app` が通っても、同じ名前の利用者のファイルが
        // 紙の場所にあれば、書くのはビルドの後になる
        _ = try replaceableNote(for: identity, in: out)

        // **宣言は 1 度だけ読む。** 走らせるものを決めるのにも、下限の版と資材の包みを
        // 知るのにも要る — 別々に引くと `dump-package` を 2 回起こすことになる
        //
        // **道具立てが答えなかった回を、宣言の不備と名乗らない** (#2483)。`dump-package` が 0 以外で
        // 終わると宣言は読めないが、それは `Package.swift` が実行ファイルを宣言していないことでは
        // ない。壊れた宣言そのものを道具立てが読めなかった回も、理由は標準エラーにある
        let reading = try RunCommand.declaration(in: directory)
        if let failure = reading.failure { throw failure }
        let declared = reading.package
        // **束ねる前に見る。** 宣言の抜けはビルドを通るので、後では「組み上がったのに
        // 絵が出ない」形になる — しかも配った先で出る。見るのは読んだ宣言 (#3984)
        try ResourceDeclaration.check(in: directory, declared: declared)
        guard let product = declared?.executableProductName else {
            throw .noExecutable(path: directory.path)
        }
        // **束ねるときは置き場を共有しない** (`BuildDirectory.Fallback.packaging` が理由を
        // 持つ)。共有の置き場には同じ鍵の全スケッチの包みが並ぶので、隣にあるものを
        // 全部入れる下の作りが**他人の資材を配ってしまう**
        let context = BuildContext(
            configuration: configuration, place: .inPackage(.packaging), product: product)
        let executable = try RunCommand.buildAndResolve(in: directory, context: context)

        // **コピーで除くものと入っているべきものは、同じ閉包から 1 度に求める** (#3982)。宣言から消えた
        // target の古い包みも除く — 置き場は利用者の `swift build` / `swift test` と共有なので残る (#4005)
        let scope = declared.map {
            Self.resourceScope(
                of: $0, product: product, executable: executable,
                buildDirectory: context.directory(under: directory))
        }
        let signature = signIdentity(environment: ProcessInfo.processInfo.environment)
        let published = try distribute(
            executable: executable, identity: identity,
            minimumSystemVersion: declared?.minimumMacOSVersion ?? defaultMinimumSystemVersion,
            into: out, excluding: scope?.excluded ?? [], bundles: scope?.required ?? []
        ) { app throws(CommandFailure) in
            try sign(app, as: signature, entitlements: identity.entitlements)
        }
        print(
            report(
                for: published.app, package: directory, note: published.note,
                signedAs: signature, identity: identity))
    }

    /// 組み立て → 仕上げ (資材の検め・紙・署名) → 公開。**公開するまで `--out` の `<name>.app` と紙に
    /// 触れない** ([#3981](https://github.com/mokume-metal/mokume/issues/3981))。
    ///
    /// 前は `<name>.app` を退けてからその場所に組み、署名していたので、コピー・資材の検め・紙・署名の
    /// どこで止まっても、直前に署名を通った前の版はもう無く、残るのは途中の新しい版だった。いまは
    /// `--out` の中の一時の置き場 (``stage(executable:identity:minimumSystemVersion:into:excluding:owner:)``) で
    /// 全部を済ませ、通ったものだけを ``publish(_:identity:into:steps:)`` で入れ替える。止まった回は
    /// 一時の置き場を片付けるだけで、前の版と紙はそのまま残る。代償は、入れ替えるまで新旧 2 版分の
    /// ディスクを使うこと。
    ///
    /// - Parameter signing: 署名の段 (``finish(_:identity:bundles:signing:)`` と同じ)。
    /// - Parameter steps: 公開の手 (検査が失敗を差し込むために外から渡せる形にしてある)。
    /// - Parameter owner: 一時の置き場の名前に入れる持ち主の pid (検査が、落ちたプロセスの残りを作るために
    ///   外から渡せる形にしてある)。
    /// - Returns: 公開した `<name>.app` と紙の場所。
    static func distribute(
        executable: URL, identity: AppIdentity, minimumSystemVersion: String, into out: URL,
        excluding: Set<String>, bundles: [String],
        signing: (URL) throws(CommandFailure) -> Void, steps: PublishSteps = .live,
        owner: pid_t = getpid()
    ) throws(CommandFailure) -> (app: URL, note: URL) {
        let staging = try stage(
            executable: executable, identity: identity,
            minimumSystemVersion: minimumSystemVersion, into: out, excluding: excluding, owner: owner)
        do {
            _ = try finish(staging.app, identity: identity, bundles: bundles, signing: signing)
            let app = try publish(staging, identity: identity, into: out, steps: steps)
            return (app, out.appendingPathComponent(noteFileName(for: identity)))
        } catch {
            discard(staging)
            throw error
        }
    }

    /// 組み上がった包みの仕上げ。**手順の順序をここ 1 か所で持つ** — 資材の検め → 開き方の紙 → 署名。
    ///
    /// **紙は署名の前に書く** ([#2773](https://github.com/mokume-metal/mokume/issues/2773))。
    /// 紙は `.app` の隣にあって署名の対象ではないので、先に書いても代償は無い。逆にすると、
    /// 紙が書けない理由 (行き先が同じ名前のディレクトリ・書けない置き場など) で止まる回に、
    /// 署名済みの (`codesign --verify` が通る) `.app` が残る。先に書けば、そうした回は署名の段に
    /// 進む前に同じ失敗で終わる。組み立て途中の `.app` を消す約束は、資材の欠けで止まる回と同じく
    /// ここでも作らない。
    ///
    /// - Parameters:
    ///   - bundles: 宣言された資材の包み。
    ///   - signing: 署名の段。**検査が、ビルドも `codesign` も起こさずに順序を見るために外から渡せる形にしてある。**
    /// - Returns: 書いた紙の場所。
    static func finish(
        _ app: URL, identity: AppIdentity, bundles: [String],
        signing: (URL) throws(CommandFailure) -> Void
    ) throws(CommandFailure) -> URL {
        try check(app, contains: bundles)
        let note = try writeOpeningNote(for: identity, beside: app)
        try signing(app)
        return note
    }

    // MARK: - 引数

    /// 選択肢の宣言。``Command/valueOptions`` が `doctor` に同じ宣言を渡す。
    static var options: [Arguments.Option] {
        [
            Arguments.Option(["--out"], takesPlace: true) {
                "\($0) needs a directory"
            }
        ]
    }

    /// 引数を解く。骨格は ``Arguments`` が持ち、ここは宣言だけを書く。
    static func parse(_ arguments: [String]) throws(CommandFailure) -> Options {
        let parsed = try Arguments.parse(
            arguments, options: options,
            positionalIsPlace: true,
            surplus: .reject { "Only one directory: \($0)" })
        return Options(
            path: parsed.positional ?? ".",
            out: parsed.values["--out"])
    }

    // MARK: - 組み立て

    /// 包みを組んで、そのまま公開する (署名も紙も無い)。``distribute(executable:identity:minimumSystemVersion:into:excluding:bundles:signing:steps:owner:)``
    /// から仕上げを抜いた形で、組み立てと公開の約束を検査から見るための口。
    ///
    /// **作り直しは入れ替えで。** 中身は毎回まっさらな一時の置き場で組むので、前の版の資材は
    /// 混ざらない — 混ざると、消したはずのものが配られ、しかも手元では動くので気付けない。
    ///
    /// **消してよいのは、`--out` の直下にある、前の版の自分の `.app` だけである** (#2309・#2500)。
    /// 場所は ``replaceableApp(for:in:)`` が、中身は ``isOwnOutput(_:identity:)`` が確かめ、
    /// どちらかが外れたら何も消さずに投げる。
    ///
    /// - Parameter excluding: 入れない包みの名前 (``SwiftPM/Package/ResourceScope/excluded``)。
    static func assemble(
        executable: URL, identity: AppIdentity, minimumSystemVersion: String, into out: URL,
        excluding: Set<String>
    ) throws(CommandFailure) -> URL {
        let staging = try stage(
            executable: executable, identity: identity,
            minimumSystemVersion: minimumSystemVersion, into: out, excluding: excluding)
        do {
            return try publish(staging, identity: identity, into: out)
        } catch {
            discard(staging)
            throw error
        }
    }

    /// 組み立ての一時の置き場。`--out` の直下の `.mokume-bundle-<作品の印>-<機械の印>-<pid>-<乱数>/` で、中に `<name>.app` と
    /// (仕上げの後は) 紙を持つ。**`--out` の中に置くのは、公開を同じボリュームの中の rename で済ませる
    /// ため** (別のボリュームからは 1 手で入れ替えられない)。
    ///
    /// 公開の間だけ、同じ名前に `.app`・`.previous` を足した兄弟 (``incoming``・``previous``) を `--out` の
    /// 直下に使う。**前の `<name>.app` は `--out` の外 (親の違う場所) へ動かさない** — 親の違う場所へ
    /// ディレクトリを rename するには、そのディレクトリ自身の書き込み権が要るので、最上位に書き込み権の無い
    /// 前の `.app` (`chmod a-w`・`sudo` で束ねたもの) を入れ替えられなくなる。兄弟どうしの rename なら
    /// `--out` の書き込み権だけで済む。
    ///
    /// **名前に作品名そのものは入れない。** 名前は上限 (``AppIdentity/maximumNameLength``) まで使えるので、
    /// 前後に足すとファイル名の上限を越える。代わりに作品名の短い印 (``remnantMark(for:)``) を入れ、
    /// 次の回が自分の作品の残りだけを片付けられるようにする。**pid を入れる**のは、同じ `--out` へ同時に
    /// 走る別の `mokume bundle` の作業中の置き場を、片付けで消さないため (``AtomicFile`` と同じ作法)。
    struct Staging {
        /// 一時の置き場そのもの。
        let directory: URL
        /// 中で組む `<name>.app`。
        let app: URL

        /// 入れ替えの相手。置き場で仕上がった新しい版を、`--out` の直下のこの名前へ先に動かしてから、
        /// 兄弟どうしで `<name>.app` と入れ替える。入れ替えた後は前の版が入る。
        var incoming: URL {
            directory.deletingLastPathComponent()
                .appendingPathComponent(directory.lastPathComponent + incomingSuffix, isDirectory: true)
        }

        /// 入れ替えを持たないボリュームで、前の版を退けておく `--out` の直下の名前。
        var previous: URL {
            directory.deletingLastPathComponent()
                .appendingPathComponent(directory.lastPathComponent + previousSuffix, isDirectory: true)
        }
    }

    /// 片付けの前の確かめ。**ビルドの前の `run` と組み立ての前の ``stage(executable:identity:minimumSystemVersion:into:excluding:owner:)``
    /// が同じものを通す。** 作り直せない相手なら何も片付けずに止まり、通れば前の回の残り
    /// (``sweepRemnants(in:identity:)``。退けたまま止まった前の版は元の場所へ戻す) を片付けて、もう一度
    /// 確かめる。
    @discardableResult
    static func prepare(for identity: AppIdentity, in out: URL) throws(CommandFailure) -> URL {
        _ = try replaceableApp(for: identity, in: out)
        sweepRemnants(in: out, identity: identity)
        return try replaceableApp(for: identity, in: out)
    }

    /// 一時の置き場で包みを組む。`--out` の `<name>.app` と紙には触れない。
    ///
    /// **ビルドの前と同じ確かめと片付けを先に通す** (``prepare(for:in:)``)。作り直せない相手なら、組む前に
    /// 止まる。途中で失敗したら、作った一時の置き場を片付けて投げる。
    ///
    /// - Parameter owner: 置き場の名前に入れる持ち主の pid (``distribute(executable:identity:minimumSystemVersion:into:excluding:bundles:signing:steps:owner:)``)。
    static func stage(
        executable: URL, identity: AppIdentity, minimumSystemVersion: String, into out: URL,
        excluding: Set<String>, owner: pid_t = getpid()
    ) throws(CommandFailure) -> Staging {
        let target = try prepare(for: identity, in: out)
        let directory = out.appendingPathComponent(
            stagingName(for: identity, owner: owner), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            // 置き場を作れないのは、`<name>.app` を書けないのと同じ事情 (`--out` を書けない・無いなど)
            throw .cannotCreate(path: target.path, reason: Diagnostics.failureText(error))
        }
        let staging = Staging(
            directory: directory,
            app: directory.appendingPathComponent(target.lastPathComponent, isDirectory: true))
        do {
            try build(
                staging.app, executable: executable, identity: identity,
                minimumSystemVersion: minimumSystemVersion, excluding: excluding)
        } catch {
            discard(staging)
            throw error
        }
        return staging
    }

    /// 止まった回の一時の置き場を片付ける。消し損ねても投げない (次の回に ``sweepRemnants(in:identity:)`` が
    /// 片付ける)。
    ///
    /// 片付けるのは置き場と ``Staging/incoming`` (公開が投げた回は、まだ入れ替えていない新しい版が入る) だけで、
    /// **``Staging/previous`` には触れない** — そこに残るのは、入れ替えを持たないボリュームで退けた前の版を
    /// 戻せなかった回で、それが前の版の唯一の写しである。
    static func discard(_ staging: Staging) {
        try? FileManager.default.removeItem(at: staging.incoming)
        try? FileManager.default.removeItem(at: staging.directory)
    }

    /// `app` の場所に、包みの中身を組む。
    private static func build(
        _ app: URL, executable: URL, identity: AppIdentity, minimumSystemVersion: String,
        excluding: Set<String>
    ) throws(CommandFailure) {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let programs = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try create(programs)
        try create(resources)

        // **`Info.plist` を先に書く。** 印 (``AppIdentity/bundledMarkKey``) が入っているので、途中の
        // `.app` が何かの拍子に `--out` へ出ても、次の回に自分の出力と確かめられて作り直せる
        let plist = identity.infoPlist(
            executable: executable.lastPathComponent,
            minimumSystemVersion: minimumSystemVersion)
        guard
            let data = try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
        else {
            throw .cannotCreate(path: contents.appendingPathComponent("Info.plist").path,
                reason: "could not write the identity")
        }
        do {
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        } catch {
            throw .cannotCreate(
                path: contents.appendingPathComponent("Info.plist").path,
                reason: Diagnostics.failureText(error))
        }

        try copy(executable, to: programs.appendingPathComponent(executable.lastPathComponent))
        for bundle in resourceBundles(besides: executable, excluding: excluding) {
            try copy(bundle, to: resources.appendingPathComponent(bundle.lastPathComponent))
        }
    }

    /// 作る `<name>.app` の場所。**消してよいと確かめられたときだけ返し、そうでなければ何も消さずに
    /// 投げる** (``assemble(executable:identity:minimumSystemVersion:into:)`` とビルドの前の `run`
    /// が同じ判定を使う)。
    ///
    /// 確かめることは 2 つ。**場所**: 最後の部品が名前そのもので (`a/../b` は `b.app` に畳まれる
    /// ので外れる)、親が `--out` であること。名前の `/` は名乗りを読む段
    /// (``AppIdentity/make(from:path:)``) が断るが、ここはそれに頼らない — 名乗りを通らずに組んだ
    /// `AppIdentity` でも `--out` の外を消さない ([#2309](https://github.com/mokume-metal/mokume/issues/2309))。
    /// **中身**: そこに既に在るものが、mokume の出力と確かめられること
    /// (``isOwnOutput(_:identity:)``)。何も無ければ消すものも無い。
    static func replaceableApp(for identity: AppIdentity, in out: URL) throws(CommandFailure) -> URL {
        let fileName = "\(identity.name).app"
        let app = out.appendingPathComponent(fileName, isDirectory: true)
        guard app.lastPathComponent == fileName,
            app.deletingLastPathComponent().standardizedFileURL.path
                == out.standardizedFileURL.path
        else {
            throw .cannotCreate(
                path: app.path,
                reason: "It would not sit directly inside \(out.path), so nothing was removed"
                    + " or written. The name must not contain \"/\"")
        }
        // 何も無ければ消すものも無い。**シンボリックリンクは在るものとして数える** (壊れたものも)
        guard kind(of: app) != nil else { return app }
        guard isOwnOutput(app, identity: identity) else {
            throw .cannotCreate(
                path: app.path,
                reason: "It could not be confirmed as something mokume bundled, so nothing was"
                    + " removed or written. If you do not need it, remove it by hand and run this again")
        }
        return app
    }

    /// 作る開き方の紙 `How to open <name>.txt` の場所。**上書きしてよいと確かめられたときだけ返し、
    /// そうでなければ何も書かずに投げる** (#3054。``replaceableApp(for:in:)`` と同じ約束を紙へ広げる。
    /// ビルドの前の `run` と、紙を書く直前の ``writeOpeningNote(for:beside:)`` が同じ判定を使う)。
    ///
    /// 場所の確かめは `.app` と同じ (最後の部品が名前そのもので、親が `--out`)。**中身**: そこに既に
    /// 在るものが、前の版の mokume が書いた紙と確かめられること (``isOwnNote(_:identity:)``)。
    /// 何も無ければ上書きするものも無い。**シンボリックリンクは在るものとして数える** (壊れたものも)。
    static func replaceableNote(for identity: AppIdentity, in out: URL) throws(CommandFailure) -> URL {
        let fileName = noteFileName(for: identity)
        let note = out.appendingPathComponent(fileName)
        guard note.lastPathComponent == fileName,
            note.deletingLastPathComponent().standardizedFileURL.path
                == out.standardizedFileURL.path
        else {
            throw .cannotCreate(
                path: note.path,
                reason: "It would not sit directly inside \(out.path), so nothing was removed"
                    + " or written. The name must not contain \"/\"")
        }
        guard kind(of: note) != nil else { return note }
        guard isOwnNote(note, identity: identity) else {
            throw .cannotCreate(
                path: note.path,
                reason: "It could not be confirmed as a note mokume wrote, so nothing was"
                    + " removed or written. If you do not need it, remove it by hand and run this again")
        }
        return note
    }

    /// 開き方の紙を読んでよい大きさの上限 (バイト)。mokume が書く紙は数百バイトに名前が数回入るだけ
    /// なので、確かめるために読む前に、この大きさで断る (``infoPlistReadLimit`` と同じ考え方)。
    static let openingNoteReadLimit = 65_536

    /// 既にある紙が、前の版の mokume が書いたものと確かめられるか。
    ///
    /// **印は先頭の行 `How to open <name>`** (``openingNote(for:)`` が書く決まった文)。形は、普通の
    /// ファイルで ``openingNoteReadLimit`` 以下であること。**シンボリックリンクは、生きていても壊れていても
    /// 確かめられない側に倒す** — 読んで「自分のもの」と判定すると、利用者が張ったリンクを普通の
    /// ファイルに置き換えてしまう。形が外れるものは読まずに断る。
    ///
    /// **印は「先頭の行」を行として割らずに、本文の頭が印と、その後ろの改行 (か本文の終わり) で
    /// 続くかで見る。** 名前には改行が入りうる (`AppIdentity.make` は途中の `\n` を通す) ので、行で
    /// 割ると自分の紙を 2 回目から断ってしまう。印の中の改行の数は名前が持つので、数えずに頭から比べる。
    /// 次の 3 つは自分の紙として受ける (どれも mokume が書いたあとで、人かエディタが触っただけの形):
    /// - **名前の大文字小文字の違い** (`Grain` → `grain`)。APFS の既定は大文字小文字を区別せず、
    ///   同じファイルに当たる。`How to open ` の部分は完全一致のまま
    /// - **UTF-8 の BOM 1 つ** が頭に付いたもの
    /// - **CRLF** に変換されたもの (印の中の改行も、後ろの区切りも)
    static func isOwnNote(_ note: URL, identity: AppIdentity) -> Bool {
        guard kind(of: note) == .typeRegular,
            let attributes = try? FileManager.default.attributesOfItem(atPath: note.path),
            let size = (attributes[.size] as? NSNumber)?.intValue, size <= openingNoteReadLimit,
            let data = try? Data(contentsOf: note),
            // `String(data:encoding:)` は頭の BOM を黙って落とすので使わない (読み飛ばすのは下で 1 つだけ)
            let raw = String(validating: data, as: UTF8.self)
        else { return false }
        let unified = { (text: String) -> [Unicode.Scalar] in
            Array(text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars)
        }
        var body = unified(raw)
        if body.first == "\u{FEFF}" { body.removeFirst() }
        let lead = Array(openingNoteLead.unicodeScalars)
        let name = unified(identity.name)
        guard body.count >= lead.count + name.count, Array(body[..<lead.count]) == lead else {
            return false
        }
        let given = String(String.UnicodeScalarView(body[lead.count..<(lead.count + name.count)]))
        guard given.compare(String(String.UnicodeScalarView(name)), options: .caseInsensitive)
            == .orderedSame
        else { return false }
        let rest = body[(lead.count + name.count)...]
        return rest.isEmpty || rest.first == "\n"
    }

    /// 紙の先頭の行の、名前より前の部分。大文字小文字を区別して比べる。
    private static let openingNoteLead = "How to open "

    /// 紙の先頭の行。紙の印であり、``openingNote(for:)`` の書き出しでもある (1 か所で持つ)。
    static func openingNoteMark(for identity: AppIdentity) -> String {
        "\(openingNoteLead)\(identity.name)"
    }

    /// `Info.plist` を読んでよい大きさの上限 (バイト)。他人の `.app` の中を、確かめるために読むので、
    /// 読む前に大きさで断る (普通の `Info.plist` は数 KB)。
    static let infoPlistReadLimit = 1_048_576

    /// 既にある `<name>.app` が、前の版の自分の出力と確かめられるか。
    ///
    /// **まず形を見る。** `<name>.app`・`Contents` は実体のディレクトリ、`Contents/Info.plist` は普通の
    /// ファイルで ``infoPlistReadLimit`` 以下であること。**シンボリックリンクは、生きていても壊れていても
    /// 確かめられない側に倒す** — リンクの先の `Info.plist` を読んで「自分のもの」と判定すると、利用者が
    /// 張った別の場所の `.app` へのリンクを外してしまう (#2500)。形が外れるものは読まずに断る。
    ///
    /// **形が合えば `Info.plist` を読んで、2 つのどちらかを見る。** 1 つ目は mokume だけが書く印
    /// (``AppIdentity/bundledMarkKey``) で、識別子を変えた作り直しもこれで通る。2 つ目は
    /// この変更より前に束ねたもの (印が無い) のための、`CFBundleIdentifier` が今の名乗りと同じこと。
    /// どちらでもなければ消さない。
    ///
    /// **印が示すのは「mokume の出力」までである。** 別の作品が同じ `--out` に同じ名前で束ねた
    /// `.app` も作り直しの対象になる (名前の衝突として受け入れる)。
    static func isOwnOutput(_ app: URL, identity: AppIdentity) -> Bool {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let info = contents.appendingPathComponent("Info.plist")
        guard kind(of: app) == .typeDirectory, kind(of: contents) == .typeDirectory,
            kind(of: info) == .typeRegular,
            let attributes = try? FileManager.default.attributesOfItem(atPath: info.path),
            let size = (attributes[.size] as? NSNumber)?.intValue, size <= infoPlistReadLimit,
            let data = try? Data(contentsOf: info),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else { return false }
        if plist[AppIdentity.bundledMarkKey] as? Bool == true { return true }
        return plist["CFBundleIdentifier"] as? String == identity.identifier
    }

    /// `url` 自身の種類。**リンクは辿らない** (`lstat`)。無ければ `nil`。
    private static func kind(of url: URL) -> FileAttributeType? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.type] as? FileAttributeType
    }

    // MARK: - 前の出力を退ける

    /// 一時の置き場の名前の頭 (`.mokume-bundle-<作品の印>-<機械の印>-<pid>-<乱数>`)。
    static let stagingPrefix = ".mokume-bundle-"

    /// 入れ替えの相手 (``Staging/incoming``) の名前の尻。
    static let incomingSuffix = ".app"

    /// 入れ替えを持たないボリュームで前の版を退けておく場所 (``Staging/previous``) の名前の尻。
    static let previousSuffix = ".previous"

    /// 置き場の名前に入れる、作品名の短い印 (名前の UTF-8 の SHA-256 の頭 4 バイトを 16 進で)。作品名
    /// そのものを入れるとファイル名の上限を越えうるので、プロセスをまたいで同じになる短い印で代える。
    /// 同じ `--out` の別の作品と印が重なる見込みは 2^-32 で、重なっても置き場そのものは中身
    /// (``isOwnRemnant(_:name:)``) も見る。
    static func remnantMark(for identity: AppIdentity) -> String {
        SHA256.hash(data: Data(identity.name.utf8)).prefix(4)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// この機械の短い印。**pid の生死はその機械の中でしか引けない** — 共有ボリューム (SMB・NFS) の `--out` には
    /// 別の機械の `mokume bundle` の作業中の置き場が並びうるので、片付けは自分の機械の印を持つものだけを見る。
    ///
    /// 元はホスト名ではなく機械の UUID (`gethostuuid`)。macOS のホスト名はつなぐネットワークで変わりうるので、
    /// 変わると自分の残り (戻すべき前の版も) を別の機械のものとみなして放っておくことになる。UUID を
    /// 引けなければホスト名に倒す。
    static let machineMark: String = {
        var raw = [UInt8](repeating: 0, count: 16)
        var wait = timespec(tv_sec: 0, tv_nsec: 0)
        let source: Data
        if gethostuuid(&raw, &wait) == 0 {
            source = Data(raw)
        } else {
            source = Data(ProcessInfo.processInfo.hostName.utf8)
        }
        return SHA256.hash(data: source).prefix(4).map { String(format: "%02x", $0) }.joined()
    }()

    /// 一時の置き場の名前 (`.mokume-bundle-<作品の印>-<機械の印>-<pid>-<乱数>`)。
    ///
    /// **短く保つ。** 置き場の中の `<name>.app/Contents/…` は `--out` の直下より置き場の名前の分だけ深く、
    /// 長い名前 (上限まで使った多バイトの名前) ではパス長の上限 (1024 バイト) に近い。印はどれも 8 桁の
    /// 16 進で、同じプロセスの中の置き場は乱数の 8 桁で分ける。
    static func stagingName(
        for identity: AppIdentity, owner: pid_t, machine: String = machineMark,
        id: UInt32 = .random(in: .min ... .max)
    ) -> String {
        "\(stagingPrefix)\(remnantMark(for: identity))-\(machine)-\(owner)-\(hex(id))"
    }

    /// 8 桁の 16 進 (小文字)。
    private static func hex(_ value: UInt32) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 8 - digits.count) + digits
    }

    /// 印の形 (8 桁の小文字の 16 進) か。
    private static func isMark(_ text: Substring) -> Bool {
        text.count == 8 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// 残りの役。
    enum RemnantRole {
        /// 組み立ての置き場 (``Staging/directory``)。
        case staging
        /// 入れ替えの相手 (``Staging/incoming``)。
        case incoming
        /// 退けた前の版 (``Staging/previous``)。
        case previous
    }

    /// 名前が、**この作品の**一時の置き場 (か、その兄弟) の形なら、役と持ち主 (機械の印と pid)。形が外れれば `nil`。
    static func remnant(_ fileName: String, identity: AppIdentity)
        -> (role: RemnantRole, machine: String, owner: pid_t)?
    {
        let head = "\(stagingPrefix)\(remnantMark(for: identity))-"
        guard fileName.hasPrefix(head) else { return nil }
        var rest = Substring(fileName.dropFirst(head.count))
        var role = RemnantRole.staging
        if rest.hasSuffix(incomingSuffix) {
            role = .incoming
            rest = rest.dropLast(incomingSuffix.count)
        } else if rest.hasSuffix(previousSuffix) {
            role = .previous
            rest = rest.dropLast(previousSuffix.count)
        }
        let parts = rest.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, isMark(parts[0]),
            !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
            let owner = pid_t(parts[1]), owner > 0, isMark(parts[2])
        else { return nil }
        return (role, String(parts[0]), owner)
    }

    /// 前の版が前の出力を消すのに使っていた一時の名前の形 (`.<name>.app.removing-<UUID>`)。
    /// 残っていれば片付ける対象として読むだけで、もう作らない。
    private static func retiringPrefix(_ name: String) -> String { ".\(name).app.removing-" }

    /// 前の版が残した、前の出力を消し損ねた一時の名前か。**消してよいのは、この名前のこの形のものだけ**
    /// (`<UUID>` が UUID として読めるもの)。ほかの `.` から始まるものや、ほかの作品の一時の名前には触れない。
    static func isRetiredRemnant(_ fileName: String, name: String) -> Bool {
        let prefix = retiringPrefix(name)
        return fileName.hasPrefix(prefix)
            && UUID(uuidString: String(fileName.dropFirst(prefix.count))) != nil
    }

    /// 残った一時の置き場 (か、その兄弟) のうち、**この作品のもの**か。片付けてよいのはこれだけ
    /// (#2500・#3054 の持ち主の確かめと同じ考え方)。持ち主の生死は見ない (``sweepRemnants(in:identity:me:)`` が見る)。
    ///
    /// 名前が ``remnant(_:identity:)`` の形 (作品名の印が合い、機械の印・pid・乱数が読める) の実体のディレクトリで
    /// あること。置き場そのものは、中身が空か、`<name>.app`・`How to open <name>.txt` だけであることも見る。
    /// 別の作品が同じ `--out` に残したものは、印が違うので触れない。リンクは辿らずに断る。
    static func isOwnRemnant(_ url: URL, name identity: AppIdentity) -> Bool {
        guard let remnant = remnant(url.lastPathComponent, identity: identity),
            kind(of: url) == .typeDirectory
        else { return false }
        guard remnant.role == .staging else { return true }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return false
        }
        return Set(entries).isSubset(of: ["\(identity.name).app", noteFileName(for: identity)])
    }

    /// 前の回に止められて残った一時の置き場を片付ける。
    ///
    /// **持ち主のプロセスがもう居ないと言い切れるものだけ** (``AtomicFile/isRunning(_:)``。確かめられなければ
    /// 居ることにする。pid が使い回されていれば、そのプロセスが終わるまで残す — ``AtomicFile`` の先例どおり)。
    /// 同じ `--out` へ同時に走っている別の `mokume bundle` の作業中のものには触れない。自分の pid のものも
    /// 片付けない。**別の機械の印 (``machineMark``) を持つものは、生死を引けないので生きているとみなす**
    /// (共有ボリュームの `--out`)。
    ///
    /// **先に、退けたまま止まった前の版を戻す。** 入れ替えを持たないボリュームでは前の版を ``Staging/previous``
    /// へ退けてから新しい版を置く (2 手) ので、その間に止められると `<name>.app` が無い。`<name>.app` が無く、
    /// 前の版が残っていれば、元の場所へ戻す (戻せなければ残す)。`<name>.app` が在れば、退けた前の版と入れ替えの
    /// 相手はもう要らない。前の版が残した `.removing-` の形も片付ける。
    static func sweepRemnants(in out: URL, identity: AppIdentity, me: pid_t = getpid()) {
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        let app = out.appendingPathComponent("\(identity.name).app", isDirectory: true)
        var found: [(url: URL, role: RemnantRole)] = []
        for entry in listing {
            let url = out.appendingPathComponent(entry, isDirectory: true)
            if isRetiredRemnant(entry, name: identity.name) {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            guard let remnant = remnant(entry, identity: identity), remnant.machine == machineMark,
                remnant.owner != me, !AtomicFile.isRunning(remnant.owner),
                isOwnRemnant(url, name: identity)
            else { continue }
            found.append((url, remnant.role))
        }
        for (url, role) in found where role == .previous {
            if kind(of: app) == nil {
                try? place(url, at: app, steps: .live)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        for (url, role) in found where role != .previous {
            // 入れ替えの相手は、`<name>.app` が在るときだけ消す。無ければ残すだけで、`<name>.app` へは戻さない
            // (中身が前の版か、検めを通った新しい版かを名前で見分けられない)。次に `<name>.app` が置かれた回に片付く
            if role == .incoming, kind(of: app) == nil { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 公開

    /// 公開の手。どれも同じボリュームの中の 1 手 (rename か片付け) で、途中の姿が外から見えない。
    /// **公開の副作用は全部ここを通す** — 検査が、手の前後で失敗や中断を差し込むために外から渡せる形に
    /// してあり、ここを通らない手は差し込みから漏れる。
    struct PublishSteps {
        /// 素の `rename(2)`。紙を置く (在る普通のファイルは置き換える) のと、`RENAME_EXCL` を持たない
        /// ボリュームでの倒し先 (``place(_:at:steps:)``) に使う。
        var replace: (_ from: URL, _ to: URL) throws -> Void
        /// 2 つの場所を入れ替える (`renamex_np` の `RENAME_SWAP`)。
        var swap: (_ from: URL, _ to: URL) throws -> Void
        /// 動かす。**行き先に在れば断る** (`RENAME_EXCL`)。
        var move: (_ from: URL, _ to: URL) throws -> Void
        /// 片付ける (一時の置き場・退けた前の版・初回に置けなかったときの紙)。消し損ねても投げない。
        var remove: (_ url: URL) -> Void

        static var live: PublishSteps {
            PublishSteps(
                replace: { from, to in try rename(from, to, flags: 0) },
                swap: { from, to in try rename(from, to, flags: UInt32(RENAME_SWAP)) },
                move: { from, to in try rename(from, to, flags: UInt32(RENAME_EXCL)) },
                remove: { url in try? FileManager.default.removeItem(at: url) })
        }

        private static func rename(_ from: URL, _ to: URL, flags: UInt32) throws {
            guard renamex_np(from.path, to.path, flags) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
    }

    /// そのボリュームが `renamex_np` の旗 (`RENAME_SWAP`・`RENAME_EXCL`) を持たないと言った失敗か。
    private static func isUnsupported(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == NSPOSIXErrorDomain
            && [Int(ENOTSUP), Int(EINVAL), Int(EOPNOTSUPP)].contains(error.code)
    }

    /// 一時の置き場で仕上がった `.app` と紙を、`--out` へ出す ([#3981](https://github.com/mokume-metal/mokume/issues/3981))。
    ///
    /// **どの手の間で止まっても (失敗・Ctrl-C・kill)、`--out` には前の版か新しい版のどちらかが紙と揃って
    /// 残る。** 手は順に:
    /// 1. **紙を置く** (1 手の rename)。紙の中身は名前だけで決まる (``openingNote(for:)``) ので、同じ名前の
    ///    前の版の紙と同じ文である。ここで止まっても、前の `.app` と (同じ文の) 紙が揃っている
    /// 2. **前の版が無ければ、`.app` を置く** (在れば断る)。置けなければ、1 で前に無かった場所へ置いた紙を
    ///    片付けて投げる (紙だけを残さない。前から在った紙には触れない)
    /// 3. **前の版が在れば、新しい版を `--out` の直下の兄弟 (``Staging/incoming``) へ動かしてから、
    ///    `RENAME_SWAP` で `<name>.app` と 1 手に入れ替える。** 退けてから置く 2 手にすると、その間に
    ///    `<name>.app` が無い瞬間ができる。**前の版は `--out` の外へ動かさない** (``Staging`` に理由)
    /// 4. **片付ける** (入れ替えの相手には前の版が入っている)。消し損ねても投げず、次の回に片付ける
    ///
    /// **入れ替えを持たないボリューム** (`RENAME_SWAP` が `ENOTSUP`・`EINVAL` で断られる。APFS・HFS+ 以外の
    /// 一部) では、前の版を ``Staging/previous`` へ退けてから新しい版を置く 2 手に倒す
    /// (``replaceInTwoSteps(_:app:steps:)``)。**2 手の間で強制終了されたときだけ `<name>.app` が無い瞬間が
    /// 残る** が、前の版は ``Staging/previous`` に揃って残り、次の回がビルドの前に元の場所へ戻す
    /// (``sweepRemnants(in:identity:me:)``)。`RENAME_EXCL` も断られれば、在るかを確かめてからの素の rename に
    /// 倒す (``place(_:at:steps:)``)。
    ///
    /// 置く前に、ビルドの前と同じ確かめ (``replaceableApp(for:in:)``・``replaceableNote(for:in:)``) を
    /// もう一度通す。ビルドの間に置き換わった相手を、確かめずに入れ替えない (#2500・#3054)。
    static func publish(
        _ staging: Staging, identity: AppIdentity, into out: URL, steps: PublishSteps = .live
    ) throws(CommandFailure) -> URL {
        let app = try replaceableApp(for: identity, in: out)
        let replacing = kind(of: app) != nil
        let stagedNote = staging.directory.appendingPathComponent(noteFileName(for: identity))
        // 1 で、前に何も無かった場所へ置いた紙 (初回に `.app` を置けなければ片付ける)
        var placedNote: URL?
        // 1 で置いた紙
        var publishedNote: URL?
        if kind(of: stagedNote) != nil {
            let note = try replaceableNote(for: identity, in: out)
            let existed = kind(of: note) != nil
            do {
                try steps.replace(stagedNote, note)
            } catch {
                throw .cannotCreate(path: note.path, reason: Diagnostics.failureText(error))
            }
            publishedNote = note
            if !existed { placedNote = note }
        }
        do {
            if !replacing {
                try place(staging.app, at: app, steps: steps)
            } else {
                try place(staging.app, at: staging.incoming, steps: steps)
                do {
                    try steps.swap(staging.incoming, app)
                } catch where isUnsupported(error) {
                    try replaceInTwoSteps(staging, app: app, steps: steps)
                }
            }
        } catch {
            // **`<name>.app` がいまも無いときだけ。** 同時に走った別の初回の公開が先に `.app` を置いていれば、
            // この紙はその隣の紙 (中身は同じ文) になっている
            if !replacing, let placedNote, kind(of: app) == nil { steps.remove(placedNote) }
            if let failure = error as? CommandFailure { throw failure }
            throw .cannotCreate(path: app.path, reason: Diagnostics.failureText(error))
        }
        // **綴りを頼んだ名前に揃える。** 大文字小文字を区別しないボリュームで名前の大文字小文字だけを変えて
        // 束ね直すと (`Grain` → `grain`)、入れ替えは中身だけを替え、名前は前の綴り (`Grain.app`) のまま残る
        respell(app, steps: steps)
        if let publishedNote { respell(publishedNote, steps: steps) }
        for leftover in [staging.incoming, staging.previous] where kind(of: leftover) != nil {
            steps.remove(leftover)
        }
        steps.remove(staging.directory)
        return app
    }

    /// 入れ替えを持たないボリュームでの倒し先。前の版を ``Staging/previous`` (`--out` の直下の兄弟) へ
    /// 退けてから、``Staging/incoming`` の新しい版を置き、置けなければ前の版を戻す。
    ///
    /// **戻すのにも失敗したら、前の版の在処を名乗って投げる。** 前の版は ``Staging/previous`` に残り、
    /// 呼び元の片付け (``discard(_:)``) はそこに触れない。次の回は組み立ての前に元の場所へ戻す
    /// (``sweepRemnants(in:identity:me:)``)。
    private static func replaceInTwoSteps(_ staging: Staging, app: URL, steps: PublishSteps) throws {
        try place(app, at: staging.previous, steps: steps)
        do {
            try place(staging.incoming, at: app, steps: steps)
        } catch let failure {
            do {
                try place(staging.previous, at: app, steps: steps)
            } catch {
                throw CommandFailure.cannotCreate(
                    path: app.path,
                    reason: "\(Diagnostics.failureText(failure))\nThe previous version was moved aside to"
                        + " \(staging.previous.path) and could not be put back, so it is kept there."
                        + " While nothing is at \(app.path), running this again puts it back."
                        + " Do not put anything there before moving it back by hand: once something is"
                        + " there, the next run removes the version kept aside as a leftover")
            }
            throw failure
        }
    }

    /// `url` の場所に在るものの名前の綴りが `url` の最後の部品と違えば (大文字小文字を区別しないボリュームで、
    /// 大文字小文字だけが違う)、頼んだ綴りへ付け替える。付け替えられなくても投げない (中身は公開できている)。
    private static func respell(_ url: URL, steps: PublishSteps) {
        let wanted = url.lastPathComponent
        let parent = url.deletingLastPathComponent()
        guard let listing = try? FileManager.default.contentsOfDirectory(atPath: parent.path),
            !listing.contains(wanted),
            let actual = listing.first(where: {
                $0.compare(wanted, options: .caseInsensitive) == .orderedSame
            })
        else { return }
        try? steps.replace(parent.appendingPathComponent(actual), url)
    }

    /// `from` を `to` へ動かす。**行き先に在れば断る** (`RENAME_EXCL`)。ボリュームが `RENAME_EXCL` を
    /// 断れば (``isUnsupported(_:)``)、在るかを確かめてからの素の rename に倒す (前の実装の `moveItem` と
    /// 同じ強さ。確かめてから動かすまでの間は守らない)。
    private static func place(_ from: URL, at to: URL, steps: PublishSteps) throws {
        do {
            try steps.move(from, to)
        } catch where isUnsupported(error) {
            guard kind(of: to) == nil else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST))
            }
            try steps.replace(from, to)
        }
    }

    /// 実行ファイルの隣に並んだ資材の包み。
    ///
    /// **隣にあるものを、`excluding` に載ったもの以外全部入れる。** 依存が持ち込む包み (シェーダなど) は
    /// 宣言を辿っても出てこないが、無ければそもそも絵が出ない。除くのは、このパッケージの target のうち
    /// 実行 product が使わないもの (テストの target の fixture など — #3982) で、名前の形ではなく
    /// 依存の閉包で決めたものを受け取る。
    static func resourceBundles(besides executable: URL, excluding: Set<String>) -> [URL] {
        let listing =
            (try? FileManager.default.contentsOfDirectory(
                at: executable.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        return listing.filter { $0.pathExtension == "bundle" && !excluding.contains($0.lastPathComponent) }
            .sorted { $0.path < $1.path }
    }

    /// 配る範囲。宣言の閉包 (#3982) に、実行ファイルの隣の並びとビルドの置き場の依存の名前
    /// (`workspace-state.json`) から決めた、宣言から消えた target の古い包みの除外を足す (#4005)。
    /// 依存の名前が読めなければ、古い包みは除かない (``SwiftPM/Package/resourceScope(forProduct:beside:dependencyPackages:)``)。
    ///
    /// - Parameter buildDirectory: ビルドの置き場そのもの (``BuildContext/directory(under:)``)。
    static func resourceScope(
        of declared: SwiftPM.Package, product: String, executable: URL, buildDirectory: URL
    ) -> SwiftPM.Package.ResourceScope {
        let state = SwiftPM.read(
            SwiftPM.WorkspaceState.self, at: buildDirectory.appendingPathComponent("workspace-state.json"))
        return declared.resourceScope(
            forProduct: product,
            beside: resourceBundles(besides: executable, excluding: []).map(\.lastPathComponent),
            dependencyPackages: state?.packageNames)
    }

    // MARK: - 配る前の検査

    /// 宣言された資材の包みが、組み上がりに入っていることを見る。
    ///
    /// **黙って欠けさせない** ([ADR-0029] 決定 4)。欠けたまま配ると、受け取った側では
    /// 絵が出ないだけで、原因を指すものが何も残らない。
    ///
    /// [ADR-0029]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0029-post-run-surfaces.md
    static func check(_ app: URL, contains bundles: [String]) throws(CommandFailure) {
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        for name in bundles {
            let url = resources.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw .bundledResourceMissing(name: name, path: resources.path)
            }
        }
    }

    // MARK: - 署名

    /// 与えられた環境から、署名に使う名前を決める (検査から呼べる形)。
    ///
    /// **空白だけの値は書かれていないものとして扱う。** 鍵があることではなく、名乗れる
    /// 中身があることを見る ([AppIdentity] の読み方と揃えてある)。
    static func signIdentity(environment: [String: String]) -> String? {
        guard let given = environment[signIdentityKey] else { return nil }
        let trimmed = given.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 署名を当てる。
    ///
    /// **名前が無いときに当てる理由は、身元を示すことではない。** 包みの中身が組み上がった
    /// 後に差し替えられていないことを封じるためで、身元のほうは名前のある署名が持つ。
    ///
    /// **名前が与えられたときは、公証に出せる形で当てる。** 強化されたランタイムと
    /// タイムスタンプは公証の前提で、後から足せない (署名し直しになる)。ただし
    /// **公証そのものは通さない** — この環境には署名できる証明書が無く、一度も走らせて
    /// いないものを道具に持たせないためである。
    ///
    /// **entitlement は、強化されたランタイムを当てるとき (名前があるとき) だけ添える。**
    /// 強化されたランタイムの下では、カメラやマイクは entitlement が無いと許可を求める
    /// ところまで行けずに拒否される。名前を持たない署名はランタイムを当てないので、文言が
    /// あれば許可を求められる。
    ///
    /// **`codesign` は `swift` と同じ口 (``RunCommand/capture(_:capturing:errors:running:)``) で
    /// 起こす** ([#2483](https://github.com/mokume-metal/mokume/issues/2483)・
    /// [#2575](https://github.com/mokume-metal/mokume/issues/2575))。`env` 越しなので、`codesign` が
    /// 無い回は 127 で終わる — 自前で起こして終了コードだけを読むと、それを「署名に失敗した
    /// (127)」と名乗り、起こせなかった理由は `catch` で捨てて一律「codesign が無い」と名乗って
    /// いた。道具が無いこと・起こせなかった理由・署名の失敗を、それぞれの名で名乗る。出力は
    /// 端末へ流す (失敗の本文は `codesign` が標準エラーで名乗る)。
    ///
    /// - Parameter environment: `codesign` へ渡す環境。**検査から `PATH` を差し替えられる形にしてある。**
    static func sign(
        _ app: URL, as identity: String?, entitlements: [String: Bool] = [:],
        scratch: URL = FileManager.default.temporaryDirectory,
        environment: [String: String]? = nil
    ) throws(CommandFailure) {
        var file: URL?
        if identity != nil, !entitlements.isEmpty {
            file = try writeEntitlements(entitlements, in: scratch)
        }
        // **包みの隣には置かない。** 置くと、作品と一緒に送るものに紛れる
        defer {
            if let file { try? FileManager.default.removeItem(at: file) }
        }

        let process = Process()
        process.executableURL = RunCommand.envURL
        process.arguments = signArguments(for: app, as: identity, entitlements: file)
        process.environment = environment
        let result = try RunCommand.capture(process, capturing: false, errors: .inherit)
        guard result.status == 0 else {
            throw .codesignFailed(status: result.status)
        }
    }

    /// `codesign` に渡すもの (検査から呼べる形)。
    ///
    /// `entitlements` は、署名に埋め込むものを書いた plist の場所。名前が無いときは
    /// 強化されたランタイムを当てないので、渡されても使わない。
    static func signArguments(
        for app: URL, as identity: String?, entitlements: URL? = nil
    ) -> [String] {
        guard let identity else {
            return ["codesign", "--force", "--sign", "-", app.path]
        }
        var arguments = ["codesign", "--force", "--options", "runtime", "--timestamp"]
        if let entitlements { arguments += ["--entitlements", entitlements.path] }
        return arguments + ["--sign", identity, app.path]
    }

    /// entitlement を、`codesign` が読める plist として一時の場所へ書く。
    ///
    /// `codesign` は標準入力から読めず、ファイルの場所を要る。`scratch` は置き場
    /// (検査が、残っていないことを自分の置き場で見るために差し替える)。
    static func writeEntitlements(
        _ entitlements: [String: Bool], in scratch: URL = FileManager.default.temporaryDirectory
    ) throws(CommandFailure) -> URL {
        let url = scratch.appendingPathComponent("mokume-entitlements-\(UUID().uuidString).plist")
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: entitlements, format: .xml, options: 0)
            try data.write(to: url)
        } catch {
            throw .cannotCreate(path: url.path, reason: Diagnostics.failureText(error))
        }
        return url
    }

    // MARK: - 報告

    /// 束ねた後に言うこと。
    ///
    /// **確かめ方まで言う。** 束ねた側の手元では、作者の環境に依存した解決が残っていても
    /// たまたま当たるので、成功したように見える。退避してから起動する 1 手順が、それを
    /// 捕まえる唯一の場所である ([ADR-0029] 決定 4)。
    ///
    /// **開き方は紙を名指しする。** 手順をここに書くと、読んだ送り手が受け取る側へ
    /// 伝え直すことになり、配るたびに繰り返される。
    ///
    /// **どちらの段で署名したかを名乗る。** 名前のある署名を当てただけでは受け取った側の
    /// 往復は消えないので、名乗らないと「署名したのだから開くはず」と読まれる。
    ///
    /// **確かめ方の行は、走らせた場所からそのまま貼って動く形にする** (#2320)。退避するのは
    /// スケッチの `.build` (束ねるときの置き場はパッケージ直下に固定 — ``BuildDirectory/Fallback/packaging``)
    /// なので、`.build` と書くと走らせた場所がスケッチでないときに別の場所を指す。場所は
    /// 絶対パスで名指しし、シェルの 1 語に包む (``GivenPath/shellWord(_:)``)。
    ///
    /// **名乗りが見本の値のままなら、警告をもう一度ここで言う** (#3442)。束ねる前の 1 行
    /// (``AppIdentity/warnIfExample(to:)``) は、続く `swift build` の出力で流れる。送る前に読む
    /// この報せの末尾へ置けば、配る直前の目に入る。文は ``AppIdentity/warning`` から引く (写さない)。
    ///
    /// - Parameters:
    ///   - package: 束ねたスケッチの場所 (絶対パス)。
    ///   - identity: 束ねた名乗り。**省略できない** — 呼び元が渡し忘れると、警告だけが黙って落ちる。
    ///
    /// [ADR-0029]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0029-post-run-surfaces.md
    static func report(
        for app: URL, package: URL, note: URL, signedAs signature: String?,
        identity: AppIdentity
    ) -> String {
        let base = """
        Bundled: \(app.path)

        What this guarantees is that it launches on another machine and draws.
        \(signatureLine(signature))
        The first launch is blocked on the receiving side, so a note on how to open it went
        next to the bundle. **Send it along with the work**:

          \(note.path)

        Before sending, check that nothing still resolves through the author's environment.
        Once it draws, quit the app: .build is put back as soon as it closes,
        or if you stop this with Ctrl-C.

          \(checkLine(for: app, package: package))

        If it draws with .build moved aside, the bundle carries all it needs.
        """
        guard let warning = identity.warning else { return base }
        return base + "\n\n" + warning
    }

    /// 確かめ方の 1 行。スケッチの `.build` を退避して `.app` を開き、戻す。
    ///
    /// **`open -W` で、アプリを閉じるまで `.build` を戻さない** (#2833)。`open` は起動を
    /// 頼むとすぐ戻るので、アプリが資材を読む前に `.build` が戻りうる。そうなると作者の環境
    /// (`.build` の下の束) を通して読めてしまい、確かめ方が素通りする。代償は、アプリを
    /// 閉じるまで端末に戻らないこと — ``report(for:package:note:signedAs:)`` が閉じるよう言う。
    ///
    /// **`-n` で、動いているアプリがあっても新しく起こす。** `-W` だけでは、同じアプリが
    /// 既に動いていると、新しく起動せずそれを前に出してその終了を待つだけになる。資材を読み
    /// 終えたアプリが描いているのを見て、確かめ方が素通りする。
    ///
    /// **待つ間に止められても `.build` を戻す。** 待ちが長いので、Ctrl-C や端末を閉じる
    /// (HUP・INT・TERM) が起きうる。戻す手が行の最後にあるだけだと `.build` が
    /// `.build-held` のまま残り、次のビルドが全部やり直しになる。包む殻 `( … )` の中で EXIT に
    /// 戻す手を掛け、信号は `exit` に倒して EXIT を通す。殻の中で変数に置くので、貼った人の
    /// 殻に名前が残らず、trap の文字列にパスを写さずに済む (パスの引用は変数の代入が受け持つ)。
    ///
    /// **退避先は、その回が `mktemp -d` で作る一意なディレクトリの中** (#3985)。決まった名前
    /// (`.build-held`) へ `mv` すると、同じ名前のディレクトリが既にあったとき `.build` はその
    /// **中へ**入り、戻す手は退避先ごと `.build` の中へ入れる — 終了 0 のまま `.build/.build`
    /// ができ、作者が置いていた物も巻き込む。その回が作った場所なら衝突せず、戻した後に
    /// 消してよいのも空になったその場所だけ (`rmdir` は中身が残っていれば消さない)。
    ///
    /// **戻す手は `mv` より先に掛ける。** 後に掛けると、退避した直後に届いた信号で `.build` が
    /// 乱数の名前の下に取り残される。戻す手は「退避した物が在るときだけ戻す」ので、`mv` の前に
    /// 止められても `mv` が失敗しても、作った空の場所を消すだけで済む。
    ///
    /// **確かめている間に `.build` が作り直されていたら、戻さない。** 戻す `mv` の先が既に在る
    /// ディレクトリだと、退避側と同じく中へ入れて入れ子にする。どちらも消さず、退避した物の在処を
    /// 標準エラーで名乗って 0 以外で終わる。退避した物の有無もリンクとして見る (`-L`) — 切れた
    /// シンボリックリンクの `.build` は `-e` では無いことになり、戻されずに取り残される。
    ///
    /// **退避先を消せなければ 0 以外で終わる。** 物が残ったまま成功で終わると、溜まっていくのに
    /// 気付けない。`open` が先に失敗していたら、その終了コード (`s`) を潰さない。
    static func checkLine(for app: URL, package: URL) -> String {
        let build = GivenPath.shellWord(package.appendingPathComponent(".build"))
        let template = GivenPath.shellWord(package.appendingPathComponent(".build-held.XXXXXX"))
        let restore =
            "s=$?; if [ -e \"$held/.build\" ] || [ -L \"$held/.build\" ]; then"
            + " if [ -e \"$build\" ] || [ -L \"$build\" ]; then"
            + " printf \"%s\\n\" \"A new .build appeared while checking;"
            + " the one moved aside was left at $held/.build\" >&2; exit 1; fi;"
            + " mv \"$held/.build\" \"$build\" || exit; fi;"
            + " rmdir \"$held\" || exit $((s ? s : 1))"
        return "( build=\(build); held=$(mktemp -d \(template)) || exit;"
            + " trap '\(restore)' EXIT; trap exit HUP INT TERM;"
            + " mv \"$build\" \"$held/.build\" || exit;"
            + " open -n -W \(GivenPath.shellWord(app)) )"
    }

    /// どちらの段で署名したかを 1 行で言う。
    ///
    /// **名前があっても「開くようになった」とは言わない。** 公証を通すまで受け取った側の
    /// 往復は残るので、そこを先に言い切ってしまうと期待だけが先に行く。
    static func signatureLine(_ signature: String?) -> String {
        guard let signature else {
            return "It is signed ad-hoc, with no identity."
        }
        return "It is signed as \"\(signature)\", in a form that can be notarized. "
            + "**It has not been notarized yet.**"
    }

    // MARK: - 開き方

    /// 開き方を書いた 1 枚を、包みの**隣**に出す。
    ///
    /// **中には入れない。** 開けないことが問題なのだから、中にあっては読めない。
    ///
    /// 受け取った側の設定往復は**消せない** — 名前のある署名と公証を採らないと決めた
    /// 以上、macOS はここを通す。消せない代わりに、説明を**送り手の記憶から外す**。
    /// 作品と一緒に送れる物にしておけば、配るたびに手順を伝え直さずに済む。
    static func writeOpeningNote(for identity: AppIdentity, beside app: URL)
        throws(CommandFailure) -> URL
    {
        // **書く直前にも、ビルドの前と同じ確かめを通す** (#3054)。ここでだけ確かめると、止まる回に
        // 作り直した `.app` が残る。ここは、前に済んだ確かめから書くまでに変わった分の守り
        let url = try replaceableNote(for: identity, in: app.deletingLastPathComponent())
        do {
            // **一時ファイルを経ずに書く** (#3981)。書く先は一時の置き場の中で、`--out` への公開は rename で
            // 行うので、ここで原子的に書く必要が無い。経由すると、書く途中で強制終了されたときに置き場の中へ
            // 知らない名前が残り、その置き場は片付けの対象から外れる (``isOwnRemnant(_:name:)``)
            try Data(openingNote(for: identity).utf8).write(to: url)
        } catch {
            // 行き先がディレクトリのときは確かめで先に断る (#3054)。ここへ来るのは書けなかった事情
            // (置き場が無い・権限が無いなど) で、OS の文面で名乗る (#2839)
            throw .cannotCreate(
                path: url.path,
                reason: Diagnostics.writingPosixReason(error, at: url) ?? error.localizedDescription)
        }
        return url
    }

    /// 紙の名前。
    ///
    /// **作品名を入れる。** 受け取った側のフォルダに落ちたとき、何についての紙かが
    /// 名前だけで分かる必要がある。
    static func noteFileName(for identity: AppIdentity) -> String {
        "How to open \(identity.name).txt"
    }

    /// 紙の中身。
    ///
    /// **止められた後に実際に踏む手順だけを書く。** 安全かどうかのような、こちらから
    /// 断定できないことは書かない ([ADR-0029] 決定 2 と同じ規律)。
    static func openingNote(for identity: AppIdentity) -> String {
        """
        \(openingNoteMark(for: identity))

        The first time, you have to give it permission to open yourself.
        This app is distributed in a form where macOS cannot verify who made it.

        1. Double-click \(identity.name).app (it will say it cannot be opened)
        2. Apple menu -> System Settings -> Privacy & Security
        3. Near the bottom there is a line about \(identity.name). Press "Open Anyway"
        4. Double-click \(identity.name).app again

        From the second time on, it just opens.
        """
    }

    // MARK: - ファイル

    private static func create(_ directory: URL) throws(CommandFailure) {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            throw .cannotCreate(path: directory.path, reason: Diagnostics.failureText(error))
        }
    }

    private static func copy(_ source: URL, to destination: URL) throws(CommandFailure) {
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw .cannotCreate(path: destination.path, reason: Diagnostics.failureText(error))
        }
    }
}
