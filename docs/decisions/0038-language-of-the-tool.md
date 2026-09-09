<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# ADR-0038: 道具が話す言葉は英語、読み物は日本語

## 状態

採用 (2026-09-09)

## 文脈

`mokume-cli` の help・エラー・`doctor`・`watch` の進捗と確認ダイアログ・エージェントの窓口が返す説明文、そしてスケッチ実行時に窓へ描かれる速さの名乗り・診断の警告・メニューバーの名乗り・起動失敗の告知は、**すべて日本語で書かれている**。

一方で mokume は「スケッチを書いて絵を出す」道具であり、**それを使って作品を作る人は日本語話者に限らない**。道具が日本語しか話さないことは、利用者を言語で選別している。

### この問いは「面の言語」であって「プロジェクトの言語」ではない

[ADR-0001](0001-founding-principles.md) 原則 10 は「言語を強制しない」と定め、メンテナの実践として規約文書・コミット・Issue が日本語であることを述べている。これは**このリポジトリを触る人**に向いた記述で、**道具が利用者へ話す言葉**を決めてはいない。

同じことが [ADR-0027](0027-readable-surfaces.md) 決定 4 にも言える。あちらが「日本語 1 言語で出す」と決めたのは**読み物の面** (公開 API の参照・入口の 1 枚) であって、道具の表示ではない。

**面ごとに読み手が違えば、言語も違ってよい。** ADR-0027 決定 2 は絵の形式について既に同じ形を採っている — 参照の面には GIF、Issue / PR には WebP と、配信系の能力が違えば答えが違ってよい。ただしそこは「違う結論を持つ以上、なぜ違うかは両方の場所に書く」という条件を付けている。本 ADR も同じ条件で立つ。

### 測ったこと (2026-09-09)

| 対象 | 件数 |
| --- | ---: |
| 利用者に見えるメッセージ (`Sources/` 全体) | **395** |
| └ `Sources/MokumeCLI/` | 177 |
| └ `Sources/MokumeCore/` | 210 |
| └ `Sources/MokumeMacros/` (コンパイル時診断) | 5 |
| うち文字列補間つき | 196 (引数 1 個が 124・最大 6 個) |
| 助数詞・数の一致が要るもの | 30 |
| 文言に依存している検査 | **118** |
| `Schemas/*.schema.json` の `description` / `title` | 95 |
| CI スクリプトが文言を完全一致で握っている箇所 | 2 |

`Sources/MokumeDiagnostics/` と `Sources/mokume/` は 0 件である。`Diagnostics` は接頭辞と改行だけを持つ薄い口で、文面は全部呼び出し側にある。

**文を語のスロットから組み立てているヘルパが 9 型あり、差し替え語は約 85 個ある。** `Drawing/OutsideFrame.swift` は `opening` +「初期化のときに」+ `pastVerb` + `subject` +「はどのフレームにも属さないため、無視しました」の 3 スロットで 9 通の警告を作る。日本語の語順と助詞に依存しており、そのままでは英語にならない。

**この形は日本語でも既に一度事故っている。** 同じファイルが「「た」まで含めて持つ。語幹だけにして `\(pastVerb)た` と組むと、音便のある動詞が濁らない — 実際に畳んだとき「頼んだ」が「頼んた」になった」と記録している。

## 決定

### 1. 道具が話す言葉は英語、読み物は日本語

線は**読み手**で引く。

| | 道具が話す言葉 | 読み物 |
| --- | --- | --- |
| 中身 | 標準出力・標準エラー・GUI・JSON 応答として**プロセスが外へ出す文字列** | コードのコメントと説明文 (`///`)・ADR・README・CONTRIBUTING・`mokume new` が生成するテンプレート |
| 読み手 | mokume で作品を作る人 (世界中に居る) | このリポジトリを触る人 |
| 言語 | **英語** | **日本語** |

