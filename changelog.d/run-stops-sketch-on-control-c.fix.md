<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**端末で `mokume run` を `Control` + `C` で止めると、走らせていたスケッチも一緒に止まるようになりました。** これまでは道具だけが終わり、スケッチは窓ごと孤児として残っていました — スケッチは道具とは別のプロセスグループで走るので、端末の `Control` + `C` は道具にしか届いていませんでした。道具が受けてスケッチへ渡し、スケッチが終わるのを待ってから `130` で終わります。背面 (`&`) で起こした `mokume run` は、これまでどおり `Control` + `C` を受け流します。
