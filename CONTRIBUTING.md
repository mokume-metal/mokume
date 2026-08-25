# Contributing

mokume への貢献の手引き。日本語で書かれているが、**Issue・PR はどの言語で出してもよい** (メンテナが日本語で作業しているだけで、リポジトリとして言語は強制しない)。

## 開発フロー

1. まず Issue を立てる (目的と完了条件)。既存の Issue に着手する場合はその旨をコメントする
2. `main` から `<type>/<短い説明>` ブランチを切る
3. 変更は小さく — 1 PR 1 関心
4. push 前に `make ci-check` を通す (CI と同一の検査)
5. PR の本文は 目的 / 変更点 / 確認方法。Issue を閉じる場合は `Closes #N` を本文に書く
6. マージは squash のみ。PR タイトルがそのまま `main` のコミットメッセージになるため、[Conventional Commits](https://www.conventionalcommits.org/ja/) で書く: `<type>(<scope>): <要約>` (type: feat / fix / docs / refactor / test / chore / ci / perf / build)

## ルール

- **帰属の宣言**: すべてのファイルに著作権とライセンスの帰属が必要 (SPDX ヘッダ、または帰属宣言ファイルへの明示的な記載)。第三者素材は正確な帰属の宣言と同時にしか持ち込めない
- **生成物・バイナリをコミットしない**: 画像・動画などの証跡は外部ホスティングへ上げ、URL で参照する
- **描画に影響する変更は絵で検証する**: before/after の視覚的証跡を PR に載せる (動きが変わる場合は動きの分かる形式で)
- **ユーザー影響のある変更**は `changelog.d/` に断片ファイルを 1 つ置く (CHANGELOG を直接編集しない)
- **設計判断**は `docs/decisions/` に ADR として記録する (状態 / 文脈 / 決定 / 影響 の 4 節・自己完結)

土台となる原則は [ADR-0001](docs/decisions/0001-founding-principles.md) を参照。
