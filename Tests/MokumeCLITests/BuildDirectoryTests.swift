// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import mokume

@testable import MokumeCLI

@Suite("ビルドの置き場")
struct BuildDirectoryTests {
    // MARK: - 根

    @Test("根は、環境が与えなければホームの下のキャッシュ")
    func theRootDefaultsToTheCacheUnderHome() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let root = BuildDirectory.root(environment: [:], home: home)
        #expect(root.path == "/Users/example/Library/Caches/mokume/build")
    }

    @Test("環境が与えた根は、~ も相対も絶対にして使う")
    func theGivenRootIsExpanded() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let given = BuildDirectory.root(
            environment: [BuildDirectory.environmentKey: "/tmp/store"], home: home)
        #expect(given.path == "/tmp/store")
        // **空白だけは「書かれていない」として扱う。** 空の環境変数で共有が黙って
        // ルートへ落ちるのを避ける
        let blank = BuildDirectory.root(
            environment: [BuildDirectory.environmentKey: "  "], home: home)
        #expect(blank.path == "/Users/example/Library/Caches/mokume/build")
    }

    // MARK: - 鍵

    /// `swift --version` の 1 行目の形。
    static let toolchain =
        "swift-driver version: 1.148.6 Apple Swift version 6.3.3 "
        + "(swiftlang-6.3.3.1.3 clang-2100.1.1.101)"

    static func manifest(local: Bool) -> SwiftPM.Package {
        let dependency = local ? #"{"fileSystem":[{"identity":"mokume"}]}"# : #"{"sourceControl":[{"identity":"mokume"}]}"#
        return try! #require(
            SwiftPM.package(
                inDumpOf: """
                    {"name":"hello",
                     "products":[{"name":"hello","type":{"executable":null}}],
                     "targets":[{"name":"hello"}],
                     "platforms":[],
                     "dependencies":[\(dependency)]}
                    """))
    }

    @Test("版で固定されていれば、道具立てと版で置き場を分ける")
    func aVersionPinKeysTheStore() throws {
        let shareability = BuildDirectory.shareability(
            package: Self.manifest(local: false), pin: .version("0.7.1"),
            toolchain: Self.toolchain)
        #expect(shareability == .shareable("swiftlang-6.3.3.1.3/0.7.1"))
    }

    /// **枝や改訂で固定したものを、版と混ぜない。** 混ぜると互いを作り直させ続け、
    /// 増分ビルドが 1.6 秒から 8 秒へ落ちる (#1055 の実測)。
    @Test("改訂で固定されていれば、版とは別の名前になる")
    func aRevisionPinIsKeptApartFromVersions() throws {
        let shareability = BuildDirectory.shareability(
            package: Self.manifest(local: false),
            pin: .revision("b8f9c7652cd8e23a7b45f97bc90f37739e072884"),
            toolchain: Self.toolchain)
        #expect(shareability == .shareable("swiftlang-6.3.3.1.3/rev-b8f9c7652cd8"))
    }

    @Test("まだ固定が読めなければ、共有しない")
    func anUnresolvedPackageIsNotShared() throws {
        let shareability = BuildDirectory.shareability(
            package: Self.manifest(local: false), pin: nil, toolchain: Self.toolchain)
        #expect(shareability == .unshared(.unresolved))
    }

    /// **mokume 自身の開発は、ソースからビルドする。** パスで指した先は版を名乗らない
    /// まま中身が動くので、同じ鍵で別物になる。
    @Test("パスで指した依存があれば、共有しない")
    func aPathDependencyIsNotShared() throws {
        let shareability = BuildDirectory.shareability(
            package: Self.manifest(local: true), pin: .version("0.7.1"),
            toolchain: Self.toolchain)
        #expect(shareability == .unshared(.localDependency))
    }

    /// **でっち上げて共有しない。** 置き場の 55% は道具立ての産物で、食い違うと
    /// 作り直しではなく硬い失敗 (`missing required module`) になる。
    @Test("道具立ての版が読めなければ、共有しない")
    func anUnknownToolchainIsNotShared() throws {
        #expect(
            BuildDirectory.shareability(
                package: Self.manifest(local: false), pin: .version("0.7.1"), toolchain: nil)
                == .unshared(.unknownToolchain))
        #expect(
            BuildDirectory.shareability(
                package: Self.manifest(local: false), pin: .version("0.7.1"),
                toolchain: "何かよく分からない出力") == .unshared(.unknownToolchain))
    }

    @Test("道具立ての語は、版と突き合わせられる形で取り出す")
    func theToolchainSegmentIsReadable() {
        #expect(BuildDirectory.toolchainSegment(from: Self.toolchain) == "swiftlang-6.3.3.1.3")
        #expect(BuildDirectory.toolchainSegment(from: nil) == nil)
        #expect(BuildDirectory.toolchainSegment(from: "swiftlang-") == nil, "語が空なら諦める")
    }

    // MARK: - 先客

    /// **ひな形は package = product = target を同じ名前にする**ので、この集合を
    /// 押さえれば実行ファイル・中間物・資材の包みのすべてを覆える。
    @Test("押さえる名前は、置き場で席が 1 つしか無いもの")
    func contestedNamesCoverEverySharedSlot() throws {
        let names = BuildDirectory.contestedNames(of: Self.manifest(local: false))
        #expect(names == ["hello"], "product 名と target 名が同じなら 1 つに畳む")
    }

    @Test("誰も使っていない名前は取れる")
    func afreeNameIsClaimed() throws {
        let store = try Self.directory()
        let package = try Self.directory()
        #expect(BuildDirectory.claim(["hello"], for: package, in: store) == .free)
        // 2 度目も自分のものとして取れる
        #expect(BuildDirectory.claim(["hello"], for: package, in: store) == .free)
    }

    @Test("別のパッケージが先に使っている名前は取れない")
    func aTakenNameIsRefused() throws {
        let store = try Self.directory()
        let first = try Self.directory()
        let second = try Self.directory()
        #expect(BuildDirectory.claim(["hello"], for: first, in: store) == .free)
        #expect(
            BuildDirectory.claim(["hello"], for: second, in: store)
                == .taken(by: BuildDirectory.ownerPath(of: first)))
    }

    /// **読めなかったことと、書かれていないことを同じ顔にしない。** 空の記録を
    /// 「未使用」と読むと、書きかけを掴んだ側が先客を追い出す。
    @Test("読めない記録は、別人のものとして扱う")
    func anUnreadableClaimIsTreatedAsTaken() throws {
        let store = try Self.directory()
        let package = try Self.directory()
        let owners = BuildDirectory.ownersDirectory(in: store)
        try FileManager.default.createDirectory(at: owners, withIntermediateDirectories: true)
        try Data().write(to: owners.appendingPathComponent("hello"))
        #expect(
            BuildDirectory.claim(["hello"], for: package, in: store)
                == .taken(by: BuildDirectory.unreadableOwner))
    }

    /// 上と同じ倒し方を、**読み取り自体が失敗する**形でも見る (空の記録とは別の分岐)。
    @Test("記録が読み取れない形でも、別人のものとして扱う")
    func aClaimThatCannotBeReadAtAllIsTreatedAsTaken() throws {
        let store = try Self.directory()
        let package = try Self.directory()
        // ファイルの位置にディレクトリを置くと、作るのも読むのも失敗する
        try FileManager.default.createDirectory(
            at: BuildDirectory.ownersDirectory(in: store).appendingPathComponent("hello"),
            withIntermediateDirectories: true)
        #expect(
            BuildDirectory.claim(["hello"], for: package, in: store)
                == .taken(by: BuildDirectory.unreadableOwner))
    }

    /// 作って消したスケッチの名前が、共有を永久に塞がないようにする。
    @Test("先客のパッケージが消えていれば、名前を取り直せる")
    func aStaleClaimIsReleased() throws {
        let store = try Self.directory()
        let gone = try Self.directory()
        let package = try Self.directory()
        #expect(BuildDirectory.claim(["hello"], for: gone, in: store) == .free)
        try FileManager.default.removeItem(at: gone)
        #expect(BuildDirectory.claim(["hello"], for: package, in: store) == .free)
        // 取り直した後は、こちらが持ち主として記録されている
        let owner = try String(
            contentsOf: BuildDirectory.ownersDirectory(in: store)
                .appendingPathComponent("hello"), encoding: .utf8)
        #expect(
            owner.trimmingCharacters(in: .whitespacesAndNewlines)
                == BuildDirectory.ownerPath(of: package))
    }

    @Test("押さえる名前が 1 つでも取れなければ、共有しない")
    func oneTakenNameIsEnoughToRefuse() throws {
        let store = try Self.directory()
        let first = try Self.directory()
        let second = try Self.directory()
        #expect(BuildDirectory.claim(["b"], for: first, in: store) == .free)
        #expect(BuildDirectory.claim(["a", "b"], for: second, in: store) != .free)
    }

    // MARK: - 並べるだけの経路

    /// **読むだけの経路にプロセスを払わせない。** 道具立ての版を推さず、根を 1 段
    /// 列挙するので、道具立てを入れ替えた後でも前の置き場を見つけられる。
    @Test("置き場の候補は、根に在る道具立ての分だけ並ぶ")
    func plausibleDirectoriesEnumerateTheRoot() {
        let root = URL(fileURLWithPath: "/store", isDirectory: true)
        let package = URL(fileURLWithPath: "/sketch", isDirectory: true)
        let listed = BuildDirectory.plausibleDirectories(
            for: package, root: root, pin: .version("0.7.1"),
            listing: { _ in ["swiftlang-6.3.3.1.3", "swiftlang-6.2.0", "resolve", "owners"] })
        #expect(
            listed.map(\.path) == [
                "/store/swiftlang-6.2.0/0.7.1",
                "/store/swiftlang-6.3.3.1.3/0.7.1",
                "/sketch/.build",
            ], "道具立ての語だけを拾い、最後はいつでもパッケージ直下へ落ちる")
    }

    @Test("固定が読めなければ、候補はパッケージ直下だけ")
    func withoutAPinOnlyThePackageIsPlausible() {
        let listed = BuildDirectory.plausibleDirectories(
            for: URL(fileURLWithPath: "/sketch", isDirectory: true),
            root: URL(fileURLWithPath: "/store", isDirectory: true), pin: nil,
            listing: { _ in ["swiftlang-6.3.3.1.3"] })
        #expect(listed.map(\.path) == ["/sketch/.build"])
    }

    /// **共有の置き場が在ることは、このスケッチがそこを使っている証拠ではない。**
    /// 同じ版に依存する別のスケッチが作ったのかもしれず、先客に譲ってパッケージ直下へ
    /// 落ちた側にそれを名乗ると、切り分けの口が嘘をつく (実際に嘘をついた)。
    @Test("実際に建てている置き場は、記録から決める")
    func theSettledDirectoryComesFromTheRecord() throws {
        let root = try Self.directory()
        let store = root.appendingPathComponent("swiftlang-1/0.7.1", isDirectory: true)
        let mine = try Self.directory()
        let other = try Self.directory()
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: mine.appendingPathComponent(".build"), withIntermediateDirectories: true)

        // 先客が名前を押さえている = 共有の置き場は在るが、こちらのものではない
        #expect(BuildDirectory.claim(["hello"], for: other, in: store) == .free)
        #expect(
            BuildDirectory.settled(
                for: mine, root: root, pin: .version("0.7.1"),
                listing: { _ in ["swiftlang-1"] })
                == mine.appendingPathComponent(".build", isDirectory: true),
            "他人が使っている共有の置き場を、自分の跡として名乗っている")

        // 自分が押さえていれば、共有の置き場を名乗る
        #expect(BuildDirectory.claim(["kumo"], for: mine, in: store) == .free)
        #expect(
            BuildDirectory.settled(
                for: mine, root: root, pin: .version("0.7.1"),
                listing: { _ in ["swiftlang-1"] }) == store)
    }

    @Test("まだ 1 度も建てていなければ、跡は無い")
    func nothingBuiltMeansNoDirectory() throws {
        let root = try Self.directory()
        let package = try Self.directory()
        #expect(
            BuildDirectory.settled(
                for: package, root: root, pin: .version("0.7.1"), listing: { _ in [] }) == nil)
    }

    // MARK: - 道具立てへ渡す形

    @Test("パッケージ直下へ落ちたときは、置き場の指定を渡さない")
    func theInPackagePlacePassesNoArgument() {
        #expect(BuildDirectory.Place.inPackage(.localDependency).arguments.isEmpty)
    }

    @Test("外の置き場は、道具立ての綴りで渡す")
    func anOutsidePlaceIsPassedToTheToolchain() {
        let place = BuildDirectory.Place.outside(
            URL(fileURLWithPath: "/store/swiftlang-1/0.7.1", isDirectory: true), given: false)
        #expect(place.arguments == ["--scratch-path", "/store/swiftlang-1/0.7.1"])
    }

    /// **`build` と `--show-bin-path` に、同じ置き場と構成が渡る。** 片方だけに渡すと
    /// 名乗ったものと実際に起動するものが食い違う (#680 が構成で踏んだ形)。
    @Test("作るときの引数は、構成と置き場を必ず両方持つ")
    func theArgumentsCarryBothTheConfigurationAndThePlace() {
        let context = BuildContext(
            configuration: "release",
            place: .outside(URL(fileURLWithPath: "/store", isDirectory: true), given: false),
            product: "hello")
        #expect(context.arguments == ["-c", "release", "--scratch-path", "/store"])
    }

    // MARK: - 名乗り

    /// **共有の常道では黙る。** 言うのは「そうしなかったとき」だけである。
    @Test("共有できたときは何も言わず、落ちたときだけ言う")
    func onlyTheFallbacksAreAnnounced() {
        #expect(
            BuildDirectory.Place.outside(
                URL(fileURLWithPath: "/store", isDirectory: true), given: false).notice == nil)
        // 開発の常道 (パスで指した依存) と、束ねるときも黙る
        #expect(BuildDirectory.Place.inPackage(.localDependency).notice == nil)
        #expect(BuildDirectory.Place.inPackage(.packaging).notice == nil)
        // 先客に譲ったことは必ず名乗る — 黙って別の置き場へ落ちない
        #expect(
            BuildDirectory.Place.inPackage(.nameTaken(by: "/other")).notice?.contains("/other")
                == true)
    }

    // MARK: -

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// 置き場を決める経路そのもの (宣言と固定と道具立てを実際に読む)。
///
/// **ビルドはしない。** 見たいのは「同名のスケッチが同じ場所を指さないこと」で、
/// `--show-bin-path` は建てずに答える — [#1055] が再現した壊れ方は、まさに 2 つの
/// パッケージから引いた bin path が同じ場所を返すことだった。
///
/// [#1055]: https://github.com/mokume-metal/mokume/issues/1055
@Suite("置き場を決める")
struct BuildPlacementTests {
    /// 同じ名前のスケッチを 2 つ作る (どちらも product `hello`)。
    ///
    /// 依存は取ってきた形にし、固定は手で書く — **ネットワークにも実際のビルドにも
    /// 依らせない**。決めるのに要るのは宣言と固定と道具立ての 3 つだけである。
    static func sketch(pinning version: String) throws -> URL {
        let root = try BuildDirectoryTests.directory()
        let sources = root.appendingPathComponent("Sources/hello", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
            // swift-tools-version: 6.2
            import PackageDescription
            let package = Package(
                name: "hello",
                products: [.executable(name: "hello", targets: ["hello"])],
                dependencies: [
                    .package(url: "https://github.com/mokume-metal/mokume.git", exact: "\(version)")
                ],
                targets: [.executableTarget(name: "hello", dependencies: [])]
            )
            """.write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "".write(
            to: sources.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try """
            {"originHash":"x","pins":[{"identity":"mokume","kind":"remoteSourceControl",
             "location":"https://github.com/mokume-metal/mokume.git",
             "state":{"revision":"abc123","version":"\(version)"}}],"version":3}
            """.write(
            to: root.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)
        return root
    }

    /// **同じ名前でも、指す場所が分かれる。** これが分かれていなかったとき、後から
    /// 建てたスケッチが先のものを上書きし、`--show-bin-path` は同じ場所を返していた。
    @Test("同名のスケッチ 2 本は、同じ出来上がりの場所を指さない")
    func twoSketchesOfTheSameNameDoNotShareTheirProduct() throws {
        let store = try BuildDirectoryTests.directory()
        let environment = [BuildDirectory.environmentKey: store.path]
        let first = try Self.sketch(pinning: "0.7.1")
        let second = try Self.sketch(pinning: "0.7.1")

        let a = try RunCommand.context(
            in: first, invocation: Invocation(place: first.path), environment: environment)
        let b = try RunCommand.context(
            in: second, invocation: Invocation(place: second.path), environment: environment)

        // 先に来たほうが共有の置き場を取り、名乗ることは無い (常道なので黙る)
        #expect(a.place.notice == nil)
        #expect(a.place != .inPackage(.nameTaken(by: BuildDirectory.ownerPath(of: second))))
        if case .outside(let url, given: false) = a.place {
            #expect(
                url.path.contains("\(store.lastPathComponent)/"), "共有の置き場は根の下にある")
            #expect(url.lastPathComponent == "0.7.1", "鍵は固定された版")
        } else {
            Issue.record("先に来たスケッチが共有の置き場を使っていない: \(a.place)")
        }

        // 後から来たほうは今までどおりパッケージ直下へ落ち、**そう名乗る**
        #expect(b.place == .inPackage(.nameTaken(by: BuildDirectory.ownerPath(of: first))))
        let notice = try #require(b.place.notice)
        #expect(notice.contains(first.path))

        // **決め手は、出来上がりの場所が違うこと。** 建てずに引ける
        let binA = try RunCommand.binPath(in: first, context: a)
        let binB = try RunCommand.binPath(in: second, context: b)
        #expect(binA != binB, "同名のスケッチが同じ場所へ実行ファイルを置こうとしている")
        // 一時ディレクトリは /var と /private/var のどちらの綴りでも現れるので、
        // 前置きではなく「そのパッケージの直下の .build か」で見る
        #expect(
            binB.path.contains("\(second.lastPathComponent)/.build/"),
            "落ちた先はそのパッケージの直下")
    }

    /// **違う版は同じ部屋に入れない。** 混ぜると互いを作り直させ続ける (1.6 秒 → 8 秒)。
    @Test("固定された版が違えば、別の置き場になる")
    func differentPinsGetDifferentStores() throws {
        let store = try BuildDirectoryTests.directory()
        let environment = [BuildDirectory.environmentKey: store.path]
        let older = try Self.sketch(pinning: "0.6.0")
        let newer = try Self.sketch(pinning: "0.7.1")

        let a = try RunCommand.context(
            in: older, invocation: Invocation(place: older.path), environment: environment)
        let b = try RunCommand.context(
            in: newer, invocation: Invocation(place: newer.path), environment: environment)
        // 名前は取り合うが (どちらも product `hello`)、鍵が違うので部屋も違う
        #expect(a.place != b.place)
        let binA = try RunCommand.binPath(in: older, context: a)
        let binB = try RunCommand.binPath(in: newer, context: b)
        #expect(binA != binB)
    }

    /// **明示されたら理由を確かめない。** 既定を変えたので、戻す口が要る。
    @Test("置き場を明示すれば、そこを使う")
    func anExplicitScratchPathWins() throws {
        let store = try BuildDirectoryTests.directory()
        let sketch = try Self.sketch(pinning: "0.7.1")
        let context = try RunCommand.context(
            in: sketch,
            invocation: Invocation(place: sketch.path, scratchPath: ".build"),
            environment: [BuildDirectory.environmentKey: store.path])
        #expect(
            context.place == .outside(
                sketch.appendingPathComponent(".build", isDirectory: true).standardizedFileURL,
                given: true))
        // 明示した人へ理由を説かない
        #expect(context.place.notice == nil)
    }

    // MARK: - 作り直しの結果の読み方

    /// **3 つの失敗を混ぜない。** 次の一手が違う。
    @Test("作り直しが通らなければ、作り直しの失敗として投げる")
    func aFailedBuildIsThrownAsSuch() {
        let context = BuildContext(
            configuration: nil, place: .inPackage(.localDependency), product: "hello")
        let result = RunCommand.Rebuilt(
            status: 2, output: "", executable: nil,
            binPath: URL(fileURLWithPath: "/bin", isDirectory: true))
        #expect(throws: CommandFailure.buildFailed(status: 2)) {
            try RunCommand.executable(
                from: result, context: context, in: URL(fileURLWithPath: "/sketch"))
        }
    }

    /// 置き場の計画が古いと、道具立ては「Build complete!」と言って何も作らない。
    /// **終了コードだけを見ていると、そこを成功として通してしまう。**
    @Test("通ったのに建っていなければ、建っていないと投げる")
    func aBuildThatProducedNothingIsThrown() {
        let context = BuildContext(
            configuration: nil, place: .inPackage(.localDependency), product: "hello")
        let result = RunCommand.Rebuilt(
            status: 0, output: "Build complete!", executable: nil,
            binPath: URL(fileURLWithPath: "/store/debug", isDirectory: true))
        #expect(throws: CommandFailure.productNotBuilt(product: "hello", path: "/store/debug")) {
            try RunCommand.executable(
                from: result, context: context, in: URL(fileURLWithPath: "/sketch"))
        }
    }

    @Test("走らせるものを決められなければ、宣言の失敗として投げる")
    func anUndeclaredProductIsThrownAsSuch() {
        let context = BuildContext(
            configuration: nil, place: .inPackage(.unreadableManifest), product: nil)
        let result = RunCommand.Rebuilt(
            status: 0, output: "", executable: nil,
            binPath: URL(fileURLWithPath: "/store/debug", isDirectory: true))
        #expect(throws: CommandFailure.noExecutable(path: "/sketch")) {
            try RunCommand.executable(
                from: result, context: context, in: URL(fileURLWithPath: "/sketch"))
        }
    }
}
