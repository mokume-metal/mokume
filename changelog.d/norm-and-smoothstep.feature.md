<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

範囲の中のどこにあるかを 0…1 の割合で返す `norm()` と、窓・締め・曲線を 1 本で済ませる `smoothstep()` を追加した。時刻の窓で動きを付けるとき、`smoothstep(2.4, 5.4, time)` の 1 行で「2.4 秒から 5.4 秒のあいだに、端で速さが 0 になる曲線で 0 から 1 へ移る」値が得られる。`map()` / `lerp()` / `constrain()` と同じくグローバル関数なので、`Sketch` の外に置いた型からも呼べる。

`smoothstep()` は**シェーダ (MSL) の `smoothstep` と同じ名前・同じ引数の並び・同じ式**なので、断片に書いた式を Swift の側へそのまま写せる。窓の外は締め、逆向きの窓 (`smoothstep(6, 2, x)`) は下り坂になり、幅 0 の窓は縁から上が 1 の段になる。`norm()` は手本 (Processing / p5.js) と同じく**範囲の外を締めない** — `norm(120, 0, 80)` は 1.5 を返す。締めたいときは `constrain()` を通すか `smoothstep()` を使う。どちらも、数でない値や無限が混じったとき (`norm()` は範囲の幅が 0 のときも) だけ 0 を返して 1 度だけ注意を言う (絵へ NaN を通さないため)。
