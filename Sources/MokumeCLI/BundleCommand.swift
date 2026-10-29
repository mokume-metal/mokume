// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

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

        // **束ねる前に見る。** 宣言の抜けはビルドを通るので、後では「組み上がったのに
        // 絵が出ない」形になる — しかも配った先で出る
        try ResourceDeclaration.check(in: directory)
        let identity = try AppIdentity.read(in: directory)
        identity.warnIfExample()
        // **許可の文言も、ビルドの前に見る。** 使うのに無いと、止まるのは配った先になる
        try DeviceUse.check(in: directory, identity: identity)
        // **作り直す先が自分の出力でなければ、ビルドの前に止まる** (#2500)。消せないと分かるのは
        // 数分のビルドの後ではなく、いまでよい
        _ = try replaceableApp(for: identity, in: out)

        // **宣言は 1 度だけ読む。** 走らせるものを決めるのにも、下限の版と資材の包みを
        // 知るのにも要る — 別々に引くと `dump-package` を 2 回起こすことになる
        //
        // **道具立てが答えなかった回を、宣言の不備と名乗らない** (#2483)。`dump-package` が 0 以外で
        // 終わると宣言は読めないが、それは `Package.swift` が実行ファイルを宣言していないことでは
        // ない。壊れた宣言そのものを道具立てが読めなかった回も、理由は標準エラーにある
        let reading = try RunCommand.declaration(in: directory)
        if let failure = reading.failure { throw failure }
        let declared = reading.package
        guard let product = declared?.executableProductName else {
            throw .noExecutable(path: directory.path)
        }
        // **束ねるときは置き場を共有しない** (`BuildDirectory.Fallback.packaging` が理由を
        // 持つ)。共有の置き場には同じ鍵の全スケッチの包みが並ぶので、隣にあるものを
        // 全部入れる下の作りが**他人の資材を配ってしまう**
        let context = BuildContext(
            configuration: configuration, place: .inPackage(.packaging), product: product)
        let executable = try RunCommand.buildAndResolve(in: directory, context: context)

        let app = try assemble(
            executable: executable, identity: identity,
            minimumSystemVersion: declared?.minimumMacOSVersion ?? defaultMinimumSystemVersion,
            into: out)
        let signature = signIdentity(environment: ProcessInfo.processInfo.environment)
        let note = try finish(
            app, identity: identity, bundles: declared?.declaredResourceBundles ?? []
        ) { app throws(CommandFailure) in
            try sign(app, as: signature, entitlements: identity.entitlements)
        }
        print(
            report(
                for: app, package: directory, note: note, signedAs: signature,
                identity: identity))
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

    /// 包みを組む。中身は毎回まっさらから作り直す。
    ///
    /// **作り直しは消してから。** 前の版の資材が残ると、消したはずのものが配られる —
    /// しかも手元では動くので気付けない。
    ///
    /// **消してよいのは、`--out` の直下にある、前の版の自分の `.app` だけである** (#2309・#2500)。
    /// 場所は ``replaceableApp(for:in:)`` が、中身は ``isOwnOutput(_:identity:)`` が確かめ、
    /// どちらかが外れたら何も消さずに投げる。
    static func assemble(
        executable: URL, identity: AppIdentity, minimumSystemVersion: String, into out: URL
    ) throws(CommandFailure) -> URL {
        let app = try replaceableApp(for: identity, in: out)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let programs = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)

        try retire(app, in: out, name: identity.name)
        try create(programs)
        try create(resources)

        // **`Info.plist` を先に書く。** 印 (``AppIdentity/bundledMarkKey``) が入っているので、組み立ての
        // 途中で止まって残った `.app` も、次の回に自分の出力と確かめられて作り直せる (後に書くと、
        // 途中の `.app` は印を持たず、手で消すまで先へ進めない)
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
        for bundle in resourceBundles(besides: executable) {
            try copy(bundle, to: resources.appendingPathComponent(bundle.lastPathComponent))
        }
        return app
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

    /// 前の出力を消す一時の名前の形 (`.<name>.app.removing-<UUID>`)。名前の前後を固定する。
    private static func retiringPrefix(_ name: String) -> String { ".\(name).app.removing-" }

    /// 消し損ねた一時の名前か。**消してよいのは、この名前のこの形のものだけ** (`<UUID>` が UUID として
    /// 読めるもの)。ほかの `.` から始まるものや、ほかの作品の一時の名前には触れない。
    static func isRetiredRemnant(_ fileName: String, name: String) -> Bool {
        let prefix = retiringPrefix(name)
        guard fileName.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(fileName.dropFirst(prefix.count))) != nil
    }

    /// 前の `<name>.app` を退ける。**`<name>.app` の場所に半端なものを残さない** (#2500)。
    ///
    /// 直接消すと、途中で止まった (Ctrl-C・kill・消せないものがある) とき `Info.plist` だけが先に
    /// 消えて他が残ることがあり、次の回に自分の出力と確かめられず断られる。だから `--out` の中の
    /// 一時の名前へ**先に rename し** (同じ場所での rename は 1 手で、半端が出ない)、それから消す。
    /// rename に失敗したら黙らずに投げる (`<name>.app` は元のまま)。一時の名前の中身を消し損ねても、
    /// 新しい `<name>.app` は作れるので投げず、残ったものは次の回に ``isRetiredRemnant(_:name:)`` の形
    /// のものだけ先に消す。
    private static func retire(_ app: URL, in out: URL, name: String) throws(CommandFailure) {
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        for entry in listing where isRetiredRemnant(entry, name: name) {
            try? FileManager.default.removeItem(at: out.appendingPathComponent(entry))
        }
        guard kind(of: app) != nil else { return }
        let retiring = out.appendingPathComponent(
            "\(retiringPrefix(name))\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.moveItem(at: app, to: retiring)
        } catch {
            throw .cannotCreate(path: app.path, reason: Diagnostics.failureText(error))
        }
        try? FileManager.default.removeItem(at: retiring)
    }

    /// 実行ファイルの隣に並んだ資材の包み。
    ///
    /// **隣にあるものを全部入れる。** 依存が持ち込む包み (シェーダなど) は宣言を辿っても
    /// 出てこないが、無ければそもそも絵が出ない。
    static func resourceBundles(besides executable: URL) -> [URL] {
        let listing =
            (try? FileManager.default.contentsOfDirectory(
                at: executable.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        return listing.filter { $0.pathExtension == "bundle" }.sorted { $0.path < $1.path }
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
    static func checkLine(for app: URL, package: URL) -> String {
        let build = GivenPath.shellWord(package.appendingPathComponent(".build"))
        let held = GivenPath.shellWord(package.appendingPathComponent(".build-held"))
        return "( build=\(build); held=\(held); mv \"$build\" \"$held\" || exit;"
            + " trap 'mv \"$held\" \"$build\"' EXIT; trap exit HUP INT TERM;"
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
        let url = app.deletingLastPathComponent()
            .appendingPathComponent(noteFileName(for: identity))
        do {
            try openingNote(for: identity).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // 置き換えて書くので、行き先がディレクトリだと下の失敗は ENOENT になる (#2839)
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
        How to open \(identity.name)

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
