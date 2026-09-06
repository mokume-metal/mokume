# Contributing

mokume への貢献を歓迎する。**Issue・PR はどの言語で出してもよい** — メンテナが日本語で作業しているだけで、リポジトリとして言語は強制しない ([ADR-0001](docs/decisions/0001-founding-principles.md) 原則 10)。

## 規約の正典は AGENTS.md

Issue の起票から PR のマージまで、守ることは [AGENTS.md](AGENTS.md) にまとまっている。人間にも AI エージェントにも同じ規約が効くので 1 本にしている。

**この文書は入口で、規約の写しは持たない。** 写しは必ず古くなるためである ([ADR-0001](docs/decisions/0001-founding-principles.md) 原則 9 — 同じ内容の二重管理を作らない)。

初めての貢献なら、AGENTS.md の次の節から読むと早い:

| 知りたいこと | AGENTS.md の節 |
| --- | --- |
| 何から始めるか | **進め方** — 起票は雑でよいが、着手は完了条件が固まって `verify: triaged` が付いてから |
| Issue に何を書くか | **Issue の分類** — 型は Issue Type、ラベルは状態と完了条件の性質 |
| 経過をどこに残すか | **コメント** — PR ができるまでは Issue、できてからは PR |
| PR の出し方 | **コミット・PR の規約** — Conventional Commits・1 PR は 1 つの説明で筋が通る範囲・`Closes #N` は本文に・「確認方法」に完了条件の対応表 |
| いつマージされるか | **マージの判断基準** — `ci-gate` が green で、必要なら承認 |
| やってはいけないこと | **してはならないこと** — 帰属の不明なファイル・生成物のコミット・実需のない先回り |
| 見た目が変わる変更 | **描画に影響する変更** — before/after の絵を PR に載せる (入力欄へ落とせば GitHub が保管する) |

## 手元で作る

入れ方 (`brew install`) は [README](README.md#入れる) にある。ここが持つのは、**このリポジトリから道具を作る手順**である — リリースを待たずに試すとき、ライブラリを触りながらスケッチで確かめるときに使う。

```bash
git clone https://github.com/mokume-metal/mokume.git
cd mokume
swift build -c release --product mokume-cli
export PATH="$PWD/.build/release:$PATH"   # この shell の間だけ
```

できるのは `mokume-cli` — 配布物の `mokume` と同じ道具で、名前だけが違う (道具は起動された名前で名乗るので、印字される行はそのまま打てる)。ひな形の入った `mokume_MokumeCLI.bundle` は隣に作られるので、**実行ファイルだけを別の場所へ移さない**。

スケッチにも手元のライブラリを引かせるなら、`--local` でこのリポジトリの場所を渡す:

```bash
cd ..
mokume-cli new --local ../mokume my-sketch
cd my-sketch
mokume-cli run
```

渡した場所は生成される `Package.swift` の `.package(path:)` へそのまま入るので、**作られるスケッチから見た相対**で書く (絶対パスでもよい)。`--local` を付けなければ、公開済みの版を引く。

## 設計の背景

- 土台となる原則: [ADR-0001 設計原則](docs/decisions/0001-founding-principles.md)
- 個別の設計判断: [docs/decisions/](docs/decisions/) の ADR (状態 / 文脈 / 決定 / 影響 の 4 節・自己完結で書く)

「なぜこうなっているか」はここに書いてある。規約に納得できないときは、まず該当する ADR を読んでほしい。それでも違うと思ったら Issue を立ててよい — ADR は改訂できる。
