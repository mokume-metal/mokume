// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// ビルドの置き場。
///
/// ## なぜスケッチごとに持たないのか
///
/// スケッチ 1 本の置き場は **414MB / 22 秒**で、そのうちスケッチに固有なのは 14MB
/// (3.6%) だけである。残りはどのスケッチでも中身が同じ — 依存の複製とマクロ用の
/// prebuilt が 200MB、SDK のモジュールキャッシュが 79MB、mokume 本体のコンパイル結果が
/// 40MB。置き場を 1 つにすると 2 本目以降が **2.5 秒 / +14MB** で済む
/// ([#1055](https://github.com/mokume-metal/mokume/issues/1055) に実測)。
///
/// **部分だけ共有する口は無い。** `--cache-path` を別に与えても置き場は 393MB のまま
/// (キャッシュ側が持つのは圧縮された種で、置き場は展開後の写しを別に持つ)。内容で
/// 決まる = 取り違えの危険が無いものだけを寄せる、という安全な形は選べないので、
/// 置き場そのものを 1 つにするしかない。
///
/// ## 鍵で区切るのは必須である
///
/// 違う版の mokume に依存するスケッチを同じ置き場で往復させると、増分ビルドが 1.6 秒から
/// **8 秒**へ落ちる (互いを作り直させ続ける)。だから置き場は
/// `<toolchain>/<ライブラリの固定>` で分ける。**toolchain を鍵に入れる**のは、置き場の
/// 55% (モジュールキャッシュと prebuilt) が toolchain の産物で、食い違ったときの症状が
/// 「作り直し」ではなく硬い失敗 (`missing required module`) だからである。
///
/// ## 共有しないときは、今までの場所へ落ちる
///
/// 共有できない理由は 5 つあり (下記 ``Fallback``)、どれもパッケージ直下の `.build` へ
/// 落ちる — **専用の置き場を別に作らない。** 落ちた先が今までと同じなら、`rm -rf .build`
/// も切り分けの口も孤児を拾う道具も、作法を 1 つも増やさずに済む。
///
/// ## 判断は 1 回だけ行い、値として持ち回る
///
/// 置き場は**作り直しと実行ファイルの解決の両方**へ渡す。片方だけに渡すと、名乗った
/// ものと実際に起動するものが食い違う ([#680](https://github.com/mokume-metal/mokume/issues/680)
/// が構成で踏んだのと同じ形)。だから ``BuildContext`` に抱き合わせて、片方だけ渡せない
/// 形にしてある。
enum BuildDirectory {
    /// 根を外から与える環境変数。
    ///
    /// **``StartupReads`` には載せない。** あれは走らせたスケッチが起動の瞬間に読むものの
    /// 一覧で、これは道具がビルドを始める瞬間に読むものである (`MOKUME_SIGN_IDENTITY` と
    /// 同類)。載せると走らせる側の話に混ざる。
    static let environmentKey = "MOKUME_BUILD_DIR"

    /// 根の既定 (ホームからの相対)。
    static let defaultRootPath = "Library/Caches/mokume/build"

    /// 依存を解決するためだけの置き場の名前。
    ///
    /// **まだ固定が読めないスケッチの初回に要る。** 鍵はライブラリの固定から作るが、
    /// 固定は `swift package resolve` が `Package.resolved` を書くまで存在しない。推測して
    /// 後から直す形は採らない — 推測は道具が最新でないときに必ず外れ、外れた置き場が
    /// 414MB のまま掃除の当てなく残る。
    static let resolveSegment = "resolve"

    /// 先客を記録する場所の名前。
    static let ownersSegment = "owners"

    // MARK: - どこに建てるか

    /// 置き場の決まり方。
    enum Place: Equatable {
        /// パッケージ直下 (`.build`)。**道具立ての既定に任せる** = `--scratch-path` を渡さない。
        case inPackage(Fallback)
        /// パッケージの外。
        case outside(URL, given: Bool)

        /// 道具立てへ渡す引数。
        var arguments: [String] {
            switch self {
            case .inPackage: []
            case .outside(let url, _): ["--scratch-path", url.path]
            }
        }

        /// ビルドの置き場そのもの (`.build` を足す前の姿ではない)。
        ///
        /// `workspace-state.json` と `checkouts/` を読む側がここから引く。
        func directory(under package: URL) -> URL {
            switch self {
            case .inPackage: package.appendingPathComponent(".build", isDirectory: true)
            case .outside(let url, _): url
            }
        }

