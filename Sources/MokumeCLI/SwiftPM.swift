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

        /// 入っているべき資材の包みの名前。
        ///
        /// 道具立ては資材を `<パッケージ>_<ターゲット>.bundle` の名前で作る。
        var declaredResourceBundles: [String] {
            targets.filter { !$0.resources.isEmpty }.map { "\(name)_\($0.name).bundle" }
        }

        /// 走らせる実行ファイルの束に**そのまま写される**資材の置き場 (`Sources/<target>/assets`)
        /// ([#2517](https://github.com/mokume-metal/mokume/issues/2517))。
        ///
        /// 見張りが子へ渡し、置き場の断片を束の写しではなく元から読ませる (``ShaderOrigin``)。決めるのは
        /// 宣言である — product を作る target のうち、`.copy("assets")` を宣言したもの。**どの target の置き場が
        /// 束に入るかを、ディレクトリの並びから推し量らない** (束に入っていない別の target の断片を黙って
        /// 読まない)。
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
                guard let target = targets.first(where: { $0.name == name }),
                    target.resources.contains(where: {
                        $0.isCopy && Self.normalized($0.path) == directoryName
                    })
                else { continue }
                // 置き場の場所が決まらない target があれば、決められない (推し量らない)
                guard let place = sourceDirectory(of: target, in: root) else { return .undecided }
                let assets = place.appendingPathComponent(directoryName, isDirectory: true)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: assets.path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                {
                    found.append(assets)
                }
            }
            switch found.count {
            case 0: return .notCopied
            case 1: return .source(found[0])
            default: return .undecided
            }
        }

        /// 資材の相対パスの綴りを揃える (`./assets/`・`assets/` → `assets`)。
        private static func normalized(_ path: String?) -> String? {
            guard let path else { return nil }
            var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            while parts.first == "." { parts.removeFirst() }
            return parts.joined(separator: "/")
        }

        /// target のソースの置き場。**`path:` があればそれ、無ければ道具立ての既定の置き場。**
        /// 在るものが無ければ `nil`。
        private func sourceDirectory(of target: Target, in root: URL) -> URL? {
            let candidates =
                target.path.map { [$0] }
                ?? ["Sources", "Source", "src", "srcs"].map { "\($0)/\(target.name)" }
            for relative in candidates {
                let url = root.appendingPathComponent(relative, isDirectory: true)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                {
                    return url
                }
            }
            return nil
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

        private enum CodingKeys: String, CodingKey { case name, path, resources }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            path = try container.decodeIfPresent(String.self, forKey: .path)
            resources = try container.decodeIfPresent([Resource].self, forKey: .resources) ?? []
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
            }

            struct State: Decodable {
                let name: String
                /// パスで指した依存の在処。`name` が `fileSystem` のときだけ在る。
                let path: String?
            }
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
                /// 版で固定したときだけ在る。枝や改訂で固定した依存には無い。
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
        /// 枝や改訂で固定した依存は版を名乗らないので、版だけを見ていると「まだ解決されて
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
