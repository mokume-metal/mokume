// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI

/// 束ねるときの組み立てと、配る前の検査。
///
/// 組み上げ自体は道具立てを呼ぶので重い。ここで見るのは**組み上がった後の並びと判定**で、
/// 実際に走るところまでの通しは ``TemplateBuildTests`` が受け持つ。
@Suite("束ねる")
struct BundleCommandTests {
    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 組み上がったつもりの並び (実行ファイルと、隣に並んだ包み) を作る。
    private func makeBuildOutput(in root: URL) throws -> URL {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let bundle = bin.appendingPathComponent("demo_demo.bundle/assets", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "木目".write(
            to: bundle.appendingPathComponent("mark.txt"), atomically: true, encoding: .utf8)
        let executable = bin.appendingPathComponent("demo")
        try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
        return executable
    }

    private let identity = AppIdentity(
        name: "Demo", identifier: "org.example.demo", version: "1.2.3")

    @Test("組み上がりが、包みの並びになる")
    func theLayoutIsAnApplicationBundle() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeBuildOutput(in: root)

        let app = try BundleCommand.assemble(
            executable: executable, identity: identity, minimumSystemVersion: "26.0",
            into: root.appendingPathComponent("out", isDirectory: true))

        #expect(app.lastPathComponent == "Demo.app")
        for path in ["Contents/Info.plist", "Contents/MacOS/demo", "Contents/Resources/demo_demo.bundle"] {
            #expect(
                FileManager.default.fileExists(atPath: app.appendingPathComponent(path).path),
                "包みに \(path) が無い")
        }
    }

    @Test("名乗りが、包みの一覧として書き出される")
    func theIdentityIsWrittenIntoTheBundle() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeBuildOutput(in: root)

        let app = try BundleCommand.assemble(
            executable: executable, identity: identity, minimumSystemVersion: "26.0",
            into: root.appendingPathComponent("out", isDirectory: true))

        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let plist =
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        #expect(plist?["CFBundleIdentifier"] as? String == "org.example.demo")
        #expect(plist?["CFBundleName"] as? String == "Demo")
        #expect(plist?["CFBundleExecutable"] as? String == "demo")
    }

    /// 文言が包みの一覧に入るのは、`assemble` を通った後の Info.plist で見る。
    @Test("書いた許可の文言が、組み上がった包みの Info.plist に入る")
    func theUsageTextsAreWrittenIntoTheBundle() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeBuildOutput(in: root)
        var written = identity
        written.cameraUsage = "木目のカメラ映像を絵にするため"
        written.microphoneUsage = "Grain listens to the room"

        let app = try BundleCommand.assemble(
            executable: executable, identity: written, minimumSystemVersion: "26.0",
            into: root.appendingPathComponent("out", isDirectory: true))

        let plist = try readInfoPlist(of: app)
        #expect(plist["NSCameraUsageDescription"] as? String == "木目のカメラ映像を絵にするため")
        #expect(plist["NSMicrophoneUsageDescription"] as? String == "Grain listens to the room")
    }

    @Test("文言を書かなければ、許可の鍵は包みに入らない")
    func noUsageKeysWithoutTexts() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeBuildOutput(in: root)

        let app = try BundleCommand.assemble(
            executable: executable, identity: identity, minimumSystemVersion: "26.0",
            into: root.appendingPathComponent("out", isDirectory: true))

        let plist = try readInfoPlist(of: app)
        #expect(plist["NSCameraUsageDescription"] == nil)
        #expect(plist["NSMicrophoneUsageDescription"] == nil)
    }

    private func readInfoPlist(of app: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any])
    }

    /// 前の版の資材が残ると、消したはずのものが配られる — しかも手元では動く。
    @Test("組み直しは、前の中身を残さない")
    func rebuildingDoesNotKeepTheOldContents() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeBuildOutput(in: root)
        let out = root.appendingPathComponent("out", isDirectory: true)

        let app = try BundleCommand.assemble(
            executable: executable, identity: identity, minimumSystemVersion: "26.0", into: out)
        let stale = app.appendingPathComponent("Contents/Resources/old.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)

        _ = try BundleCommand.assemble(
            executable: executable, identity: identity, minimumSystemVersion: "26.0", into: out)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    // MARK: - 消すのは --out の直下の自分の .app だけ (#2309)

    /// **名前の検めとは別の守り。** 消してよいのは `--out` の直下にある、前の版の自分の
    /// `.app` だけである。名乗りを通らずに組んだ `AppIdentity` (`/` を含む名前) を渡しても、
    /// `--out` の外も中も消さずに投げる ([#2309](https://github.com/mokume-metal/mokume/issues/2309))。
    ///
    /// `..` は在るディレクトリを経てしか解けないので、`--out` を先に作っておく (本文の再現の
    /// 「2 回目は bundle/ が在るので .. が解ける」と同じ状況)。
    @Test(
        "作る .app が --out の直下でなければ、何も消さずに投げる",
        arguments: ["../victim", "AC/DC", "sub/../victim"])
    func anAppOutsideTheOutputIsNeverRemoved(name: String) throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeBuildOutput(in: root)
        let out = root.appendingPathComponent("out", isDirectory: true)
        // `sub/../victim` が `--out` の直下の victim.app を指すように、sub も置く
        try FileManager.default.createDirectory(
            at: out.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true)
        // 消されてはならないもの: --out の外 (隣) と、--out の直下の別の .app
        var kept: [URL] = []
        for victim in [root.appendingPathComponent("victim.app"), out.appendingPathComponent("victim.app")] {
            try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
            let keep = victim.appendingPathComponent("keep.txt")
            try "keep".write(to: keep, atomically: true, encoding: .utf8)
            kept.append(keep)
        }
        let before = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()

        let unchecked = AppIdentity(name: name, identifier: "org.example.bund", version: "0.1.0")
        // 2 回打っても同じ (本文の再現は 2 回目で消えた)
        for _ in 0..<2 {
            #expect(throws: CommandFailure.self, "\(name) で投げなかった") {
                try BundleCommand.assemble(
                    executable: executable, identity: unchecked, minimumSystemVersion: "26.0",
                    into: out)
            }
        }
        for keep in kept {
            #expect(FileManager.default.fileExists(atPath: keep.path), "\(name) で \(keep.path) が消えた")
        }
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: out.path).sorted() == before,
            "\(name) で --out の下に何かを作った")
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("AC").path))
    }

    /// 裏側。**ファイル名にできる名前は、いままでどおり `--out` の直下に包みと紙ができる。**
    @Test("/ の無い名前は、--out の直下に包みと開き方の紙ができる", arguments: ["Bund", "My Sketch", "木目"])
    func aPlainNameLandsDirectlyInTheOutput(name: String) throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeBuildOutput(in: root)
        let out = root.appendingPathComponent("out", isDirectory: true)
        let named = AppIdentity(name: name, identifier: "org.example.bund", version: "0.1.0")

        let app = try BundleCommand.assemble(
            executable: executable, identity: named, minimumSystemVersion: "26.0", into: out)
        let note = try BundleCommand.writeOpeningNote(for: named, beside: app)

        #expect(app.standardizedFileURL == out.appendingPathComponent("\(name).app").standardizedFileURL)
        #expect(note.standardizedFileURL == out.appendingPathComponent("How to open \(name).txt").standardizedFileURL)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
                == ["How to open \(name).txt", "\(name).app"].sorted())
    }

    // MARK: - 名前の長さ (#2501)

    /// **239 までの名前は、いままでどおり `--out` の直下に包みと紙ができる** ([#2501](https://github.com/mokume-metal/mokume/issues/2501))。
    /// 紙は `write(to:atomically: true)` で書くので、途中の一時ファイルの名前で上限が下がるなら
    /// ここが赤くなる — 計算ではなく、紙を実際に書いて確かめる。名乗りの段を通して組み、
    /// 線の内側であることも見る。`が` × 119 は、ファイルシステムへ渡る形 (か + 濁点) で 238。
    @Test(
        "239 までの名前は、--out の直下に包みと開き方の紙ができる (紙を実際に書く)",
        arguments: [
            RepeatedName("a", 239), RepeatedName("木", 239), RepeatedName("😀", 119, unitsEach: 2),
            RepeatedName("\u{304C}", 119, unitsEach: 2),
        ])
    func aNameUpToTheLimitLandsDirectlyInTheOutput(given: RepeatedName) throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeBuildOutput(in: root)
        let out = root.appendingPathComponent("out", isDirectory: true)
        let named = try AppIdentity.make(
            from: AppIdentity.Wire(
                name: given.name, identifier: "org.example.bund", version: "0.1.0"),
            path: root.appendingPathComponent(AppIdentity.fileName).path)

        let app = try BundleCommand.assemble(
            executable: executable, identity: named, minimumSystemVersion: "26.0", into: out)
        let note = try BundleCommand.writeOpeningNote(for: named, beside: app)

        #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path))
        #expect(try String(contentsOf: note, encoding: .utf8) == BundleCommand.openingNote(for: named))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
                == ["How to open \(given.name).txt", "\(given.name).app"].sorted())
    }

    /// 裏側。**線はちょうど「紙が書けなくなる長さ」の始まりにある** — 239 を越える名前は、検めが
    /// 無くても `.app` までは作れて紙で落ちる (直す前に、ビルドと署名の後で起きていたこと)。
    /// だから越える名前を断っても、成功していた名前は 1 つも失わない。名乗りを通らずに組んだ
    /// `AppIdentity` で、実際のファイルシステムに書いて確かめる。
    @Test(
        "239 を越える名前は、検めが無ければ .app はできても紙が書けない",
        arguments: [
            RepeatedName("a", 240), RepeatedName("木", 240), RepeatedName("😀", 120, unitsEach: 2),
            RepeatedName("\u{304C}", 120, unitsEach: 2),
        ])
    func aNameBeyondTheLimitCannotHaveItsNote(given: RepeatedName) throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeBuildOutput(in: root)
        let out = root.appendingPathComponent("out", isDirectory: true)
        let unchecked = AppIdentity(
            name: given.name, identifier: "org.example.bund", version: "0.1.0")

        let app = try BundleCommand.assemble(
            executable: executable, identity: unchecked, minimumSystemVersion: "26.0", into: out)
        #expect(throws: CommandFailure.self, "\(given.testDescription) の紙が書けた") {
            try BundleCommand.writeOpeningNote(for: unchecked, beside: app)
        }
    }

    /// 上限 (239) は紙の名前から決まる。**紙の名前を変えたら、上限も合わせて動かす** — 動かさないと
    /// 紙が書けない名前を通すか、書ける名前を断る。ここがその食い違いで赤くなる。
    @Test("上限ちょうどの名前で、開き方の紙の名前がちょうどファイル名の上限になる")
    func theLimitIsWhereTheNoteFillsAFileName() {
        let identity = AppIdentity(
            name: String(repeating: "a", count: AppIdentity.maximumNameLength),
            identifier: "org.example.bund", version: "0.1.0")
        #expect(
            AppIdentity.fileNameLength(of: BundleCommand.noteFileName(for: identity))
                == AppIdentity.fileNameLimit)
    }

    @Test("宣言された包みが入っていなければ止まる")
    func aMissingDeclaredBundleStops() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeBuildOutput(in: root)
        let app = try BundleCommand.assemble(
            executable: executable, identity: identity, minimumSystemVersion: "26.0",
            into: root.appendingPathComponent("out", isDirectory: true))

        #expect(throws: Never.self) { try BundleCommand.check(app, contains: ["demo_demo.bundle"]) }
        #expect(throws: (any Error).self) {
            try BundleCommand.check(app, contains: ["demo_other.bundle"])
        }
    }

    /// 確かめ方まで言わないと、束ねた側の手元では成功したようにしか見えない。
    @Test("束ねた後の報せが、退避して起動する手順を含む")
    func theReportTellsHowToCheck() {
        let report = BundleCommand.report(
            for: URL(fileURLWithPath: "/tmp/Demo.app"),
            package: URL(fileURLWithPath: "/tmp/demo", isDirectory: true),
            note: URL(fileURLWithPath: "/tmp/How to open Demo.txt"), signedAs: nil)
        #expect(report.contains("/tmp/Demo.app"))
        #expect(report.contains(".build"))
    }

    /// **確かめ方の行は、走らせた場所からそのまま貼って動く** (#2320)。`mv .build …` と
    /// 書いていたので、スケッチの親で `bundle <dir>` を打った人が貼ると、親に `.build` は
    /// 無く、何も確かめずに失敗していた。動かすのはスケッチの `.build` である (束ねるときの
    /// 置き場はパッケージ直下に固定 — `BuildDirectory.Fallback.packaging`)。
    ///
    /// `open` は偽物を `PATH` の先に置き、呼ばれた時点で `.build` が退避されているかを
    /// 書き残させる — 本物の `.app` を開かずに、手順の順序まで見る。
    @Test(
        "確かめ方の行は、スケッチの親から貼っても、スケッチの .build を退避して戻す",
        arguments: ["bund", "bund with space", "it's bund"])
    func theCheckCanBePastedFromTheParent(name: String) throws {
        let parent = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: parent) }
        let sketch = parent.appendingPathComponent(name, isDirectory: true)
        let build = sketch.appendingPathComponent(".build", isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try "".write(to: build.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        let app = sketch.appendingPathComponent("bundle/Bund.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        let tools = parent.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let record = parent.appendingPathComponent("opened")
        let open = tools.appendingPathComponent("open")
        try """
            #!/bin/sh
            { printf '%s\\n' "$1"
              if [ -e '\(sketch.path.replacingOccurrences(of: "'", with: #"'\''"#))/.build' ]
              then echo present; else echo held; fi; } > '\(record.path)'
            """.write(to: open, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: open.path)

        let report = BundleCommand.report(
            for: app, package: sketch, note: parent.appendingPathComponent("How to open Bund.txt"),
            signedAs: nil)
        let line = try #require(
            report.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("mv ") })
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", line]
        process.currentDirectoryURL = parent
        process.environment = ["PATH": "\(tools.path):/usr/bin:/bin"]
        let result = try RunCommand.capture(process, capturing: true, errors: .inherit)

        #expect(result.status == 0, "確かめ方の行が通らない: \(line)")
        // `open` の時点でスケッチの .build は退避されていて、開いたのは束ねた .app
        #expect(
            try String(contentsOf: record, encoding: .utf8) == "\(app.path)\nheld\n",
            "打った行: \(line)")
        // 終わった後は戻っている
        #expect(FileManager.default.fileExists(atPath: build.appendingPathComponent("marker").path))
        #expect(
            !FileManager.default.fileExists(
                atPath: sketch.appendingPathComponent(".build-held").path))
    }

    /// 文面の固定。スケッチの `.build` と `.app` を、引用した絶対パスで名指しする。
    @Test("確かめ方の行は、スケッチの .build と .app を引用した絶対パスで名指しする")
    func theCheckNamesTheQuotedPlaces() {
        let report = BundleCommand.report(
            for: URL(fileURLWithPath: "/work/bund with space/bundle/Bund.app"),
            package: URL(fileURLWithPath: "/work/bund with space", isDirectory: true),
            note: URL(fileURLWithPath: "/work/bund with space/bundle/How to open Bund.txt"),
            signedAs: nil)
        #expect(
            report.contains(
                "  mv '/work/bund with space/.build' '/work/bund with space/.build-held'"
                    + " && open '/work/bund with space/bundle/Bund.app'"
                    + " ; mv '/work/bund with space/.build-held' '/work/bund with space/.build'\n"))
    }

    /// 受け取った側の往復は消せない。消せない代わりに、説明を**送り手の記憶から外す** —
    /// 紙が作品と一緒に運べる形になっていることを見る。
    @Test("開き方の紙が、作品名と踏む手順を持つ")
    func theOpeningNoteCarriesTheSteps() {
        let identity = AppIdentity(
            name: "Grain", identifier: "org.example.grain", version: "0.1.0")
        #expect(BundleCommand.noteFileName(for: identity) == "How to open Grain.txt")

        let note = BundleCommand.openingNote(for: identity)
        #expect(note.contains("Grain.app"))
        #expect(note.contains("Privacy & Security"))
        #expect(note.contains("Open Anyway"))
    }

    /// README は紙の名前を利用者に約束している。**名前は実関数から引く** — 検査の側に
    /// 写しを持つと、実装と README と検査の 3 か所が別々に古くなる ([#2488])。`<name>` は
    /// README が作品名の場所に書く綴りで、`name` に入れて求めた名前がそのまま載る。
    ///
    /// [#2488]: https://github.com/mokume-metal/mokume/issues/2488
    @Test("README が書く開き方の紙の名前は、実際に作る名前と同じ")
    func theReadmeNamesTheOpeningNoteTheWayItIsWritten() throws {
        let readme = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // MokumeCLITests
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // リポジトリ直下
                .appendingPathComponent("README.md"),
            encoding: .utf8)
        let placeholder = AppIdentity(
            name: "<name>", identifier: "org.example.grain", version: "0.1.0")
        let fileName = BundleCommand.noteFileName(for: placeholder)
        #expect(
            readme.contains("`\(fileName)`"),
            "README が開き方の紙を `\(fileName)` と書いていない (実際に作る名前と食い違っている)")
    }

    /// README は `name` の長さの上限も利用者に約束している (#2501)。**数は実装の上限から引く** —
    /// 紙の名前と同じく、写しを持つと上限を動かした日に README だけが古くなる。
    @Test("README が書く name の長さの上限は、実際の上限と同じ")
    func theReadmeStatesTheNameLimitTheWayItIsChecked() throws {
        let readme = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // MokumeCLITests
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // リポジトリ直下
                .appendingPathComponent("README.md"),
            encoding: .utf8)
        let phrase = "長さは \(AppIdentity.maximumNameLength) まで"
        #expect(
            readme.contains(phrase),
            "README が name の長さの上限を「\(phrase)」と書いていない (実際の上限と食い違っている)")
    }

    /// 手順を報せに書くと、読んだ送り手が伝え直すことになる。名指しなら物が動く。
    @Test("束ねた後の報せが、開き方の紙を名指しして一緒に送るよう言う")
    func theReportPointsAtTheOpeningNote() {
        let report = BundleCommand.report(
            for: URL(fileURLWithPath: "/tmp/Demo.app"),
            package: URL(fileURLWithPath: "/tmp/demo", isDirectory: true),
            note: URL(fileURLWithPath: "/tmp/How to open Demo.txt"), signedAs: nil)
        #expect(report.contains("/tmp/How to open Demo.txt"))
        #expect(report.contains("Send it along with the work"))
    }

    /// 名前は**持っている人の環境の性質**なので、環境から受け取る。
    @Test("署名の名前は環境から取り、空白だけなら無いものとして扱う")
    func theSigningIdentityComesFromTheEnvironment() {
        #expect(BundleCommand.signIdentity(environment: [:]) == nil)
        #expect(BundleCommand.signIdentity(environment: [BundleCommand.signIdentityKey: "  "]) == nil)
        #expect(
            BundleCommand.signIdentity(
                environment: [BundleCommand.signIdentityKey: " Developer ID Application: X "])
                == "Developer ID Application: X")
    }

    /// 名前を与えたときだけ、公証の前提 (強化されたランタイム・タイムスタンプ) を当てる。
    /// **後から足せない** — 足すには署名し直しになる。
    @Test("名前が無ければ ad-hoc、あれば公証に出せる形で署名する")
    func theSignatureFollowsTheGivenName() {
        let app = URL(fileURLWithPath: "/tmp/Demo.app")
        #expect(
            BundleCommand.signArguments(for: app, as: nil)
                == ["codesign", "--force", "--sign", "-", "/tmp/Demo.app"])

        let named = BundleCommand.signArguments(for: app, as: "Developer ID Application: X")
        #expect(named.contains("Developer ID Application: X"))
        #expect(named.contains("--options") && named.contains("runtime"))
        #expect(named.contains("--timestamp"))
    }

    /// 強化されたランタイムの下では、entitlement が無いとダイアログも出ずに拒否される。
    @Test("名前のある署名には、entitlement の plist を添える")
    func theNamedSignatureCarriesTheEntitlements() {
        let app = URL(fileURLWithPath: "/tmp/Demo.app")
        let file = URL(fileURLWithPath: "/tmp/entitlements.plist")

        let named = BundleCommand.signArguments(
            for: app, as: "Developer ID Application: X", entitlements: file)
        let index = named.firstIndex(of: "--entitlements")
        #expect(index != nil)
        #expect(index.map { named[named.index(after: $0)] } == "/tmp/entitlements.plist")
        #expect(named.contains("runtime"))

        // 渡さなければ、これまでと同じ引数のまま
        #expect(
            BundleCommand.signArguments(for: app, as: "Developer ID Application: X")
                == BundleCommand.signArguments(
                    for: app, as: "Developer ID Application: X", entitlements: nil))
        #expect(
            !BundleCommand.signArguments(for: app, as: "Developer ID Application: X")
                .contains("--entitlements"))
    }

    /// 名前が無い署名は強化されたランタイムを当てないので、要らない。
    @Test("名前の無い署名には、entitlement を添えない")
    func theAdHocSignatureCarriesNoEntitlements() {
        let app = URL(fileURLWithPath: "/tmp/Demo.app")
        let file = URL(fileURLWithPath: "/tmp/entitlements.plist")
        #expect(
            BundleCommand.signArguments(for: app, as: nil, entitlements: file)
                == ["codesign", "--force", "--sign", "-", "/tmp/Demo.app"])
    }

    @Test("entitlement は、codesign が読める plist として書き出される")
    func entitlementsAreWrittenAsAPropertyList() throws {
        let file = try BundleCommand.writeEntitlements([
            "com.apple.security.device.camera": true,
            "com.apple.security.device.audio-input": true,
        ])
        defer { try? FileManager.default.removeItem(at: file) }

        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: file), format: nil)
        #expect(
            plist as? [String: Bool] == [
                "com.apple.security.device.camera": true,
                "com.apple.security.device.audio-input": true,
            ])
    }

    // MARK: - 署名 (本物の codesign)

    /// 本物の `codesign` に通して、埋め込みを読み戻す。
    ///
    /// **本物の証明書はこの環境に無い**ので、名前の代わりに `-` (ad-hoc) を与える。
    /// `sign` は名前の有無だけで強化されたランタイムと entitlement を足すので、通る経路は
    /// 同じになる (`--timestamp` は ad-hoc では使われず、網が無くても通る)。
    /// **主実行ファイルは本物の Mach-O にする** — スクリプトには entitlement が埋まらない。
    @Test("名前のある署名で、entitlement が署名に埋まり、強化されたランタイムが当たる")
    func entitlementsLandInTheSignature() throws {
        let app = try makeSignedApplication(
            identity: "-", entitlements: [
                "com.apple.security.device.camera": true,
                "com.apple.security.device.audio-input": true,
            ])
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        let embedded = try readEntitlements(of: app)
        #expect(
            embedded == [
                "com.apple.security.device.camera": true,
                "com.apple.security.device.audio-input": true,
            ])
        let description = try codesignDescription(of: app)
        #expect(description.contains("runtime"))
    }

    @Test("名前の無い署名には、entitlement が埋まらない")
    func noEntitlementsInTheAdHocSignature() throws {
        let app = try makeSignedApplication(
            identity: nil, entitlements: ["com.apple.security.device.camera": true])
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        #expect(try readEntitlements(of: app).isEmpty)
        let description = try codesignDescription(of: app)
        #expect(!description.contains("runtime"))
    }

    @Test("名前のある署名でも、文言が無ければ entitlement は無い")
    func noEntitlementsWithoutTexts() throws {
        let app = try makeSignedApplication(identity: "-", entitlements: [:])
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        #expect(try readEntitlements(of: app).isEmpty)
    }

    @Test("署名のために書いた一時の plist は、署名の後に残らない")
    func theEntitlementsFileIsRemoved() throws {
        let scratch = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let app = try makeSignedApplication(
            identity: "-", entitlements: ["com.apple.security.device.camera": true],
            scratch: scratch)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }

    /// **`codesign` が無いことを、署名の失敗と取り違えない** (#2483・#2575)。`env` 越しに起こす
    /// ので、`PATH` に無い回は `env` が 127 で終わる。それを「Signing failed (exit code 127)」と
    /// 名乗ると、Xcode の道具を入れ直す方へ向かわず、署名の中身を疑わせる (#1157・#2314 の逆向き)。
    @Test("codesign が PATH に無ければ、署名の失敗ではなく codesign が無いと名乗る")
    func aMissingCodesignIsAMissingTool() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApplicationToSign(in: root)

        #expect(throws: CommandFailure.toolchainMissing("codesign")) {
            try BundleCommand.sign(app, as: nil, environment: ["PATH": "/nonexistent"])
        }
    }

    /// 裏側。`codesign` が起きて 0 以外で終わった回は、いままでどおり署名の失敗である。
    @Test("codesign が起きて失敗したときは、いままでどおり署名の失敗と名乗る")
    func aFailingCodesignIsStillASigningFailure() {
        let nowhere = URL(
            fileURLWithPath: "/nonexistent-\(UUID().uuidString)/Demo.app", isDirectory: true)
        let failure = #expect(throws: CommandFailure.self) {
            try BundleCommand.sign(nowhere, as: nil)
        }
        guard case .codesignFailed(let status) = failure else {
            Issue.record("署名の失敗と名乗らなかった: \(String(describing: failure))")
            return
        }
        #expect(status != 0 && status != 127)
    }

    /// **合図で落ちた `codesign` を、終了コードの形で名乗らない** ([#2315](https://github.com/mokume-metal/mokume/issues/2315))。
    /// `terminationStatus` を直に読むと SIGKILL の 9 が「Signing failed (exit code 9)」になり、
    /// `exit(9)` で終わった回と見分けがつかない。`PATH` の先に置いた偽の `codesign` で、自分で
    /// 終わる回と合図で落ちる回を作り、`sign` が名乗る数を見る。
    @Test("codesign が合図で落ちたら、128 + 番号で名乗る。自分で終わったら、終了コードのまま")
    func aSignalledCodesignIsNamedByShellStatus() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApplicationToSign(in: root)
        let tools = root.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let fake = tools.appendingPathComponent("codesign")
        try "#!/bin/sh\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let environment = ["PATH": "\(tools.path):/usr/bin:/bin"]

        for (script, status) in [
            ("exit 9", Int32(9)), ("kill -s KILL $$", 128 + SIGKILL), ("kill -s TRAP $$", 128 + SIGTRAP),
        ] {
            // 実行ビットを保つため、同じファイルへ書き足す (置き換えない)
            try "#!/bin/sh\n\(script)\n".write(to: fake, atomically: false, encoding: .utf8)
            #expect(throws: CommandFailure.codesignFailed(status: status), "\(script)") {
                try BundleCommand.sign(app, as: nil, environment: environment)
            }
        }
    }

    /// **道具立てが答えなかった回を、宣言の不備と名乗らない** (#2483)。`dump-package` は
    /// 宣言を道具立てが読めない (`Package.swift` が壊れている) と 0 以外で終わり、`bundle` は
    /// それを「Package.swift が実行ファイルを宣言していない」と名乗っていた。打ったコマンドと
    /// 終了コードを名乗る形 (`binPath` の #2316 と同じ) にする。
    @Test("宣言を道具立てが読めなかった回は、宣言に実行ファイルが無いとは名乗らない")
    func anUnreadableManifestIsTheToolchainsFailureNotAMissingProduct() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try "this is not a manifest\n".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try #"{"name": "Demo", "identifier": "org.example.demo", "version": "0.1.0"}"#.write(
            to: root.appendingPathComponent(AppIdentity.fileName), atomically: true, encoding: .utf8)

        let thrown = #expect(throws: CommandFailure.self) {
            try BundleCommand.run([root.path])
        }
        guard let failure = thrown, case .toolchainFailed(let command, let status) = failure else {
            Issue.record("道具立ての失敗と名乗らなかった: \(String(describing: thrown))")
            return
        }
        #expect(command == "swift package dump-package")
        #expect(status != 0)
        #expect(!failure.message.contains("declares an executable"))
    }

    /// 署名の前まで組んだ包み (本物の Mach-O を主実行ファイルにする)。
    private func makeApplicationToSign(in root: URL) throws -> URL {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("demo")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        return try BundleCommand.assemble(
            executable: executable, identity: identity, minimumSystemVersion: "26.0",
            into: root.appendingPathComponent("out", isDirectory: true))
    }

    /// 本物の Mach-O を主実行ファイルにした包みを組んで、`sign` を通す。
    private func makeSignedApplication(
        identity signature: String?, entitlements: [String: Bool],
        scratch: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let root = try makeWorkspace()
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("demo")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)

        let app = try BundleCommand.assemble(
            executable: executable, identity: identity, minimumSystemVersion: "26.0",
            into: root.appendingPathComponent("out", isDirectory: true))
        try BundleCommand.sign(app, as: signature, entitlements: entitlements, scratch: scratch)
        return app
    }

    /// 署名に埋まっている entitlement。無ければ空。
    private func readEntitlements(of app: URL) throws -> [String: Bool] {
        let output = try run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", app.path])
        guard !output.stdout.isEmpty else { return [:] }
        let plist = try PropertyListSerialization.propertyList(from: output.stdout, format: nil)
        return try #require(plist as? [String: Bool])
    }

    /// 署名の説明 (印の並びに `runtime` が入っているかを見るのに使う)。
    private func codesignDescription(of app: URL) throws -> String {
        let output = try run("/usr/bin/codesign", ["-d", "--verbose=2", app.path])
        return String(decoding: output.stderr, as: UTF8.self)
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> (stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // 出力を先に読み切ってから待つ (溢れて止まらないように)
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (stdout, stderr)
    }

    // MARK: - 許可の文言が無いまま束ねない

    /// 止まるのは**ビルドの前**でなければならない — 後だと、待たされた末に言われる。
    /// 中身の無い `Package.swift` なので、ビルドへ進んでいればこの失敗にはならない。
    @Test("カメラを使うのに文言が無ければ、ビルドへ進まずに止まる")
    func bundlingStopsBeforeBuildingWithoutTheText() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try "// 中身の無い宣言\n".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try AppIdentity.example.write(
            to: root.appendingPathComponent(AppIdentity.fileName), atomically: true,
            encoding: .utf8)
        let sources = root.appendingPathComponent("Sources/mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "let camera = try? createCapture()\n".write(
            to: sources.appendingPathComponent("Mirror.swift"), atomically: true, encoding: .utf8)

        #expect(
            throws: CommandFailure.cameraUsageMissing(
                path: root.appendingPathComponent(AppIdentity.fileName).path,
                files: ["Sources/mirror/Mirror.swift"])
        ) {
            try BundleCommand.run([root.path])
        }
    }

    /// **name に `/` があれば、組み立ての前に止まる** ([#2309](https://github.com/mokume-metal/mokume/issues/2309))。
    /// 中身の無い `Package.swift` なので、名乗りの段を越えていれば `dump-package` で別の失敗
    /// (`toolchainFailed`) になる。`../victim` は 2 回打っても、隣の `victim.app` を消さない。
    @Test("name に / があれば、ビルドへ進まずに止まり、bundle/ の下にも隣にも触れない")
    func bundlingStopsBeforeBuildingWithASlashInTheName() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try "// 中身の無い宣言\n".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let identityFile = root.appendingPathComponent(AppIdentity.fileName)
        let victim = root.appendingPathComponent("victim.app", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        let keep = victim.appendingPathComponent("keep.txt")
        try "keep".write(to: keep, atomically: true, encoding: .utf8)

        for name in ["AC/DC", "../victim"] {
            try #"{"name": "\#(name)", "identifier": "org.example.bund", "version": "0.1.0"}"#
                .write(to: identityFile, atomically: true, encoding: .utf8)
            for _ in 0..<2 {
                #expect(
                    throws: CommandFailure.identityNameUnusable(path: identityFile.path, name: name)
                ) {
                    try BundleCommand.run([root.path])
                }
            }
            #expect(
                !FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(BundleCommand.defaultOutputDirectory).path),
                "\(name) で bundle/ を作った")
            #expect(FileManager.default.fileExists(atPath: keep.path), "\(name) で隣の victim.app を消した")
        }
    }

    /// **name がファイル名に収まらない長さなら、組み立ての前に止まる** ([#2501](https://github.com/mokume-metal/mokume/issues/2501))。
    /// 直す前は release のビルドと署名の後に紙が書けずに止まり、署名済みの `.app` が `bundle/` に
    /// 残っていた。中身の無い `Package.swift` なので、名乗りの段を越えていれば `dump-package` で
    /// 別の失敗になる (上の `/` の検査と同じ形)。
    @Test("name がファイル名に収まらない長さなら、ビルドへ進まずに止まり、bundle/ を作らない")
    func bundlingStopsBeforeBuildingWithATooLongName() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try "// 中身の無い宣言\n".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let identityFile = root.appendingPathComponent(AppIdentity.fileName)

        for given in [RepeatedName("a", 240), RepeatedName("木", 240), RepeatedName("a", 245)] {
            try #"{"name": "\#(given.name)", "identifier": "org.example.bund", "version": "0.1.0"}"#
                .write(to: identityFile, atomically: true, encoding: .utf8)
            #expect(
                throws: CommandFailure.identityNameTooLong(
                    path: identityFile.path, name: given.name, length: given.units)
            ) {
                try BundleCommand.run([root.path])
            }
            #expect(
                !FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(BundleCommand.defaultOutputDirectory).path),
                "\(given.testDescription) で bundle/ を作った")
        }
    }

    /// 名乗らないと「署名したのだから開くはず」と読まれる。往復はまだ残る。
    @Test("報せが、どちらの段で署名したかを名乗る")
    func theReportNamesTheSigningTier() {
        let app = URL(fileURLWithPath: "/tmp/Demo.app")
        let package = URL(fileURLWithPath: "/tmp/demo", isDirectory: true)
        let note = URL(fileURLWithPath: "/tmp/Demo を開くには.txt")

        #expect(
            BundleCommand.report(for: app, package: package, note: note, signedAs: nil)
                .contains("ad-hoc"))

        let named = BundleCommand.report(
            for: app, package: package, note: note, signedAs: "Developer ID Application: X")
        #expect(named.contains("Developer ID Application: X"))
        #expect(named.contains("has not been notarized yet"))
    }

    /// **場所は走らせた場所から絶対パスに解く** (#2323)。相対の `URL` のまま
    /// `swift package dump-package` の作業ディレクトリへ渡ると、先頭の `..` が落ちる (#2314)。
    @Test("スケッチの場所は、走らせた場所から絶対パスに解く")
    func theSketchIsResolvedFromWhereItWasTyped() throws {
        let typedFrom = URL(fileURLWithPath: "/work/plain", isDirectory: true)
        for (given, expected) in [("../bund", "/work/bund"), ("..", "/work"), ("bund", "/work/plain/bund")] {
            let directory = try BundleCommand.parse([given]).directory(from: typedFrom)
            #expect(directory.baseURL == nil)
            #expect(directory.path == expected)
        }
        // 渡さなければ走らせた場所
        #expect(
            try BundleCommand.parse([]).directory().standardizedFileURL.path
                == URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .standardizedFileURL.path)
    }

    /// **置き場も、走らせた場所から絶対パスに解く** (#2323 の反証)。場所と同じ規則で、
    /// help もそう言う。
    @Test("置き場の相対パスは、走らせた場所から絶対パスに解く")
    func theOutputDirectoryIsResolvedFromWhereItWasTyped() throws {
        let typedFrom = URL(fileURLWithPath: "/work/plain", isDirectory: true)
        let out = try #require(
            try BundleCommand.parse(["../bund", "--out", "../dist"]).outDirectory(from: typedFrom))
        #expect(out.baseURL == nil)
        #expect(out.path == "/work/dist")
        #expect(try BundleCommand.parse(["../bund"]).outDirectory(from: typedFrom) == nil)

        let entry = try #require(Command.Verb.bundle.usageEntry)
        let help = (entry.signature + " " + entry.description).replacingOccurrences(of: "\n", with: " ")
        #expect(help.contains("Relative paths start from where you run this"))
    }

    @Test("置き場を渡せる")
    func theOutputDirectoryCanBeGiven() throws {
        #expect(try BundleCommand.parse(["sketch", "--out", "dist"]).out == "dist")
        #expect(try BundleCommand.parse([]).out == nil)
        #expect(throws: (any Error).self) { try BundleCommand.parse(["--out"]) }
        #expect(throws: (any Error).self) { try BundleCommand.parse(["a", "b"]) }
    }

    /// 書けなかった事情は、言語の設定に左右されない OS の文面で名乗る (#2839)。置き換えて書く紙は、
    /// 行き先がディレクトリだと下の失敗が ENOENT になるが、`Is a directory` と名乗る。
    @Test("書けなかった事情は OS の文面で名乗り、ディレクトリへ置き換えて書く失敗は Is a directory")
    func unwritableReasonsAreTheOSWords() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Demo.app")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(BundleCommand.noteFileName(for: identity)),
            withIntermediateDirectories: false)
        do {
            _ = try BundleCommand.writeOpeningNote(for: identity, beside: app)
            Issue.record("ディレクトリへ紙を書けてしまった")
        } catch {
            guard case .cannotCreate(_, let reason) = error else {
                Issue.record("cannotCreate で投げていない: \(error)")
                return
            }
            #expect(reason == String(cString: strerror(EISDIR)))
        }
        let missing = root.appendingPathComponent("no-such-folder")
        do {
            _ = try BundleCommand.writeEntitlements(["com.apple.security.app-sandbox": false], in: missing)
            Issue.record("無い置き場へ書けてしまった")
        } catch {
            guard case .cannotCreate(_, let reason) = error else {
                Issue.record("cannotCreate で投げていない: \(error)")
                return
            }
            #expect(reason == String(cString: strerror(ENOENT)))
        }
    }
}