参照の面 (docc) は読み物なので日本語のままである。日本語で書いたものから英語の面を機械で作れないかは [#1106](https://github.com/mokume-metal/mokume/issues/1106) が引き受ける — **本 ADR は読み物の言語を動かさない。**

`Sources/frame-rate-probe/` は対象外である。`Package.swift` の `products` に無く、配布物に入らない。

### 2. 切替は持たない

環境変数やロケールで日本語へ戻す口は**作らない**。

- **CLI とボタンに出るのは難しい英語ではない。** 日本語話者も英語のまま使える
- **2 言語ぶんの文言を維持する機構は、実害が示されてから足す** ([ADR-0008](0008-mechanism-needs-demonstrated-harm.md) 決定 1)。日本語が要ると分かった日には git の履歴から戻せる

**将来切替を持つとなったときに踏む罠だけ、測ったので残す** (使い捨てパッケージ・Swift 6.3.3 / macOS 26.6.2 / 機械のロケールは `ja_JP`)。

| 測ったこと | 実測 |
| --- | --- |
| `.xcstrings` (String Catalog) | **SwiftPM がコンパイルしない。** 包みへ素通しでコピーされるだけで `.lproj` が 1 つも作られない。**ビルドは緑のまま、実行時に全キーが引けない** |
| `String(localized:locale:)` に `Locale("en")` を渡す | **言語テーブルの選択に効かない。** 素の CLI では偶然英語になるが、`.app` の main バンドルが `ja` を持った瞬間、`en` を渡しているのに日本語が返った |
| OS 既定が英語になるか | **偶然である。** main バンドルに `ja.lproj` を 1 つ置いただけで全部日本語へ反転した |
| 単体バイナリ配布 (`.build` を退避して 5 通り) | 実行ファイルだけ → `Fatal error: could not load resource bundle` / **`Foo.app/Contents/Resources/*.bundle` (`bundle` が作る形) → `Fatal error`** |

`Bundle.module` の生成コードは候補を 2 つしか見ず、外れると `fatalError` で落ちる。2 つ目は**組み上げた機械の絶対パス**なので、`.build` が生きている作者の手元では常に成功し**配った先だけで落ちる**。この壊れ方は既に 2 回踏んでおり ([#1058](https://github.com/mokume-metal/mokume/issues/1058) / [#1059](https://github.com/mokume-metal/mokume/issues/1059))、`Rendering/ModuleResources.swift` が自前の解決器で凌いでいる。**`MokumeCLI/Templates.swift` はいまも生の `Bundle.module` を使っている** — 将来ここへ文言を載せるなら、CLI 側にも同じ解決器が要る。

### 3. 語のスロットへ名詞や動詞句を流し込む形は残さない

文言は**完全な文として持つ**。「文の骨組みを 1 つ持ち、名詞や動詞句を差し替えて N 通りを作る」形は畳む。

- **日本語で成り立っていたのは語順と助詞が固定だからで、英語では成り立たない。** 動詞と目的語の位置が入れ替わり、語ごとに前置詞と冠詞が変わる
- **日本語でも一度事故っている** (上の「測ったこと」の音便)。骨組みを共有する節約より、**1 文ずつ読める**ことを採る

畳む対象は `Drawing/OutsideFrame.swift` (3 スロット 9 通)・`Rendering/RenderFailure.swift` の `exhausted(_ what:)` (名詞 8 種)・`Rendering/RenderDevice.swift` の助詞違い 2 テンプレ (動詞句 10 種)・`Exchange/AtomicFile.swift` の `publishJSON` (語 5 種)・`Drawing/ShaderBox.swift` ほか。

**同じ規律は条件で語を差し替える形にも効く。** `"Package.swift が\(present ? "在る" : "無い")"` のように文の途中で語を選ぶ 26 箇所も、文単位に組み直す。

### 4. 切替を持てない面も英語一本

| 面 | なぜ持てないか |
| --- | --- |
| `Schemas/*.schema.json` の `description` / `title` | ファイルが 1 つで、読み手はエージェントである。**機械が突き合わせる語 (`enum` 値・`const`・`default`) は元から英語**なので、動くのは説明文だけ |
| `MokumeMacros` のコンパイル時診断 | macro はビルド中にコンパイラの中で走り、実行時の環境を持たない |

## 影響

- **文言に依存している検査 118 件が英語の綴りへ動く。** 内訳は `Tests/MokumeCLITests/` が 101、`Tests/MokumeCoreTests/` が 24 (うち偽陽性 7)
- **`scripts/check-param-declarations.sh` が `grep -qF` で握っている 2 つの綴りは、macro の診断と同じ PR で動かす。** 順序を違えると `make ci-check` が落ち、`local-render` が打たれず**描画 PR が merge できなくなる**
- `README.md`・[ADR-0029](0029-post-run-surfaces.md)・`changelog.d/` 4 本に転写された `doctor` の出力例が動く。**断片は消さない** (リリースノートの材料なので中身だけ直す)
- `Sources/MokumeCore/` は `scripts/drawing-paths.txt` に載っているので、Core の文言を触る変更は描画 PR として扱われる。窓に描かれる文言 (速さの名乗り・メニューバー) は**実際に絵が動く**ので証跡が要り、標準エラーだけに出る文言は `no-visual-change` になる
- ADR-0027 決定 4 の側にも線を書く (決定 2 が課した「なぜ違うかは両方の場所に書く」の条件)
- **[ADR-0001](0001-founding-principles.md) 原則 10 は動かさない。** あれはメンテナの実践であって、道具の表示の話ではない
- 工程は [#1104](https://github.com/mokume-metal/mokume/issues/1104) の sub-issue 9 本に割る。**面ごとに段を分けるので、途中の main には言語が混ざった状態が残る**
