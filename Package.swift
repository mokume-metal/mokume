// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import PackageDescription

// ターゲットの並びは ADR-0016 の層そのもの。依存は必ず下の層へ向かい、
// 逆流したコードはビルドが通らない (検査を別に持たなくてよい)。
// 具体のモジュール列挙は固定しない — 何が独立領域になるかは実装するまで
// 確定しないため、ここにあるのは各層の最初の 1 つだけ。

let package = Package(
    name: "mokume",
    // ADR-0009: macOS 26 (Tahoe) 以上・Apple Silicon 専用・Metal 4 世代のみ
    platforms: [.macOS("26.0")],
    products: [
        // ADR-0016 決定 2: 利用者から見た入口は 1 つ。内部の割り方は書き味に漏らさない
        .library(name: "mokume", targets: ["mokume"]),
        // 道具。**実行ファイルの名前は product の名前で決まる**ので、ライブラリと
        // 同じ名前は置けない (同名で両方を宣言すると、ビルドは通るのに実行ファイルが
        // 作られない — 実測)。配布のときに mokume という名前で入れる
        .executable(name: "mokume-cli", targets: ["MokumeCLI"]),
    ],
    targets: [
        // 層: 基盤 — 何にも依存しない
        .target(name: "MokumeDiagnostics", swiftSettings: .mokume),
        // 層: 描画コア — 基盤にのみ依存する
        .target(
            name: "MokumeCore",
            dependencies: ["MokumeDiagnostics"],
            resources: [.process("Drawing/Shaders"), .process("Display/Shaders")],
            swiftSettings: .mokume),
        // アンブレラ — 全モジュールを再エクスポートする
        .target(name: "mokume", dependencies: ["MokumeCore"], swiftSettings: .mokume),
        // 道具 — スケッチを作って走らせる。テンプレートはソースとして持ち、
        // 生成物はコミットしない (ADR-0001 原則 8)
        .executableTarget(
            name: "MokumeCLI",
            dependencies: ["mokume"],
            resources: [.copy("Templates")],
            swiftSettings: .mokume),
        // 開発時に測るための道具。product には含めない (利用者へ配るものではない)
        .executableTarget(name: "frame-rate-probe", dependencies: ["mokume"], swiftSettings: .mokume),
        .testTarget(
            name: "MokumeCoreTests", dependencies: ["mokume"],
            // 台帳は検査が自分の場所から読むテキストで、束ねる資源ではない
            exclude: ["scene-ledger.txt"], swiftSettings: .mokume),
        .testTarget(name: "MokumeCLITests", dependencies: ["MokumeCLI"], swiftSettings: .mokume),
    ]
)

extension [SwiftSetting] {
    /// 全ターゲット共通の言語設定。
    ///
    /// - ADR-0009: Swift 6 言語モード (並行性の検査はエラーとして働く)
    /// - ADR-0010 決定 1: スケッチは main actor 既定 — ターゲット単位の既定隔離を
    ///   main actor にすることで、利用者のコードに並行性の注釈が現れない
    static var mokume: [SwiftSetting] {
        [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)]
    }
}
