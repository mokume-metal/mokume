// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

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
    }

    static func run(_ arguments: [String]) throws(CommandFailure) {
        let options = try parse(arguments)
        let directory = URL(fileURLWithPath: options.path, isDirectory: true)
        guard
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Package.swift").path)
        else { throw .packageNotFound(path: directory.path) }

        // **束ねる前に見る。** 宣言の抜けはビルドを通るので、後では「組み上がったのに
        // 絵が出ない」形になる — しかも配った先で出る
        try ResourceDeclaration.check(in: directory)
        let identity = try AppIdentity.read(in: directory)

        try RunCommand.build(in: directory, configuration: configuration)
        let executable = try RunCommand.executablePath(in: directory, configuration: configuration)

        let dump = try RunCommand.swift(
            ["package", "dump-package"], in: directory, capturing: true
        ).output
        let out =
            options.out.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? directory.appendingPathComponent(defaultOutputDirectory, isDirectory: true)

        let app = try assemble(
            executable: executable, identity: identity,
            minimumSystemVersion: minimumSystemVersion(inDumpOf: dump)
                ?? defaultMinimumSystemVersion,
            into: out)
        try check(app, contains: declaredResourceBundles(inDumpOf: dump))
        let signature = signIdentity(environment: ProcessInfo.processInfo.environment)
        try sign(app, as: signature)
        let note = try writeOpeningNote(for: identity, beside: app)
        print(report(for: app, note: note, signedAs: signature))
    }

    // MARK: - 引数

    static func parse(_ arguments: [String]) throws(CommandFailure) -> Options {
        var path: String?
        var out: String?
        var index = arguments.startIndex
        while index < arguments.endIndex {
            switch arguments[index] {
            case "--out":
                index += 1
                guard index < arguments.endIndex else {
                    throw .usage("--out には置き場が要る\n\n" + Command.usage())
                }
                out = arguments[index]
            case let argument where argument.hasPrefix("-"):
                throw .usage("知らない選択肢: \(argument)\n\n" + Command.usage())
            case let argument:
                guard path == nil else { throw .usage("場所は 1 つだけ: \(argument)") }
                path = argument
            }
            index += 1
        }
        return Options(path: path ?? FileManager.default.currentDirectoryPath, out: out)
    }

    // MARK: - 組み立て

    /// 包みを組む。中身は毎回まっさらから作り直す。
    ///
    /// **作り直しは消してから。** 前の版の資材が残ると、消したはずのものが配られる —
    /// しかも手元では動くので気付けない。
    static func assemble(
        executable: URL, identity: AppIdentity, minimumSystemVersion: String, into out: URL
    ) throws(CommandFailure) -> URL {
        let app = out.appendingPathComponent("\(identity.name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let programs = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)

        try? FileManager.default.removeItem(at: app)
        try create(programs)
        try create(resources)

        try copy(executable, to: programs.appendingPathComponent(executable.lastPathComponent))
        for bundle in resourceBundles(besides: executable) {
            try copy(bundle, to: resources.appendingPathComponent(bundle.lastPathComponent))
        }

        let plist = identity.infoPlist(
            executable: executable.lastPathComponent,
            minimumSystemVersion: minimumSystemVersion)
        guard
            let data = try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
        else {
            throw .cannotCreate(path: contents.appendingPathComponent("Info.plist").path,
                reason: "名乗りを書き出せなかった")
        }
        do {
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        } catch {
            throw .cannotCreate(
                path: contents.appendingPathComponent("Info.plist").path,
                reason: error.localizedDescription)
        }
        return app
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

    /// パッケージの宣言から、入っているべき包みの名前を導く。
    ///
    /// 道具立ては資材を `<パッケージ>_<ターゲット>.bundle` の名前で作る。
    static func declaredResourceBundles(inDumpOf dump: String) -> [String] {
        guard let root = object(inDumpOf: dump),
            let package = root["name"] as? String,
            let targets = root["targets"] as? [[String: Any]]
        else { return [] }
        var names: [String] = []
        for target in targets {
            guard let name = target["name"] as? String,
                let resources = target["resources"] as? [[String: Any]], !resources.isEmpty
            else { continue }
            names.append("\(package)_\(name).bundle")
        }
        return names
    }

    /// パッケージが名乗っている下限の版。
    static func minimumSystemVersion(inDumpOf dump: String) -> String? {
        guard let root = object(inDumpOf: dump),
            let platforms = root["platforms"] as? [[String: Any]]
        else { return nil }
        for platform in platforms
        where (platform["platformName"] as? String) == "macos" {
            return platform["version"] as? String
        }
        return nil
    }

    private static func object(inDumpOf dump: String) -> [String: Any]? {
        guard let data = dump.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
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
    static func sign(_ app: URL, as identity: String?) throws(CommandFailure) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = signArguments(for: app, as: identity)
        do {
            try process.run()
        } catch {
            throw .toolchainMissing("codesign")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw .codesignFailed(status: process.terminationStatus)
        }
    }

    /// `codesign` に渡すもの (検査から呼べる形)。
    static func signArguments(for app: URL, as identity: String?) -> [String] {
        guard let identity else {
            return ["codesign", "--force", "--sign", "-", app.path]
        }
        return [
            "codesign", "--force", "--options", "runtime", "--timestamp",
            "--sign", identity, app.path,
        ]
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
    /// [ADR-0029]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0029-post-run-surfaces.md
    static func report(for app: URL, note: URL, signedAs signature: String?) -> String {
        """
        束ねた: \(app.path)

        保証しているのは「別の機械で起動して絵が出る」ところまで。
        \(signatureLine(signature))
        受け取った側では初回の起動が止められるので、開き方を書いた紙を隣に出した。
        **作品と一緒に送る**:

          \(note.path)

        配る前に、作者の環境に依存した解決が残っていないかを確かめる:

          mv .build .build-held && open "\(app.path)" ; mv .build-held .build

        退避したまま絵が出れば、包みの中だけで足りている。
        """
    }

    /// どちらの段で署名したかを 1 行で言う。
    ///
    /// **名前があっても「開くようになった」とは言わない。** 公証を通すまで受け取った側の
    /// 往復は残るので、そこを先に言い切ってしまうと期待だけが先に行く。
    static func signatureLine(_ signature: String?) -> String {
        guard let signature else {
            return "署名は名前を持たないもの (ad-hoc) を当てた。"
        }
        return "署名は「\(signature)」で、公証に出せる形で当てた。**公証はまだ通っていない。**"
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
            throw .cannotCreate(path: url.path, reason: error.localizedDescription)
        }
        return url
    }

    /// 紙の名前。
    ///
    /// **作品名を入れる。** 受け取った側のフォルダに落ちたとき、何についての紙かが
    /// 名前だけで分かる必要がある。
    static func noteFileName(for identity: AppIdentity) -> String {
        "\(identity.name) を開くには.txt"
    }

    /// 紙の中身。
    ///
    /// **止められた後に実際に踏む手順だけを書く。** 安全かどうかのような、こちらから
    /// 断定できないことは書かない ([ADR-0029] 決定 2 と同じ規律)。
    static func openingNote(for identity: AppIdentity) -> String {
        """
        \(identity.name) を開くには

        はじめの 1 回だけ、開く許可を自分で与える必要があります。
        このアプリは、macOS が開発元を確認できない形で配られているためです。

        1. \(identity.name).app を二重クリックする (開けません、と出ます)
        2. アップルメニュー → システム設定 → プライバシーとセキュリティ を開く
        3. 下の方に \(identity.name) についての行があるので、「このまま開く」を押す
        4. もう一度 \(identity.name).app を二重クリックする

        2 回目からは、そのまま開きます。
        """
    }

    // MARK: - ファイル

    private static func create(_ directory: URL) throws(CommandFailure) {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            throw .cannotCreate(path: directory.path, reason: error.localizedDescription)
        }
    }

    private static func copy(_ source: URL, to destination: URL) throws(CommandFailure) {
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw .cannotCreate(path: destination.path, reason: error.localizedDescription)
        }
    }
}
