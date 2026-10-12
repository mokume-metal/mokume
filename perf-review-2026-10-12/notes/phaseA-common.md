## 共通の前提 (必ず守る)

- リポジトリは mokume-metal/mokume。**読むのは計測用の作業木 `/private/tmp/claude-501/-Users-so-Repos-mokume--claude-worktrees-issue-1986-fdcf54/b8bd4529-b5f1-482d-af03-aa1d0b3944f8/scratchpad/perf`** (origin/main `58eea05c` を detach で置いたもの)。`cd` はしない。絶対パスと `git -C <その木>` を使う
- Issue の本文は `gh issue view <番号> -R mokume-metal/mokume` で読む。各 Issue は 2026-10-12 の静的レビューで起票したもので、対象は 1 つ前の `92c61ba6`。行番号はずれているかもしれない
- **Issue / PR へは書き込まない。ビルド・テスト・GPU を使うものは走らせない** (ほかのエージェントと並行しているため。計測は後で別の段が 1 本ずつ行う)。`git log` / `git blame` / `gh` での読み取りは自由
- 書いてよいファイルは `/private/tmp/claude-501/-Users-so-Repos-mokume--claude-worktrees-issue-1986-fdcf54/b8bd4529-b5f1-482d-af03-aa1d0b3944f8/scratchpad/perf/PerfDrafts/<群の名前>.swift` の 1 つだけ (計測コードの下書き。コンパイルされない場所)

## Issue ごとにやること

1. **事実の再確認**: 本文の主張を現行コード (58eea05c) で 1 つずつ辿り直す。行番号を今のものに直す。呼び出し元・分岐の条件も確かめ、本文が見落とした分岐 (既に回避されている場面・逆に本文より広く効く場面) が無いか見る。主張ごとに「確認」「訂正 (正しくは…)」「反証」のどれかを付ける
2. **原因の考察**: `git log -S` / `git blame` と、関係する Issue・PR・ADR を引き、なぜこの形になったか (意図した代償か・後から入ったか・見落としか) を書く。番号と根拠を添える
3. **影響範囲**: どの公開 API・書き方がこの経路に乗るか。`Sketches/` と `Documentation/` の作例・文書のどれが該当するか (grep で数える)。効かない場面も書く
4. **実測の設計と下書き**: 具体的な場面 (入力・大きさ・回数) を決め、前後比較ではなく**いまの費用の大きさ**を測る計測コードを、上の下書きファイルに Swift Testing で書く。書き方:
   - `import Foundation`、`import Metal`、`import Testing`、`@testable import MokumeCore` (音は `@testable import MokumeAudio` も)
   - `@Suite("PerfReview <群の名前>", .serialized, .enabled(if: RenderDevice.isAvailable, "GPU が無い"))`。GPU を使わない計測は `.enabled` を外してよい
   - Canvas は `try CanvasFixture.make(gpu: RenderDevice(), width:, height:)` で作る (`Tests/MokumeCoreTests/CanvasFixture.swift`)。描くのは `try canvas.draw { … }`
   - 時間は `ContinuousClock` で、暖機 3 回の後に 15〜30 回測り、中央値・p90・最小を出す。`print("PERF\t<Issue番号>\t<場面>\t<指標>\t<値>\t<単位>")` の 1 行形式で出す (後で grep で集める)
   - 使える計数: `canvas.drawCallsInLastFrame`、`canvas.flatVerticesInLastFrame`、`RenderDevice` の `slotWaits` / `blockingWaits` / `ringWaits` (どれも internal なので `@testable` で読める)。GPU 時間の口は無いので、GPU の仕事を見たいときは「描いて決着を待つまでの壁時計」と「CPU の組み立てだけ」を分けて測る
   - 1 本の @Test は 30 秒以内に終わる大きさにする。GPU を長く占める・ハングしうる形 (無限ループ・巨大な dispatch の繰り返し) は書かない
   - 実測が意味を持たない (窓が要る・電力・外部ディスプレイ・Instruments が要る) ものは無理に書かず、何が要るかを報告に書く
5. 推測が外れていそうなら、外れていると書く。指摘を守る必要は無い

## 返すもの (日本語、最終メッセージに本文で全部。ファイルの報告は書かない)

Issue ごとに: 事実の再確認の表 (主張 / 判定 / 現行の行番号と根拠) / 原因 / 影響範囲 / 測る場面と期待する指標 / 下書きの @Test 名。最後に下書きファイルのパスと、コンパイルで引っかかりそうな箇所 (internal の名前の推測など) の一覧。
