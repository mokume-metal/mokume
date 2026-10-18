<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

動画 (`createVideo`) で 1 秒以内の先へ飛ぶとき、間に動画の鍵のコマがあれば読み直すようになり、4K で 2 割前後速く飛び先が出るようになった。これまでは 1 秒以内なら必ず間のコマを全部復号していた。いまは飛び先の手前の鍵のコマ (それだけで復号できるコマ) が十分先にあれば、そこから読み直す (4K の H.264 で 0.5 秒から 1.4 秒へ飛ぶと 86 ms → 72 ms、HEVC で 85 ms → 61 ms)。1 秒より先へ飛ぶときはこれまでどおり読み直す。どちらで読んでも映るコマは変わらない ([#2764](https://github.com/mokume-metal/mokume/issues/2764))。