        /// 名乗る 1 行。**言うことが無ければ `nil`。**
        ///
        /// 共有の常道では黙る (毎回言えば、読まれるのをやめる)。言うのは**そうしなかった
        /// とき**だけである。
        var notice: String? {
            switch self {
            case .outside(_, given: true): nil
            case .outside: nil
            case .inPackage(let fallback): fallback.notice
            }
        }
    }

    /// 共有しなかった理由。
    enum Fallback: Equatable {
        /// パスで指した依存がある (mokume 自身の開発)。
        ///
        /// **共有できない。** 鍵はライブラリの固定から作るが、パスで指した先は版を
        /// 名乗らないまま中身が動くので、同じ鍵で別物になる。
        case localDependency
        /// まだ固定が読めない (解決に失敗した)。
        case unresolved
        /// パッケージの宣言が読めない。
        ///
        /// **断らない。** 宣言を壊した状態から直していく途中は、まさに見張っていてほしい
        /// 場面である — ここで止めると、直しても始まらない道具になる。
        case unreadableManifest
        /// toolchain の版が読めない。
        case unknownToolchain
        /// 同じ名前を別のパッケージが先に使っている。
        case nameTaken(by: String)
        /// 配るものを組んでいる。
        ///
        /// **共有しない。** 束ねる側は実行ファイルの隣に並んだ包みを全部入れる作りで
        /// (`BundleCommand.resourceBundles(besides:)` — 依存が持ち込む包みは宣言を辿っても
        /// 出てこないため)、共有の置き場には同じ鍵の全スケッチの包みが並ぶので、
        /// **他人の資材が配る包みへ入る。** release 構成は 1 回しか叩かないので、
        /// 共有して得るものも薄い。
        case packaging

        /// 名乗る 1 行。
        var notice: String? {
            switch self {
            // **開発の常道なので黙る。** パスで指すのは mokume 自身を触っている
            // ときで、その人は毎回これを読まされる立場にある。在処は切り分けの口が言う
            case .localDependency: nil
            // 束ねるときは常にこうなるので黙る (選択ではなく設計である)
            case .packaging: nil
            case .unreadableManifest:
                "パッケージの宣言が読めないので、置き場はこのパッケージの .build に置く"
            case .unresolved:
                "依存の版が読めないので、置き場はこのパッケージの .build に置く"
                    + " (共有すると版の違うものが混ざる)"
            case .unknownToolchain:
                "toolchain の版が読めないので、置き場はこのパッケージの .build に置く"
            case .nameTaken(let owner):
                "同じ名前のスケッチが共有の置き場を先に使っている (\(owner)) —"
                    + " このスケッチの置き場はこのパッケージの .build に置く"
            }
        }
    }

    // MARK: - 根と鍵

    /// 置き場の根。
    ///
    /// - Parameters:
    ///   - environment: 環境。`MOKUME_BUILD_DIR` があればそれを基準にする。
    ///   - home: ホームディレクトリ。**検査から渡せる形にしてある。**
    static func root(environment: [String: String], home: URL) -> URL {
        if let given = environment[environmentKey],
            !given.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let expanded = NSString(string: given).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        return home.appendingPathComponent(defaultRootPath, isDirectory: true).standardizedFileURL
    }

    /// 共有できるか。できるなら置き場の名前 (根からの相対) を返す。
    enum Shareability: Equatable {
        /// 共有できる。根からの相対の名前。
        case shareable(String)
        /// 共有できない。
        case unshared(Fallback)
    }

    /// 宣言・固定・toolchain から、共有できるかを決める。**純関数。**
    ///
    /// - Parameter package: 読めた宣言。**読めなかった場合はここへ来ない** — 走らせる
    ///   実行ファイルの名前も宣言から取るので、読めなければ置き場を選ぶより手前で失敗する。
    static func shareability(
        package: SwiftPM.Package, pin: DependencyVersion.Pin?, toolchain: String?
    ) -> Shareability {
        guard !package.hasFileSystemDependency else { return .unshared(.localDependency) }
        guard toolchainSegment(from: toolchain) != nil else { return .unshared(.unknownToolchain) }
        guard let name = storeName(pin: pin, toolchain: toolchain) else {
            return .unshared(.unresolved)
        }
        return .shareable(name)
    }

