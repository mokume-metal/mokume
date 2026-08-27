# changelog.d

ユーザー影響のある変更 1 件につき 1 ファイルを置く。リリース時に集約されて CHANGELOG.md へ昇格する (断片はその時点で削除)。

## 形式

ファイル名は `<slug>.<category>.md`。

- `<slug>`: 変更を表す短い kebab-case (例: `add-noise-api`)
- `<category>`: `feature` / `fix` / `docs` / `perf` / `breaking`

中身は **SPDX ヘッダ (HTML コメント) + Markdown の 1 段落**。次をそのままコピーして、本文だけ書き換える — 例は `changelog.d/add-noise-api.feature.md`:

```markdown
<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

2 次元のパーリンノイズを引く `noise(x:y:)` を追加した。同じ座標には常に同じ値が返るので、フレームをまたいで安定した模様を描ける。
```

本文はリリースノートにそのまま載る文として書く (「何ができるようになったか / 何が直ったか」を利用者の言葉で)。破壊的変更は `.breaking.md` とし、移行手順を必ず含める。

## なぜ SPDX ヘッダが要るか

断片は**数が増えていくファイル群**なので、帰属は `REUSE.toml` の共有配列ではなく自ファイルのヘッダで宣言する。独立した変更の帰属宣言が同じ配列に集まると、中身が無関係でも 3-way merge が conflict と判定するためである ([#149](https://github.com/mokume-metal/mokume/issues/149))。`REUSE.toml` の冒頭コメントが定める基準どおりで、ADR (`docs/decisions/`) も同じ形をとる。

ヘッダを忘れると `reuse lint` が断片を名指しして落ちる (`make ci-check` が赤)。`REUSE.toml` にワイルドカードを書いて `changelog.d/` を包むことはしない — 帰属不明のファイルが混入したら落ちるのが望む挙動である。

## 集約するときの要件

リリース時に断片を CHANGELOG.md へ昇格させる機構を作るときは、**SPDX ヘッダを除いて昇格する**こと。ヘッダは断片ファイルの帰属を宣言するためのもので、リリースノートの文面ではない。

集約器はまだ無いので、この要件を守らせる検査も置いていない ([ADR-0008](../docs/decisions/0008-mechanism-needs-demonstrated-harm.md) 決定 2 — 実害 → Issue → 機構)。
