<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`SoundFile` に、チャンネルの数を読む `channels` と、標本 (フレーム) の数を読む `frames` を足しました。Processing Sound の `SoundFile.channels()`・`frames()` に当たります。`channels` は 3 チャンネル以上のファイルでも 2 に畳まずにそのまま返し、`frames` は `duration × sampleRate` の近似ではなく読み込んだ標本の数そのものを返します。