    /// 鍵から、共有の置き場の名前 (根からの相対) を作る。決められなければ `nil`。
    static func storeName(pin: DependencyVersion.Pin?, toolchain: String?) -> String? {
        guard let segment = toolchainSegment(from: toolchain), let key = keySegment(pin: pin)
        else { return nil }
        return "\(segment)/\(key)"
    }

    /// 固定を、置き場の名前の 1 段にする。
    static func keySegment(pin: DependencyVersion.Pin?) -> String? {
        switch pin {
        case .version(let version): version
        // 枝や改訂で固定したものは版を名乗らない。**版と混ぜない** — 混ざると
        // 互いを作り直させ続ける
        case .revision(let revision): "rev-\(revision.prefix(12))"
        case nil: nil
        }
    }

    /// そのパッケージの置き場になりうる場所を、**見る順に**並べる。
    ///
    /// **決めるのではなく、並べる。** 読むだけの経路 (面の仕様を探す・切り分けの口) は
    /// 「どこに在るか」を知りたいだけで、「どこへ建てるべきか」を決める必要が無い。
    /// 在る方を採る形にしておけば、共有へ移ったスケッチもパッケージ直下のままのスケッチも
    /// 同じ 1 本の計算で扱える (写しを作らないための形 — #791 / #730 が写しで割れた)。
    ///
    /// **道具立ての版は推さず、根を 1 段だけ列挙する。** 版を知るには `swift --version` を
    /// 起こすことになるが、読むだけの経路にプロセスを払わせたくない。列挙なら、道具立てを
    /// 入れ替えた後でも**前の置き場を見つけられる**という利点まで付く。
    static func plausibleDirectories(
        for package: URL, root: URL, pin: DependencyVersion.Pin?,
        listing: (URL) -> [String] = {
            (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? []
        }
    ) -> [URL] {
        var candidates: [URL] = []
        if let key = keySegment(pin: pin) {
            for segment in listing(root).sorted() where segment.hasPrefix("swiftlang-") {
                candidates.append(
                    root.appendingPathComponent("\(segment)/\(key)", isDirectory: true))
            }
        }
        candidates.append(package.appendingPathComponent(".build", isDirectory: true))
        return candidates
    }

    /// `swift --version` の出力から、置き場の名前に使える 1 語を作る。
    ///
    /// **読める形を選ぶ。** 切り分けの口が在処を名乗るので、ハッシュではなく
    /// `swiftlang-6.3.3.1.3` のような、人が版と突き合わせられる語にする。
    /// 取り出せなければ `nil` — **でっち上げて共有すると、違う toolchain の産物が
    /// 同じ部屋に入る。**
    static func toolchainSegment(from version: String?) -> String? {
        guard let version else { return nil }
        // 出力は "… Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-…)" の形
        guard let range = version.range(of: "swiftlang-") else { return nil }
        let rest = version[range.lowerBound...]
        let token = rest.prefix { !$0.isWhitespace && $0 != ")" && $0 != "(" }
        // 名前として使えない文字が混ざっていたら諦める (置き場の名前は 1 段である)
        guard token.count > "swiftlang-".count, !token.contains("/") else { return nil }
        return String(token)
    }

    // MARK: - 先客

    /// 共有の置き場で名前を取れたか。
    enum Claim: Equatable {
        /// 取れた (未使用だった・自分のものだった)。
        case free
        /// 別のパッケージのものである。
        case taken(by: String)
    }

    /// 読めなかった claim の持ち主の名乗り。
    ///
    /// **読めなかったことと、書かれていないことを同じ顔にしない。** 空の claim を
    /// 「未使用」と読むと、書きかけを掴んだ側が先客を追い出す。
    static let unreadableOwner = "読めない記録"

    /// 共有の置き場で contested になる名前。
    ///
    /// 置き場の中で 1 つしか席が無いのは、実行ファイル (`debug/<product>`) と、
    /// ターゲットごとの中間物 (`debug/<target>.build/`・`debug/Modules/<target>.swiftmodule`)
    /// と、資材の包み (`debug/<パッケージ>_<target>.bundle`) である。**ひな形は
    /// package = product = target を同じ名前にする**ので、この集合を押さえれば全部覆える。
    ///
    /// 依存が持ち込む名前 (`MokumeCore` など) は数えない — 鍵が同じなら中身も同じで、
    /// 共有できることがまさに狙いである。
    static func contestedNames(of package: SwiftPM.Package) -> [String] {
        var names: [String] = []
        if let product = package.executableProductName { names.append(product) }
        names.append(contentsOf: package.targets.map(\.name))
        var seen = Set<String>()
        // 置き場の名前にできないものは押さえようがないので落とす
        return names.filter { !$0.contains("/") && !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 共有の置き場で名前を押さえる。
    ///
    /// **ロックを持たない。** `O_CREAT | O_EXCL` は「無ければ作る」を 1 回の syscall で
    /// 行うので、同時に走った 2 つのうち片方だけが成功する — 競り合いはそこで決着し、
    /// 負けた側は相手の記録を読んで落ちる先を決める。
    ///
    /// 持ち主のディレクトリが消えていれば記録を解放して取り直す (作って消したスケッチの
    /// 名前が、永久に共有を塞がないため)。
    static func claim(_ names: [String], for packageDirectory: URL, in store: URL) -> Claim {
        let owner = ownerPath(of: packageDirectory)
        for name in names {
            let standing = claimOne(name, owner: owner, in: store)
            if case .taken = standing { return standing }
        }
        return .free
    }

    /// 記録に書く、持ち主の名乗り。
    static func ownerPath(of packageDirectory: URL) -> String {
        packageDirectory.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// 記録の置き場。
    static func ownersDirectory(in store: URL) -> URL {
        store.appendingPathComponent(ownersSegment, isDirectory: true)
    }

    /// その置き場に、このパッケージの名前が記録されているか。**読むだけ。**
    static func owns(_ package: URL, in store: URL) -> Bool {
        let owner = ownerPath(of: package)
        let owners = ownersDirectory(in: store)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: owners.path)) ?? []
        return names.contains { name in
            let text = try? String(
                contentsOf: owners.appendingPathComponent(name, isDirectory: false),
                encoding: .utf8)
            return text?.trimmingCharacters(in: .whitespacesAndNewlines) == owner
        }
    }

    /// そのパッケージが**実際に建てている**置き場。まだ建てていなければ `nil`。
    ///
    /// **並べるだけでは足りない。** 共有の置き場が在ることは、このパッケージがそこを
    /// 使っている証拠にはならない — 同じ版に依存する別のスケッチが作ったのかもしれず、
    /// 先客に譲ってパッケージ直下へ落ちた側にそれを名乗ると、**切り分けの口が嘘をつく**。
    ///
    /// **決め手は記録である。** 名前を押さえた側だけが記録に載るので、読めば分かる。
    /// **何も作らない** ので、切り分けの口の規律 (何も直さない) を崩さない。
    static func settled(
        for package: URL, root: URL, pin: DependencyVersion.Pin?,
        listing: (URL) -> [String] = {
            (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? []
        },
        exists: (URL) -> Bool = { WorkDirectory.directoryExists(at: $0) }
    ) -> URL? {
        let inPackage = package.appendingPathComponent(".build", isDirectory: true)
        for candidate in plausibleDirectories(
            for: package, root: root, pin: pin, listing: listing)
        where candidate != inPackage {
            if exists(candidate), owns(package, in: candidate) { return candidate }
        }
        return exists(inPackage) ? inPackage : nil
    }

    private static func claimOne(_ name: String, owner: String, in store: URL) -> Claim {
        let url = ownersDirectory(in: store).appendingPathComponent(name, isDirectory: false)
        // 2 巡する。1 巡目で消えた先客の記録を解放したら、2 巡目で取り直す
        for _ in 0..<2 {
            if createExclusively(url, contents: owner) { return .free }
            guard let existing = try? String(contentsOf: url, encoding: .utf8) else {
                return .taken(by: unreadableOwner)
            }
            let claimed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            // 空は「書きかけ」でありうる。**未使用へは倒さない**
            guard !claimed.isEmpty else { return .taken(by: unreadableOwner) }
            if claimed == owner { return .free }
            let holder = URL(fileURLWithPath: claimed, isDirectory: true)
            if WorkDirectory.directoryExists(at: holder) { return .taken(by: claimed) }
            // 先客のパッケージが消えている → 記録を解放して取り直す
            try? FileManager.default.removeItem(at: url)
        }
        // 2 巡しても取れないのは、解放した席を他の誰かが先に取ったときだけ
        let winner = try? String(contentsOf: url, encoding: .utf8)
        return .taken(
            by: winner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? unreadableOwner)
    }

    /// 無ければ作る (在れば作らない) を 1 回の syscall で行う。
    private static func createExclusively(_ url: URL, contents: String) -> Bool {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let bytes = Array((contents + "\n").utf8)
        _ = bytes.withUnsafeBufferPointer { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        return true
    }
}
