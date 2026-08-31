<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

描画の失敗 (`RenderFailure`) を `print` したり、catch して文字列にしたときに、人が読む文面が出るようになりました。これまでは `shaderSourceMissing(name: "Shapes.metal")` のような内部の名前だけで、何が足りないのか・次に何をすればよいのかが分かりませんでした。`ImageFailure` / `ModelFailure` / `ShaderFailure` と同じ扱いになります。

同梱の参照スケッチ (`swift run reference-sketches`) も、起動や書き出しに失敗したときに `Fatal error:` ではなくその文面を出して終了コード 1 で終わります。

走っている最中に出る注意 (`mokume: 〜`) は 1 行のままです。全文が出るのは起動できなかったときと、観測レポートの `warnings` です。
