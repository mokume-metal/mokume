// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 1 回の実行で 1 度だけ決める、作るときの土台。
///
/// ## なぜ 1 つの値にするのか
///
/// 構成と置き場は**作り直しと実行ファイルの解決の両方**へ渡さなければならない。片方だけに
/// 渡すと、名乗ったものと実際に起動するものが食い違う — 構成でそれを踏んだのが
/// [#680](https://github.com/mokume-metal/mokume/issues/680) で、置き場でも同じことが
/// 起きる (作り直しは共有の置き場・解決はパッケージ直下、という組み合わせになる)。
///
/// **抱き合わせておけば、片方だけ渡すことが書けなくなる。**
///
/// ## product の名前も一緒に持つ
///
/// 「いま建ったか」を確かめるのに要る。共有の置き場では前のスケッチの実行ファイルが
/// 同じ名前で残っていることがあり、**在るかどうかでは騙される**
/// ([#1055](https://github.com/mokume-metal/mokume/issues/1055) — 置き場の計画が古いと
/// `swift build` は「Build complete!」と言って何も作らない)。
///
/// **まだ分からないこともある。** 宣言が読めないスケッチでは名前を取れないが、そこで
/// 見張るのを断ってはいけない — `Package.swift` を壊した状態から直していく途中は**まさに
/// 見張っていてほしい場面**である。分からないときは `nil` にして、作り直しの後に読み直す。
/// その場合の置き場は必ずパッケージ直下なので、取り違えの危険はそこには無い。
nonisolated struct BuildContext: Equatable {
    /// 選ばれた構成。**渡されなければ道具立ての既定に任せる** — ここで既定を書き固めると、
    /// 道具立てが既定を変えた日に黙ってずれる。
    let configuration: String?
    /// ビルドの置き場。
    let place: BuildDirectory.Place
    /// 走らせる実行ファイル (宣言された executable product) の名前。**読めなければ `nil`。**
    let product: String?

    /// 道具立てへ渡す引数。
    ///
    /// **`build` にも `--show-bin-path` にも、これを渡す。** 検査はこの配列の等値で
    /// 「両方に同じものが渡っている」を固定できる。
    var arguments: [String] {
        RunCommand.configurationArguments(configuration) + place.arguments
            + Self.indexStoreArguments
    }

    /// 編集器のための索引を建てさせない綴り。
    ///
    /// `swift build` の既定は `--auto-index-store` で、debug 構成では**編集器
    /// (SourceKit-LSP) のための索引**を建てる。`run` / `watch` はこれを 1 バイトも
    /// 読まない ([#1070](https://github.com/mokume-metal/mokume/issues/1070))。
    ///
    /// **編集器も、ここに建った索引は読まない。** Swift 6.1 以降 SourceKit-LSP は
    /// 背景で索引を建てるのが既定で、置き場は開いているパッケージの
    /// `.build/index-build` である。[#1055](https://github.com/mokume-metal/mokume/issues/1055)
    /// でビルドの置き場が部屋 (`~/Library/Caches/mokume/build/…`) へ出た後は、
    /// **編集器が覗く場所と道具が建てる場所が別のディレクトリになる**ので、共有できる
    /// 余地そのものが無い。
    ///
    /// **`build` だけでなく `--show-bin-path` にも渡す。** 綴りを ``arguments`` の
    /// 1 箇所に乗せておけば、片方だけに渡すことが書けない
    /// ([ADR-0037](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0037-shared-build-directory.md)
    /// 決定 6 / [#680](https://github.com/mokume-metal/mokume/issues/680) と同じ形)。
    ///
    /// **食い違わせた場合の値段は測ったが、いまの道具立てでは出なかった** —
    /// `--show-bin-path` だけ既定にしても次のビルドは 0.45s のままで、逆向きも同じ
    /// (Swift 6.3.3)。だからここで守っているのは実測の秒数ではなく、**構成と置き場と
    /// 同じ形に揃えておく**ことである。道具立てが `--show-bin-path` の副作用を変えた
    /// 日に、揃っていない側だけが黙ってずれる。
    ///
    /// release 構成では既定でも索引は建たないので、`bundle` の振る舞いは変わらない
    /// (渡しても建たないものが建たないままである)。
    static let indexStoreArguments = ["--disable-index-store"]

    /// 名乗るときの構成の名前。選ばれていなければ既定の名前。
    var configurationName: String { configuration ?? RunCommand.defaultConfigurationName }

    /// ビルドの置き場そのもの (`workspace-state.json` と `checkouts/` を読む側が使う)。
    func directory(under package: URL) -> URL { place.directory(under: package) }
}
