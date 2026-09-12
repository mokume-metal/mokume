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
        /// 宣言された資材。**中身は読まない** — 在るかどうかだけで足りる。
        let resources: [Resource]

        struct Resource: Decodable, Equatable {}

        private enum CodingKeys: String, CodingKey { case name, resources }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
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
