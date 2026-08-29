# changelog.d

ユーザー影響のある変更 1 件につき 1 ファイルを置く。リリースのとき、**前回のタグ以降に追加された断片**が集約されて [GitHub Release](https://github.com/mokume-metal/mokume/releases) の本文になる。

**断片は消さない。** どれが今回ぶんかは履歴が知っているので、消す必要が無い — 消すにはリリースがコミットを作ることになり、そのために PR と必須チェックを通す仕掛けが要る (判断は `scripts/release.py` の冒頭)。溜まって見通しが悪くなったら、そのとき整理する ([ADR-0008](../docs/decisions/0008-mechanism-needs-demonstrated-harm.md))。

**断片が 1 つも増えていなければリリースは出ない。** 中身の無い版を出さないため。

## 形式

ファイル名は `<slug>.<category>.md`。

- `<slug>`: 変更を表す短い kebab-case (例: `seedable-random-and-noise`)
- `<category>`: `feature` / `fix` / `docs` / `perf` / `breaking`

中身は **SPDX ヘッダ (HTML コメント) + Markdown の 1 段落**。次をそのままコピーして、本文だけ書き換える — 例は `changelog.d/seedable-random-and-noise.feature.md`:

```markdown
<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

座標を渡すと 0…1 が返る `noise()` を追加した。同じ座標には常に同じ値が返るので、フレームをまたいで安定した模様を描ける。
```

本文はリリースノートにそのまま載る文として書く (「何ができるようになったか / 何が直ったか」を利用者の言葉で)。破壊的変更は `.breaking.md` とし、移行手順を必ず含める。

## なぜ SPDX ヘッダが要るか

断片は**数が増えていくファイル群**なので、帰属は `REUSE.toml` の共有配列ではなく自ファイルのヘッダで宣言する。独立した変更の帰属宣言が同じ配列に集まると、中身が無関係でも 3-way merge が conflict と判定するためである ([#149](https://github.com/mokume-metal/mokume/issues/149))。`REUSE.toml` の冒頭コメントが定める基準どおりで、ADR (`docs/decisions/`) も同じ形をとる。

ヘッダを忘れると `reuse lint` が断片を名指しして落ちる (`make ci-check` が赤)。`REUSE.toml` にワイルドカードを書いて `changelog.d/` を包むことはしない — 帰属不明のファイルが混入したら落ちるのが望む挙動である。

## 集約するときの要件

リリース時に断片を CHANGELOG.md へ昇格させる機構を作るときは、**SPDX ヘッダを除いて昇格する**こと。ヘッダは断片ファイルの帰属を宣言するためのもので、リリースノートの文面ではない。

集約器はまだ無いので、この要件を守らせる検査も置いていない ([ADR-0008](../docs/decisions/0008-mechanism-needs-demonstrated-harm.md) 決定 2 — 実害 → Issue → 機構)。
