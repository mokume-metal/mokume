// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// いま **mokume 自身の検査**の中で走っているか ([#1682])。
///
/// mokume の中の不具合を見つけたとき、検査の中なら止めて赤にし、利用者の作品の中なら止めずに
/// 名乗る — その分かれ目を 1 か所に置く。利用者のスケッチも debug で組まれるので、
/// `assertionFailure` だけに頼ると、mokume の不具合を踏んだ作品ごと落ちる。
///
/// ## どう見分けるか
///
/// **起動の引数に、mokume の検査の束の実行ファイルがあるか**で見る。`make test` と素の
/// `swift test` で実測したところ (#1682)、どちらでも立つのは次の 2 つだけだった:
///
/// - プロセス名 `swiftpm-testing-helper` — **利用者が自分のパッケージの検査を回しても立つ**ので使わない
/// - 引数の束の実行ファイル — 束の名前は mokume 固有
///
/// **束の名前は SwiftPM の版で違う。** 手元の版は `testTarget` ごとに束を作る
/// (`…/MokumeCoreTests.xctest/Contents/MacOS/MokumeCoreTests`)。CI の版 (Xcode 26.6) は全部を
/// 1 つの束にまとめ、パッケージ名から名付ける (`…/mokumePackageTests.xctest/…`)。手元でしか
/// 確かめずに入れた最初の形は、CI で「外」と判定した (#1696 の CI)。どちらも mokume 固有の名前で、
/// 利用者のパッケージは自分の名前の束になる。
///
/// `XCTestConfigurationFilePath` や `SWIFT_TESTING_*` の環境変数は、どちらの経路でも立たなかった。
/// 環境変数を読まないので、起動時に読むものの登録簿 (``StartupReads``) の外にある。
///
/// **束の名前を変えると、黙って外れる** — 検査の中でも「外」と判定し、止まらなくなる。
/// `SelfTestTests` が検査の中でこれが真であることを確かめるので、割れたら赤になる。
///
/// [#1682]: https://github.com/mokume-metal/mokume/issues/1682
enum SelfTest {
    /// mokume の検査の束の名前。`Package.swift` の `testTarget` と、パッケージ名 (`mokume`) から
    /// SwiftPM が付けるまとめた束の名前。
    static let bundleNames = ["mokumePackageTests", "MokumeCoreTests", "MokumeCLITests"]

    /// 起動の引数から 1 度だけ判定する。引数は走っている間に変わらない。
    static let isRunning: Bool = isRunning(arguments: CommandLine.arguments)

    /// 引数の並びが、mokume の検査の束の実行ファイルを含むか。
    static func isRunning(arguments: [String]) -> Bool {
        arguments.contains { argument in
            bundleNames.contains { argument.contains("/\($0).xctest/") }
        }
    }
}
