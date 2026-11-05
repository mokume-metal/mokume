# changelog.d

ユーザー影響のある変更 1 件につき 1 ファイルを置く。リリースのとき、**前回のタグ以降に追加された断片**が集約されて [GitHub Release](https://github.com/mokume-metal/mokume/releases) の本文になる。

**断片は消さない。** どれが今回の分かは git の履歴から分かるので、消す必要が無い — 消すにはリリースがコミットを作ることになり、そのために PR と必須チェックを通す仕組みが要る (判断は `scripts/release.py` の冒頭)。溜まって見通しが悪くなったら、そのとき整理する ([ADR-0008](../docs/decisions/0008-mechanism-needs-demonstrated-harm.md))。整理する時期と移す先は下の「整理のきっかけと移す先」。

**断片が 1 つも増えていなければリリースは出ない。** 中身の無いリリースを出さないため。

## 整理のきっかけと移す先

**1.0 のタグを付けた後に、1 回だけ整理する。** 1.0 は `scripts/release.py` が自動では出さず (0.x の間は破壊的変更も minor で出す)、メンテナが決めて出すバージョンなので、きっかけは「メンテナが 1.0 を出した後」になる。1.0 までのリリースノートに載った断片を、`changelog.d/archive/<1.0 のタグ>/` (例 `changelog.d/archive/v1.0.0/`) へ、**中身を変えずに `git mv` で移す** PR を 1 本出す。**消さない** — 断片はリリースノートの材料で、作業ツリーから過去の断片を引けるようにしておく。

移す PR では、次を確かめてから出す。

- `python3 scripts/release.py notes` を実行し、**移しただけの断片が次のリリースノートに載らない**こと。リリースは `git diff --diff-filter=A` で「前回のタグ以降に追加された断片」を拾うので、移した断片が rename (`R`) として検出されれば対象から外れる。中身を変えて類似度が下がる (既定は 50%) と、追加 (`A`) とみなされて再掲される
- `python3 scripts/release.py lint` が通ること (書式のチェックは直下の `*.md` だけを見るので、`archive/` の下は数えない)

再掲が見つかったら、その PR で修正とテスト (`scripts/tests/release_test.py`) を一緒に入れる。移す時より前には、再掲を防ぐテストは置かない。

## 形式

ファイル名は `<slug>.<category>.md`。

- `<slug>`: 変更を表す短い kebab-case (例: `seedable-random-and-noise`)
- `<category>`: リリースノートの見出しに対応する分類。**定義は `scripts/release.py` の `SECTIONS` にある** — ここに名前を書き写すと二重管理になるので並べない。使える名前は `python3 scripts/release.py lint` が具体的に示す

この形式は `make ci-check` の `changelog-lint` がチェックしている ([#91](https://github.com/mokume-metal/mokume/issues/91))。名前・分類のほか、**本文が空でないこと**と、**リンクが絶対 URL であること** (相対パスと reference style はリリースノートに載った時点で壊れる) もチェックする。

中身は **SPDX ヘッダ (HTML コメント) + Markdown の本文**。段落はいくつ書いてもよい — リリースノートを生成する側が全部を 1 つの項目に収める ([#446](https://github.com/mokume-metal/mokume/issues/446))。次をそのままコピーして、本文だけ書き換える — 例は `changelog.d/seedable-random-and-noise.feature.md`:

```markdown
<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

座標を渡すと 0…1 が返る `noise()` を追加した。同じ座標には常に同じ値が返るので、フレームをまたいで安定した模様を描ける。
```

本文はリリースノートにそのまま載る文として書く (「何ができるようになったか / 何が直ったか」を利用者の言葉で)。**最初の 1 文が要約としてリリースノートに表示され、要約をクリックすると続きが開く** ([#2766](https://github.com/mokume-metal/mokume/issues/2766)・[#2871](https://github.com/mokume-metal/mokume/issues/2871)) ので、最初の 1 文だけで何が変わったかが分かるように書く。破壊的変更は `.breaking.md` とし、移行手順を必ず含める。

## なぜ SPDX ヘッダが要るか

断片は**数が増えていくファイル群**なので、帰属は `REUSE.toml` の共有配列ではなく自ファイルのヘッダで宣言する。独立した変更の帰属宣言が同じ配列に集まると、中身が無関係でも 3-way merge が conflict と判定するためである ([#149](https://github.com/mokume-metal/mokume/issues/149))。`REUSE.toml` の冒頭コメントが定める基準どおりで、ADR (`docs/decisions/`) も同じ形をとる。

ヘッダを忘れると `reuse lint` が断片のファイル名を示して失敗する (`make ci-check` が失敗する)。`REUSE.toml` にワイルドカードを書いて `changelog.d/` を包むことはしない — 帰属不明のファイルが混入したら失敗するのが望む挙動である。

## 集約するときの要件

リリース時に断片を CHANGELOG.md へ集約する仕組みを作るときは、**SPDX ヘッダを除いて集約する**こと。ヘッダは断片ファイルの帰属を宣言するためのもので、リリースノートの文面ではない。

集約するスクリプト (`scripts/release.py`) はこの要件を満たしている — `body_of()` が HTML コメントを取り除いてから本文を作り、`as_entry()` が最初の文を要約にし、本文をまるごと折りたたんで 1 つの項目に収める。
