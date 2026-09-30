<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

窓を出さずにフレームを回すとき (`SketchRuntime.advance()` を続けて呼ぶ書き出しや検査のループ) でも、`loadShader`・`loadEffect`・`loadComputation` で読み込んだ断片のファイルを保存し直すと、次のフレームから新しい断片で描かれるようにしました。これまでは、回し終えるまで古い断片のまま描いていました。窓で回すときと同じく、組み直すのはフレームを描き始める前だけで、1 つのフレームの中で古い断片と新しい断片が混ざることはありません。
