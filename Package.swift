// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CompilerPluginSupport
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
    dependencies: [
        // ADR-0013 決定 2 が原則 5 の明示的な例外として引き受けた 1 件。macro を
        // 書くために要るもので、これ以上の外部依存を開く前例にはしない
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0")
    ],
    targets: [
        // 層: 基盤 — 何にも依存しない
        .target(name: "MokumeDiagnostics", swiftSettings: .mokume),
        // macro の実装。ビルドの間だけ走る道具で、利用者へ配るものには入らない
        .macro(
            name: "MokumeMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            // 既定の隔離を main actor にしない。ここはビルドの間だけ走るコードで、
            // スケッチの気楽さのための既定 (ADR-0010 決定 1) が効く場所ではない
            swiftSettings: .tool),
        // 層: 描画コア — 基盤にのみ依存する
        .target(
            name: "MokumeCore",
            dependencies: ["MokumeDiagnostics", "MokumeMacros"],
            // **シェーダの断片は 1 つずつ写す。**
            //
            // `.process` でディレクトリごと渡すと、Swift 6.4 の道具立ては `.metal` を
            // **資源ではなくソースと読んで 1 ファイルずつコンパイルしようとする** —
            // 断片は単独では組めない (前置きが持つ宣言が見えない) ので、Xcode 27 の
            // 機械では build 段で止まる ([#1268])。ここの断片は実行時に文面を
            // 組み合わせて `makeLibrary(source:)` するもので、**組み上がった
            // metallib は要らない**。
            //
            // **ディレクトリ単位の `.copy` は使えない。** `Drawing/Shaders` と
            // `Display/Shaders` は名前が同じなので `multiple resources named
            // 'Shaders'` で弾かれる。1 つずつ写せば、束ねた中身は `.process` の
            // ときと同じ**平らな 9 ファイル**になり、探す側 (`ModuleResources`) は
            // 何も変わらない。
            //
            // **足したら、ここに 1 行足す。** ディレクトリごと拾っていたものを手書きの
            // 一覧にしたので、書き忘れは「組めるのに実行時に見つからない」形で出る —
            // それを見る検査が `ModuleResourcesTests` にある。
            //
            // [#1268]: https://github.com/mokume-metal/mokume/issues/1268
            resources: [
                .copy("Display/Shaders/Present.metal"),
                .copy("Drawing/Shaders/Common.metal"),
                .copy("Drawing/Shaders/Compute.metal"),
                .copy("Drawing/Shaders/Computations/Particles.metal"),
                .copy("Image/ImageInput.metal"),
                .copy("Drawing/Shaders/Effect.metal"),
                .copy("Drawing/Shaders/Effects/Builtin.metal"),
                .copy("Drawing/Shaders/Kinds.metal"),
                .copy("Drawing/Shaders/Shapes.metal"),
                .copy("Drawing/Shaders/UnitShape.metal"),
            ],
            swiftSettings: .mokume),
        // 層: コア依存 — 描画コアの上に載り、外とやりとりする領域 (ADR-0042 決定 3)。
        // MokumeCore の public だけで書く。利用者が選んで import する product にはせず、
        // アンブレラが再エクスポートする。MokumeCamera は外から来る映像 (カメラと動画ファイル) を
        // 持つ — 動画は 1 枚を絵にする変換 (FrameConverter) をカメラと共有するので、同じ所に置く (#1960)
        .target(
            name: "MokumeCamera", dependencies: ["MokumeCore", "MokumeDiagnostics"],
            swiftSettings: .mokume),
        .target(
            name: "MokumeAudio", dependencies: ["MokumeCore", "MokumeDiagnostics"],
            swiftSettings: .mokume),
        // 通信 (OSC と、TCP・UDP・WebSocket の文字列。ポートを開く層を共有する)
        .target(
            name: "MokumeNetwork", dependencies: ["MokumeCore", "MokumeDiagnostics"],
            swiftSettings: .mokume),
        // アンブレラ — 全モジュールを再エクスポートする
        .target(
            name: "mokume", dependencies: ["MokumeCore", "MokumeCamera", "MokumeAudio", "MokumeNetwork"],
            swiftSettings: .mokume),
        // 道具 — スケッチを作って走らせる。テンプレートはソースとして持ち、
        // 生成物はコミットしない (ADR-0001 原則 8)
        .executableTarget(
            name: "MokumeCLI",
            dependencies: ["mokume"],
            resources: [.copy("Templates")],
            swiftSettings: .mokume),
        // 開発時に測るための道具。product には含めない (利用者へ配るものではない)
        // 参照スケッチ。2D の面が実際に成立していることを、使って示す。
        // product には含めない — 利用者へ配るものではなく、面を確かめるためのもの。
        // 台帳の検査 (MokumeCoreTests) がこれに依存し、全スケッチの絵を指紋にする (#1377)
        // data/ はスケッチが読むテキスト (CSV など) で、束ねる資源ではない。参照スケッチは
        // 入口ごとに作業ディレクトリが違うので、ソースの隣を名指しして読む (TableAndText.swift)
        .executableTarget(
            name: "reference-sketches", dependencies: ["mokume"], path: "Sketches",
            exclude: ["data"], swiftSettings: .mokume),
        .executableTarget(name: "frame-rate-probe", dependencies: ["mokume"], swiftSettings: .mokume),
        .testTarget(
            name: "MokumeCoreTests", dependencies: ["mokume", "reference-sketches"],
            // 台帳は検査が自分の場所から読むテキストで、束ねる資源ではない
            exclude: ["scene-ledger.txt"], swiftSettings: .mokumeTests),
        .testTarget(name: "MokumeCLITests", dependencies: ["MokumeCLI"], swiftSettings: .mokumeTests),
        // 計測の道具の引数の解き方 (#2490)。道具の最上位は走らせると窓を開くので、
        // 解き方だけを ProbeArguments.swift に出して、ここから呼ぶ
        .testTarget(
            name: "FrameRateProbeTests", dependencies: ["frame-rate-probe"],
            swiftSettings: .mokumeTests),
        .testTarget(
            name: "MokumeCameraTests", dependencies: ["mokume", "MokumeCamera"],
            swiftSettings: .mokumeTests),
        .testTarget(
            name: "MokumeAudioTests", dependencies: ["mokume", "MokumeAudio"],
            swiftSettings: .mokumeTests),
        .testTarget(
            name: "MokumeNetworkTests", dependencies: ["mokume", "MokumeNetwork"],
            swiftSettings: .mokumeTests),

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

    /// ビルドの間だけ走るコードの言語設定 (macro の実装)。
    ///
    /// スケッチのための既定隔離は載せない — macro の展開はコンパイラの中で走り、
    /// main actor は存在しない。
    static var tool: [SwiftSetting] { [.swiftLanguageMode(.v6)] }

    /// テストターゲットの言語設定。
    ///
    /// `MOKUME_TESTS_WITHOUT_WMO=1` のときだけ、release でもテストを whole-module 最適化
    /// (WMO) せずにファイルごとに組む (#2596)。WMO は型検査と SIL 最適化を 1 本の
    /// フロントエンドで逐次に走らせるので、テストが増えるほど線形より速く伸び、コア数も
    /// 使えない (`MokumeCoreTests` が release のビルドの 8 割を占めた)。立てるのは
    /// release.yml の release-check だけである。
    ///
    /// - **`-O` は保つ。** `-Onone` にすると、テストの側で `assert` の残り方を見る
    ///   `isDebugBuild` が真になり、release でだけ走る検査が黙って飛ぶ
    /// - テストだけに掛ける。本体のモジュールは利用者が組むのと同じ WMO のまま検査する
    /// - **既定にはしない。** swiftbuild (Swift 6.4 の既定のビルド系) は release を WMO と
    ///   決め打ちして出力を計画するので、この旗で `-primary.d` が無いと言って落ちる。
    ///   CI の既定が swiftbuild に変わったら、release-check が落ちるので、そのとき外す
    static var mokumeTests: [SwiftSetting] {
        guard Context.environment["MOKUME_TESTS_WITHOUT_WMO"] == "1" else { return mokume }
        return mokume + [
            .unsafeFlags(["-no-whole-module-optimization"], .when(configuration: .release))
        ]
    }
}
