<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

配布物にシェーダの資源が入っておらず、Homebrew などで入れた道具の `mokume watch` が起動できませんでした。配布物には道具立てが作った資源の束を**全部**入れるようにし、1 つでも欠けたら束ねる段で止まるようにしています。`v0.5.0` から `v0.7.0` までの配布物はどれも欠けていたので、`brew upgrade mokume` で入れ直してください ([#1054](https://github.com/mokume-metal/mokume/issues/1054))。

**欠けたときの落ち方も変えました。** これまでは、束ねた作品 (`.app`) でないかぎり「組み上げた機械のディレクトリが見つからない」という、受け取った人には意味の無い場所を名指しして即座に落ちていました。いまは資源が無いと分かった時点でそう名乗り、`watch` は落ちずにスケッチ自身の窓を開かせます ([#1058](https://github.com/mokume-metal/mokume/issues/1058))。

**`mokume doctor` が「同梱の資源」を 1 行で名乗るようになりました。** 読めるかどうかと、どこから読めているかを出します — GPU が使えても資源が欠けていれば窓は出せないので、その 2 つは別の行です ([#1059](https://github.com/mokume-metal/mokume/issues/1059))。

```
環境の前提

  描く道具: 使える
  同梱の資源: 読める (/opt/homebrew/Cellar/mokume/0.7.0/libexec/mokume_MokumeCore.bundle/Contents/Resources)
```
