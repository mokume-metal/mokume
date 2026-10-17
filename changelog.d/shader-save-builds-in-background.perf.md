<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

窓で走らせているスケッチ (`mokume watch` を含む) では、`loadShader`・`loadEffect`・`loadComputation` で読み込んだシェーダを保存しても、窓が止まらなくなりました。これまでは保存の次のフレームでシェーダとパイプラインをその場で組んでいたので、冷えた状態では保存のたびに窓が 0.2 秒ほど止まっていました。いまは裏で組み、組み上がるまでは前のシェーダのまま描き、組み上がった後のフレームから新しいシェーダで描きます。組めなかったときの知らせも、組み終えた後のフレームで 1 度だけ出ます。組んでいる間に続けて保存したときは、最後に保存した中身だけが効きます。`mokume render` での書き出しと観測は、これまでどおり保存した中身で組み上がるのを待ちます ([#2365](https://github.com/mokume-metal/mokume/issues/2365))。
