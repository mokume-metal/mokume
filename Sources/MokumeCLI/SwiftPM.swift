// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 道具立て (SwiftPM) が書く JSON の形。
///
/// ## なぜ 1 箇所に集めるのか
///
/// 読み手が銘々 `[String: Any]` を `as?` で降りていた。**鍵の綴りが 4 ファイルに散り、
/// どれも `nil` を正常系として扱う** — 実行ファイルの宣言が無い / 資材の宣言が無い /
/// 依存が解決されていない / pin が無い。だから道具立てが JSON の形を変えた日には、
/// 4 箇所とも「黙って `nil`」へ落ち、**症状は「宣言していないことになっている」**
/// としか出ない。読めなかったことと書かれていないことが、呼ぶ側で同じ顔になる。
///
/// 型で読めば綴りは 1 箇所になり、抜けた鍵はデコードの失敗として現れる。
///
/// ## 読めなかったことは、まだ呼ぶ側へ届かない
///
/// 入口は `nil` を返す。**分ける口は、実際に道具立ての形が動いた日に足す**
/// ([ADR-0008] 決定 1) — いまは「1 つの綴り」が要るのであって、新しい失敗の種別が
/// 要るわけではない。
///
/// [ADR-0008]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md
nonisolated enum SwiftPM {
    /// 見張りの子の置き場の元 (``ShaderOrigin``)。
    enum AssetsOrigin: Equatable {
        /// 走らせる実行ファイルの束には、置き場がそのまま写されない (宣言が無い・`.process`・`.copy` が
        /// 別のファイルだけ)。**子へは何も渡さず、今までどおり**資材の宣言の検査が見る。
        case notCopied
        /// 束にそのまま写される置き場の元。
        case source(URL)
        /// 宣言が読めない・置き場が複数あって決まらない。**推し量らずに渡さない。**
        case undecided

        /// 子へ渡す在処。
        var url: URL? {
            if case .source(let url) = self { return url }
            return nil
        }
    }

    // MARK: - swift package dump-package

    /// `swift package dump-package` が出すパッケージの宣言。
    struct Package: Decodable, Equatable {
        /// パッケージの名前。
        let name: String
        /// 宣言された product。
        let products: [Product]
        /// 宣言された target。
        let targets: [Target]
        /// 宣言された対応環境。
        let platforms: [Platform]
        /// 宣言された依存。
        let dependencies: [Dependency]

        private enum CodingKeys: String, CodingKey {
            case name, products, targets, platforms, dependencies
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // **名前だけは必ず在る。** 無ければ dump-package の出力ではない
            name = try container.decode(String.self, forKey: .name)
            // **空と「鍵が無い」は同じ意味。** 宣言していないものを道具立てが
            // どう書くかは版で動くので、どちらも「宣言が無い」として読む
            products = try container.decodeIfPresent([Product].self, forKey: .products) ?? []
            targets = try container.decodeIfPresent([Target].self, forKey: .targets) ?? []
            platforms = try container.decodeIfPresent([Platform].self, forKey: .platforms) ?? []
            dependencies =
                try container.decodeIfPresent([Dependency].self, forKey: .dependencies) ?? []
        }

        /// 実行ファイルとして宣言された product の名前。
        ///
        /// **ビルドの出力を漁らない。** それらしいものを選ぶ形にすると、product が
        /// 増えた日に黙って別のものを起動する。
        var executableProductName: String? {
            products.first { $0.type.isExecutable }?.name
        }

        /// 名乗っている macOS の下限の版。
        var minimumMacOSVersion: String? {
            platforms.first { $0.platformName == "macos" }?.version
        }

        /// 配る範囲の資材の包み。**コピーで除く名前と、入っているべき名前を、同じ閉包から 1 度に求める**
        /// (#3982)。別々に求めると、片方だけ古い求め方に戻っても気付けない — 除いた包みを「欠けている」と
        /// 読む、あるいは要る包みを除いたまま検査が通る。
        struct ResourceScope: Equatable {
            /// 入っているべき包みの名前 (資材を宣言した target のうち、閉包の中のもの)。道具立ては資材を
            /// `<パッケージ>_<ターゲット>.bundle` の名前で作る。
            let required: [String]
            /// 配るものに入れない包みの名前 (このパッケージの target のうち、閉包の外のもの)。資材の
            /// 宣言が無くても道具立てが包みを作る種類があるので、宣言の有無は見ない。他のパッケージの
            /// 包みは宣言を辿らずに入れる (依存が持ち込む資材は無ければ絵が出ない) ので、ここには載らない。
            /// 隣の並びを渡した形 (``resourceScope(forProduct:beside:dependencyPackages:)``) では、宣言から
            /// 消えた target の古い包みも載る (#4005)。
            let excluded: Set<String>
        }

        /// `product` を配る範囲。**名前の形 (`…Tests`) では決めない** — 依存の閉包の内外で決める。
        /// 閉包が求められない (product の宣言が無い・読めない依存に出会った) ときは、推し量らずに従来の
        /// 判定 (資材を宣言した target を全部数え、何も除かない) へ倒す。
        func resourceScope(forProduct product: String) -> ResourceScope {
            let used = targetClosure(ofProduct: product)
            return ResourceScope(
                required: targets.filter { !$0.resources.isEmpty && used?.contains($0.name) != false }
                    .map { "\(name)_\($0.name).bundle" },
                excluded: used.map { used in
                    Set(targets.filter { !used.contains($0.name) }.map { "\(name)_\($0.name).bundle" })
                } ?? [])
        }

        /// `product` を配る範囲に、**宣言から消えた target の古い包み**の除外を足したもの (#4005)。
        ///
        /// 束ねる置き場は利用者の `swift build` / `swift test` と共有なので、`Package.swift` から消した・
        /// 改名した target の包みが隣に残る。宣言に無いので閉包からは出てこない。除くのは、隣に並んだ包みの
        /// うち、**このパッケージの宣言の名前**を頭に持ち (`<name>_…`)、いまの宣言のどの target の包みでもなく、
        /// **どの依存のパッケージの名前 (`<依存>_…`) でも説明できない**もの。自分の名前が依存の名前を頭に
        /// 持つ (`Demo_Extras` と `Demo`) と、`Demo_Extras_Gone.bundle` はどちらのものとも読めるので除かない
        /// (入れすぎる側へ倒す)。依存の名前が読めない (`nil`)・閉包が求められないときは、古い包みを除かない。
        ///
        /// - Parameters:
        ///   - built: 実行ファイルの隣に並んだ包みの名前。
        ///   - dependencyPackages: 依存のパッケージの名前 (``WorkspaceState/packageNames``)。読めなければ `nil`。
        func resourceScope(
            forProduct product: String, beside built: [String], dependencyPackages: [String]?
        ) -> ResourceScope {
            let scope = resourceScope(forProduct: product)
            guard let dependencyPackages, targetClosure(ofProduct: product) != nil else { return scope }
            let declared = Set(targets.map { "\(name)_\($0.name).bundle" })
            let leftovers = built.filter { bundle in
                bundle.hasSuffix(".bundle") && bundle.hasPrefix("\(name)_") && !declared.contains(bundle)
                    && !dependencyPackages.contains { bundle.hasPrefix("\($0)_") }
            }
            return ResourceScope(required: scope.required, excluded: scope.excluded.union(leftovers))
        }

        /// `product` を作る target と、それらがこのパッケージの中で (推移的に) 依存する target の名前。
        /// product の宣言が無い・product の target が空か宣言に無い名前を含む・辿る途中で依存を読めない
        /// target に出会った、のどれかなら `nil`。
        ///
        /// `byName` は同じ名前の target があれば target、無ければ他のパッケージの product と読む
        /// (道具立てと同じ解き方)。
        func targetClosure(ofProduct product: String) -> Set<String>? {
            guard let declared = products.first(where: { $0.name == product }) else { return nil }
            let byName = Dictionary(targets.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            // **起点が読めなければ求めない。** product の target が無い (鍵が無い・空)、または宣言に無い
            // 名前を挙げていると、閉包が空になり、作品自身の包みまで除いてしまう
            guard !declared.targets.isEmpty, declared.targets.allSatisfy({ byName[$0] != nil })
            else { return nil }
            var used = Set<String>()
            var pending = declared.targets
            while let next = pending.popLast() {
                guard let target = byName[next], used.insert(next).inserted else { continue }
                guard let dependencies = target.dependencies else { return nil }
                pending.append(contentsOf: dependencies)
            }
            return used
        }

        /// 走らせる実行ファイルの束に**そのまま写される**資材の置き場 (`Sources/<target>/assets`)
        /// ([#2517](https://github.com/mokume-metal/mokume/issues/2517))。
        ///
        /// 見張りが子へ渡し、置き場の断片を束の写しではなく元から読ませる (``ShaderOrigin``)。決めるのは
        /// 宣言である — product を作る target のうち、置き場を `.copy` で宣言したもの。**どの target の置き場が
        /// 束に入るかを、ディレクトリの並びから推し量らない** (束に入っていない別の target の断片を黙って
        /// 読まない)。
        ///
        /// **宣言が置き場を指すかは、走らせる前の検査と同じ 1 つで見る** (``declaration(of:by:placedAt:)``・
        /// #3984)。検査が通す宣言 (`.copy("Assets")`・`path: "Sources"` の `.copy("demo/assets")`) を、ここで
        /// 綴りで比べて「写されない」と読むと、見張りは黙って束の写しを読ませる。見る置き場は、target の
        /// 置き場の直下の置き場と、検査が見る `Sources/<名前>/<置き場>` のうちその target が含むもの。
        ///
        /// - Parameters:
        ///   - product: 走らせる実行ファイルの名前。宣言が読めなければ `nil`。
        ///   - root: パッケージの場所。
        ///   - directoryName: 置き場の名前 (``ResourceDeclaration/directoryName``)。
        func assetsOrigin(
            forProduct product: String?, in root: URL, directoryName: String
        ) -> AssetsOrigin {
            guard let product, let declared = products.first(where: { $0.name == product })
            else { return .undecided }
            var found: [URL] = []
            for name in declared.targets {
                guard let target = targets.first(where: { $0.name == name }) else { continue }
                // 置き場の場所が決まらない target が写す宣言を持てば、決められない (推し量らない)
                guard let directory = sourceDirectory(of: target, in: root) else {
                    if target.resources.contains(where: \.isCopy) { return .undecided }
                    continue
                }
                let places =
                    [directory.appendingPathComponent(directoryName, isDirectory: true)]
                    + Self.places(in: root, directoryName: directoryName).filter {
                        self.target(containing: $0, in: root)?.target.name == name
                    }
                for place in places where Self.isDirectory(place) {
                    guard declaration(of: place, by: target, placedAt: directory)?.isCopy == true,
                        !found.contains(where: { Self.sameItem($0, place) })
                    else { continue }
                    found.append(place)
                }
            }
            switch found.count {
            case 0: return .notCopied
            case 1: return .source(found[0])
            default: return .undecided
            }
        }

        /// 走らせる前の検査が見る置き場の候補 (`Sources/<名前>/<置き場の名前>`)。在るかは見ない。
        static func places(in root: URL, directoryName: String) -> [URL] {
            let sources = root.appendingPathComponent("Sources", isDirectory: true)
            guard
                let entries = try? FileManager.default.contentsOfDirectory(
                    at: sources, includingPropertiesForKeys: [.isDirectoryKey])
            else { return [] }
            return entries.sorted { $0.path < $1.path }.map {
                $0.appendingPathComponent(directoryName, isDirectory: true)
            }
        }

        /// `target` が置き場 `place` を資材として挙げている宣言。無ければ `nil`。
        ///
        /// **宣言のパスは target の置き場 (`directory`) から解き、置き場そのものとファイルとして同じかで
        /// 見る** (``sameItem(_:_:)``)。綴り (`./assets`・`assets/`・区別しないボリュームの `Assets`) では
        /// 比べない。**置き場そのものを指す宣言だけ**が置き場の宣言である — 祖先 (`.copy("demo")`・
        /// `.copy(".")`) を写すと束の中は `demo/assets/…` になり、読み込み側 (束の直下の `assets/<名前>`
        /// を探す) は見つけられない。置き場の中の 1 ファイル (`assets/img.png`) だけでは他の資材が入らない。
        func declaration(of place: URL, by target: Target, placedAt directory: URL) -> Target.Resource? {
            target.resources.first { resource in
                guard let path = resource.path else { return false }
                return Self.sameItem(Self.resolve(path, from: directory), place)
            }
        }

        /// `item` を含む target と、その置き場 (``sourceDirectory(of:in:)`` で決める)。`item` の祖先の
        /// うち、**最も近い**ものを置き場にする target を選ぶ (`path: "Sources"` のように親を置き場に
        /// した target も、`item` を含む)。無ければ `nil`。
        ///
        /// **同じディレクトリかは、ファイルとして同じかで見る** (``sameItem(_:_:)``)。
        func target(containing item: URL, in root: URL) -> (target: Target, directory: URL)? {
            let places = targets.compactMap { target in
                sourceDirectory(of: target, in: root).map { (target: target, directory: $0) }
            }
            var ancestor = item.deletingLastPathComponent()
            let top = root.standardizedFileURL.path
            while true {
                if let found = places.first(where: { Self.sameItem($0.directory, ancestor) }) {
                    return found
                }
                if ancestor.standardizedFileURL.path == top || ancestor.path == "/" { return nil }
                ancestor = ancestor.deletingLastPathComponent()
            }
        }

        /// 2 つの場所が、**ファイルとして**同じものか。綴り (大文字と小文字を区別しないボリュームでの
        /// 大小・`..`) の違いで、同じ置き場を別のものと読まない。
        ///
        /// ファイルの識別子で比べ、取れなければ実体のパス (`realpath(3)`) で比べる。識別子が取れない
        /// だけで「同じでない」に倒すと、検査は置き場の持ち主を見失って通す側へ倒れる。どちらも
        /// 取れなければ (在らない場所) `false`。
        static func sameItem(_ a: URL, _ b: URL) -> Bool {
            if let one = identity(of: a), let other = identity(of: b) { return one.isEqual(other) }
            guard let one = realPath(of: a), let other = realPath(of: b) else { return false }
            return one == other
        }

        private static func identity(of url: URL) -> NSObject? {
            (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?
                .fileResourceIdentifier as? NSObject
        }

        private static func realPath(of url: URL) -> String? {
            guard let resolved = realpath(url.path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        /// 宣言に書かれたパスを、基準の場所から解く。**絶対パスはそのまま使う** — 基準に足すと
        /// 在らない場所になり、検査が黙って素通りする (#3984)。
        private static func resolve(_ path: String, from base: URL) -> URL {
            path.hasPrefix("/")
                ? URL(fileURLWithPath: path, isDirectory: true)
                : base.appendingPathComponent(path, isDirectory: true)
        }

        /// target のソースの置き場。**`path:` があればそれ、無ければ道具立ての既定の置き場。**
        /// 在るものが無ければ `nil`。`path:` が絶対パスならそのまま使う。
        ///
        /// 既定の置き場は道具立てと同じ規則で決める: target の種類ごとの候補 (``Target/defaultRoots``)
        /// のうち**パッケージに在る最初のもの**の下の `<名前>` (#3984)。候補ごとに `<名前>` を探す形に
        /// すると、テストやプラグインの target が `Sources/<名前>` に当たりうる。
        private func sourceDirectory(of target: Target, in root: URL) -> URL? {
            let relative: String
            if let path = target.path {
                relative = path
            } else {
                guard let base = target.defaultRoots.first(where: { Self.isDirectory(root.appendingPathComponent($0)) })
                else { return nil }
                relative = "\(base)/\(target.name)"
            }
            let url = Self.resolve(relative, from: root)
            return Self.isDirectory(url) ? url : nil
        }

        private static func isDirectory(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }

        /// パスで指した依存を 1 つでも持つか。
        ///
        /// **持つなら、ビルドの置き場を他のパッケージと共有できない。** 共有の置き場は
        /// 「解決された版が同じなら中身も同じ」を前提に鍵を付けるが、パスで指した先は
        /// 版を名乗らないまま中身が動く (`git checkout` を往復させれば同じ鍵で別物になる)。
        ///
        /// **どの依存がパスかは見ない。** パスで指すと identity が末尾のディレクトリ名に
        /// なるので (``SchemasLocator/packageName`` が完全一致で選べない理由と同じ)、
        /// 名前で mokume を狙い撃つと作業用の複製を取り逃す。1 つでも在れば共有しない、
        /// という安全側の判定にしておく。
        var hasFileSystemDependency: Bool {
            dependencies.contains { $0.isFileSystem }
        }
    }

    /// 宣言された依存。
    ///
    /// **中身は読まない。** 要るのは「パスで指しているか」だけで、位置も要求も
    /// 解決の結果 (`Package.resolved`) のほうが正しい。
    struct Dependency: Decodable, Equatable {
        /// パスで指した依存か。
        ///
        /// ``Product/Kind/isExecutable`` と同じく**鍵が在るかどうかで決まる** —
        /// 道具立ては種別を `{"fileSystem": [...]}` / `{"sourceControl": [...]}` の
        /// 形で書き分けるので、値の中身まで降りる必要が無い。
        let isFileSystem: Bool

        private enum CodingKeys: String, CodingKey { case fileSystem }

        init(from decoder: any Decoder) throws {
            isFileSystem = try decoder.container(keyedBy: CodingKeys.self).contains(.fileSystem)
        }
    }

    /// 宣言された product。
    struct Product: Decodable, Equatable {
        let name: String
        let type: Kind
        /// product を作る target の名前。**鍵が無ければ空** (宣言していないことになる)。
        let targets: [String]

        private enum CodingKeys: String, CodingKey { case name, type, targets }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            type = try container.decode(Kind.self, forKey: .type)
            targets = try container.decodeIfPresent([String].self, forKey: .targets) ?? []
        }

        /// product の種別。
        struct Kind: Decodable, Equatable {
            /// 実行ファイルか。
            ///
            /// **鍵が在るかどうかで決まる。** 道具立ては `{"executable": null}` と書くので、
            /// 値を読むと「null」と「鍵が無い」の区別が付かない。
            let isExecutable: Bool

            private enum CodingKeys: String, CodingKey { case executable }

            init(from decoder: any Decoder) throws {
                isExecutable = try decoder.container(keyedBy: CodingKeys.self)
                    .contains(.executable)
            }
        }
    }

    /// 宣言された target。
    struct Target: Decodable, Equatable {
        let name: String
        /// 宣言された置き場 (`path:`)。**指定が無ければ `nil`** — 道具立てが既定の場所から探す。
        let path: String?
        /// 宣言された資材。
        let resources: [Resource]

        /// 宣言された資材 1 件。
        struct Resource: Decodable, Equatable {
            /// target の置き場からの相対パス。
            let path: String?
            /// そのまま写す (`.copy`) 宣言か。**鍵が在るかどうかで決まる** — 道具立ては規則を
            /// `{"copy": {}}` / `{"process": {…}}` の形で書き分ける (``Product/Kind/isExecutable`` と同じ)。
            /// `.process` は種類ごとに変換して入れるので、元のファイルの写しが束に入るとは限らない。
            let isCopy: Bool

            private enum CodingKeys: String, CodingKey { case path, rule }
            private enum RuleKeys: String, CodingKey { case copy }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                path = try container.decodeIfPresent(String.self, forKey: .path)
                if let rule = try? container.nestedContainer(keyedBy: RuleKeys.self, forKey: .rule) {
                    isCopy = rule.contains(.copy)
                } else {
                    isCopy = false
                }
            }
        }

        /// 同じパッケージの target を指しうる依存の名前 (`byName`・`target`)。**他のパッケージの
        /// product (`product`) は載せない** — 閉包はこのパッケージの中だけで求める。
        ///
        /// **1 件でも形を読めない依存があれば `nil`** (読めた分だけを返さない)。個別に捨てると、
        /// 使っている target が閉包から黙って落ち、その資材が配る `.app` から抜ける。`nil` を見た
        /// 閉包は求めるのを諦め、何も除かない側へ倒れる (``Package/targetClosure(ofProduct:)``)。
        let dependencies: [String]?

        /// target の依存 1 件。種別は鍵で書き分けられ、値は配列で先頭が名前。**2 番目以降 (条件など) は
        /// 形を問わず読み飛ばす** — 条件は `null` のほか、オブジェクトでも書かれる
        /// (`{"target": ["A", {"platformNames": ["macos"]}]}`・`{"target": ["C", {"platformNames": [],
        /// "traits": ["Extra"]}]}`)。条件つきの依存は、条件にかかわらず閉包に入れる (入れすぎる側へ倒す)。
        private enum Dependency: Decodable {
            /// 同じパッケージの target を指しうるもの (`byName`・`target`)。
            case local(String)
            /// 他のパッケージの product (`product`)。
            case external
            /// 知らない鍵・名前の読めない形。
            case unreadable

            private enum CodingKeys: String, CodingKey { case byName, target, product }

            init(from decoder: any Decoder) throws {
                guard let container = try? decoder.container(keyedBy: CodingKeys.self),
                    container.allKeys.count == 1, let key = container.allKeys.first
                else {
                    self = .unreadable
                    return
                }
                guard var values = try? container.nestedUnkeyedContainer(forKey: key),
                    let name = try? values.decode(String.self)
                else {
                    self = .unreadable
                    return
                }
                self = key == .product ? .external : .local(name)
            }
        }

        /// 種類 (`executable`・`regular`・`test`・`plugin` など)。**鍵が無ければ `nil`。**
        let kind: String?

        /// `path:` が無いときに置き場を探す、パッケージ直下の候補 (道具立てと同じ並び)。
        var defaultRoots: [String] {
            switch kind {
            case "test": ["Tests", "Sources", "Source", "src", "srcs"]
            case "plugin": ["Plugins"]
            default: ["Sources", "Source", "src", "srcs"]
            }
        }

        private enum CodingKeys: String, CodingKey {
            case name, path, resources, dependencies
            case kind = "type"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            path = try container.decodeIfPresent(String.self, forKey: .path)
            resources = try container.decodeIfPresent([Resource].self, forKey: .resources) ?? []
            // 鍵が無ければ依存が無い。在るのに配列として読めなければ、読めない
            if container.contains(.dependencies) {
                let read = try? container.decode([Dependency].self, forKey: .dependencies)
                var names: [String]? = []
                for dependency in read ?? [.unreadable] {
                    switch dependency {
                    case .local(let name): names?.append(name)
                    case .external: break
                    case .unreadable: names = nil
                    }
                }
                dependencies = names
            } else {
                dependencies = []
            }
            kind = try? container.decodeIfPresent(String.self, forKey: .kind)
        }
    }

    /// 宣言された対応環境。
    struct Platform: Decodable, Equatable {
        let platformName: String
        let version: String?
    }

    // MARK: - .build/workspace-state.json

    /// 道具立てが作業ディレクトリへ残す、解決済みの依存の状態。
    ///
    /// 引き方は依存の種類で変わる — パスで指したものは絶対パスがそのまま載り、
    /// 取ってきたものは `.build/checkouts/` の下に置かれる。
    struct WorkspaceState: Decodable {
        let object: Contents

        struct Contents: Decodable {
            let dependencies: [Dependency]
        }

        struct Dependency: Decodable {
            let packageRef: Reference
            let state: State
            /// 取ってきた依存の置き場 (`.build/checkouts/` からの相対)。
            let subpath: String?

            struct Reference: Decodable {
                let name: String
                let identity: String?
            }

            struct State: Decodable {
                let name: String
                /// パスで指した依存の在処。`name` が `fileSystem` のときだけ在る。
                let path: String?
            }
        }

        /// 依存のパッケージの名前 (#4005)。**宣言の名前 (`name`) と identity の両方を返す** — 道具立ては
        /// 資材の包みを宣言の名前で名付ける (`Demo_Extras_Foo.bundle`) が、ここに書かれる名前が宣言の名前で
        /// あることは道具立ての版に依る。多く返すほど、束ねる側が除く包みは減る (入れすぎる側へ倒す)。
        var packageNames: [String] {
            object.dependencies.flatMap { [$0.packageRef.name] + ($0.packageRef.identity.map { [$0] } ?? []) }
        }

        /// 名前で引いた依存の実体。
        ///
        /// - Parameter buildDirectory: **ビルドの置き場そのもの** (`.build` を足す前の姿では
        ///   ない)。置き場はパッケージ直下に在るとは限らないので、`.build` をここで
        ///   組み立てると、置き場を動かした環境で黙って空振りする — 在処を決める計算は
        ///   ``BuildDirectory`` 1 箇所に置く。
        func resolved(_ name: String, under buildDirectory: URL) -> URL? {
            guard let dependency = object.dependencies.first(where: { $0.packageRef.name == name })
            else { return nil }
            if dependency.state.name == "fileSystem", let path = dependency.state.path {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            guard let subpath = dependency.subpath else { return nil }
            return buildDirectory.appendingPathComponent("checkouts/\(subpath)", isDirectory: true)
        }
    }

    // MARK: - Package.resolved

    /// 固定された依存の版 (道具立ての版 2 以降 — `pins` が根にある)。
    struct Resolved: Decodable {
        let pins: [Pin]

        struct Pin: Decodable {
            let identity: String
            let state: State

            struct State: Decodable {
                /// 版で固定したときだけ在る。ブランチや改訂で固定した依存には無い。
                let version: String?
                /// 固定された改訂。**版で固定したときも在る** — 道具立ては両方書く。
                let revision: String?
            }
        }

        /// 識別子で引いた版。
        func version(of identity: String) -> String? {
            pins.first { $0.identity == identity }?.state.version
        }

        /// 識別子で引いた改訂。
        ///
        /// **版が読めなかったことと、そもそも固定されていないことを分けるために要る。**
        /// ブランチや改訂で固定した依存は版を名乗らないので、版だけを見ていると「まだ解決されて
        /// いない」と同じ顔になる — ビルドの置き場の鍵はそこを分けないと、**違う改訂の
        /// mokume を同じ置き場へ入れて互いに作り直させ続ける**ことになる。
        func revision(of identity: String) -> String? {
            pins.first { $0.identity == identity }?.state.revision
        }
    }

    // MARK: - 読み

    /// `dump-package` の出力を読む。**読めなければ `nil`。**
    static func package(inDumpOf dump: String) -> Package? {
        read(Package.self, from: Data(dump.utf8))
    }

    /// JSON を読む。**読めなければ `nil`。**
    static func read<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }

    /// ファイルの JSON を読む。**読めなければ `nil`。**
    static func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return read(type, from: data)
    }
}
