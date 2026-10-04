<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

1 つのプロセスで `SketchApplication.run()` を 2 度呼んでも、走っている 1 つ目を壊さなくなった。これまでは 2 つ目の `run()` (Processing の `runSketch` で第 2 窓を出す書き方) が、1 つ目を確かめずにアプリケーションの delegate を差し替えていた。そのため 2 つ目は 1 枚も描かないまま、1 つ目が `beginRecord` で撮っていた `.mov` が、道具の止める合図で終わると開けないファイルとして残っていた ([#2027](https://github.com/mokume-metal/mokume/issues/2027))。

いまは、既に 1 つ走っていれば、2 つ目の `run()` は何にも触れずにすぐ戻る。2 つ目を `Sketch.main()` で起こしたときも同じで、組み立てる前に戻る (これまでは 2 つ目の組み立てが失敗するとプロセスごと終わり、同じく 1 つ目の `.mov` が開けないまま残っていた)。断ったことは標準エラーへ 1 度だけ言う (`A sketch is already running in this process — this second run() does nothing (one window per process)`)。窓は 1 プロセスに 1 つのままで、第 2 窓を出す口はまだ無い。
