# AGENTS.md

このリポジトリで作業する AI エージェント (と人間) 向けの規約。

## プロジェクト

mokume は macOS / Apple Silicon 専用のクリエイティブコーディング環境 (Swift + Metal)。宣言的・フレームベースのスケッチ API を提供する。**現在は設計フェーズ** — ライブラリのコードはまだ無く、作業は `docs/decisions/` (ADR) と GitHub Issues で進んでいる。

## 正典の在処

- 設計判断: `docs/decisions/` の ADR (状態 / 文脈 / 決定 / 影響 の 4 節・自己完結で書く)
- 作業の経過・発見・残タスク: GitHub Issues / PR (ローカルファイルやセッション記憶に残さない)
- プロジェクトの土台: [ADR-0001 設計原則](docs/decisions/0001-founding-principles.md)

## 進め方

1. 変更は **Issue 起票から始める** (目的・完了条件を書く)。複数工程は親 Issue + sub-issue で構成し、本文チェックリストは使わない
2. **着手時に、その時点のプラン (変更点・確認方法) を対象 Issue にコメントで残す**。実装の過程でプランが変わったら、そのコメントへの返信で差分を残す
3. `main` から `<type>/<短い説明>` ブランチを切る
4. PR を出す。本文は 目的 / 変更点 / 確認方法、Issue を閉じる `Closes #N` は PR 本文に書く (squash merge ではコミット側の記述は GitHub に届かない)
5. マージは squash のみ。**PR タイトルがそのままマージコミットになる**ので Conventional Commits で書く

## コメントの署名

同じ Issue / PR には人間も複数のエージェントも書き込む。AI エージェントが投稿するコメントは、発言の出どころが後から判別できるよう本文末尾に署名を付ける:

```markdown
---
<sub>🤖 Assisted by [Claude Code](https://claude.com/claude-code)</sub>
```

## エージェント環境の設定

`.claude/settings.json` (プロジェクト設定) が頻用コマンドの許可リストと、作法を supply するプラグイン (`repo-standards@shinyaoguri`) の宣言を持つ。設定はあくまで補助で、**作法の正典はこの文書**。リポ固有の Claude スキルを作る場合は `.claude/skills/` に置く (現状なし — コードが育ってから)。

## コミット・PR の規約

- Conventional Commits: `<type>(<scope>): <要約>`。type は feat / fix / docs / refactor / test / chore / ci / perf / build。type と scope は英語、要約は日本語でよい
- 1 コミット 1 関心・1 PR 1 関心
- 検証は `make ci-check` に集約する (CI はそれを呼ぶだけ)。push 前に通す
- ユーザー影響のある変更は `changelog.d/` に断片を 1 ファイル置く (CHANGELOG を直接編集しない)

## してはならないこと

- 生成物・バイナリ (画像・動画・モデル) をコミットしない。視覚的な証跡は外部ホスティングへ上げ URL で参照する
- 帰属 (著作権・ライセンス) の不明なファイルを持ち込まない。第三者素材は正確な帰属の宣言と同時にしか入れられない
- 想定だけの API を先回りで作らない。機能は実際の作品制作で踏まれた必要から正当化する (ADR-0001 原則 4)

## 描画に影響する変更

描画結果・動きが変わる PR には before/after の視覚的証跡を載せる (動きは動きの分かる形式で)。証跡はリポジトリにコミットせず、外部ホスティングの URL で参照する。

## 言語

メンテナは日本語で作業する (このリポジトリの規約文書・コミット・PR・Issue は基本日本語)。ただしこれはメンテナの実践であって強制ではない — どの言語での Issue・コントリビューションも歓迎する。コードの識別子は英語。
