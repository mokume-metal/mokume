## 実測の段の共通の指示 (必ず守る)

- 計測用の作業木: `/private/tmp/claude-501/-Users-so-Repos-mokume--claude-worktrees-issue-1986-fdcf54/b8bd4529-b5f1-482d-af03-aa1d0b3944f8/scratchpad/perf` (origin/main `58eea05c` を detach で置いた使い捨ての木)。**`Sources/` は一切変えない**。触ってよいのは、あなたの担当の計測ファイル (`Tests/<target>/PerfReview<群>Tests.swift`) だけ。ほかの群のファイルは触らない (コンパイルが通らなければ報告して止まる)
- コマンドは `cd` せず、`swift ... --package-path <作業木>` か `bash -c 'cd <作業木> && …'` の形で打つ。gpu-slot は `python3 <作業木>/scripts/gpu-slot.py`
- 手順:
  1. ビルド: `swift build --build-tests -c release -Xswiftc -enable-testing --package-path <作業木>` (release は温まっている。差分だけ組む)。コンパイルが通るまで担当のファイルだけを直す。直すときは、測る中身 (場面・回数・指標) を変えない。どうしても変えるなら理由を報告に書く
  2. 実行: `bash -c 'cd <作業木> && python3 scripts/gpu-slot.py --exclusive -- swift test -c release -Xswiftc -enable-testing --skip-build --filter "<Suite の型名>" 2>&1'` を、**Suite 1 つずつ単発で**。同じものを 2 回以上走らせるのは、揺れが大きく値が読めないときの 1 回の追試までにする (`--repeat-until` や繰り返しは禁止 — GPU を詰まらせると手元機の画面ごと落ちる)
  3. 出力から `PERF\t` で始まる行を全部集める。走らせた直前に `uptime` (負荷) と `pmset -g therm` を記録する
- 走らせて期待と大きく違う値が出たら、計測コードの誤りか、指摘の誤りかを切り分ける (計測コードを読み直し、必要なら内部の経路を確かめる)。指摘が外れていたら、外れたと書く
- Issue / PR には書き込まない

## 返すもの (日本語、最終メッセージに本文で全部)

1. 環境: 機種 (Apple M3 Max)・OS・Swift のバージョン・ビルド構成・負荷と熱
2. Issue ごとの実測の表 (場面 / 指標 / 中央値 / p90 / 最小 / 回数)。生の PERF 行も末尾に付ける
3. 読み取り: 指摘の主張 (Issue 本文と、再検証の報告が渡されていればそれ) と比べて、何が確かめられ、何が外れ、影響は本文の見積もりより大きいか小さいか
4. 計測コードの最終版 (Issue に貼れるよう、場面ごとの要点だけでよい。全文は作業木のファイルにある)
5. 計測で気付いた別件 (正しさの問題など)
