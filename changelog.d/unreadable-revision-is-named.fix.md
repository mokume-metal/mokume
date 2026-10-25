<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume watch` の窓に、つまみが 1 つも並ばない・絵が古いまま、のときの理由が端末に出るようになった。スケッチが別の版のライブラリで作られていて、つまみの応答や共有面の目録が道具に読めない形のとき、これまでは何も言わずに続いていた。いまは読めなかったファイルと理由、版のずれの可能性と `mokume doctor <sketch directory>` を、読めない改訂ごとに 1 度だけ標準エラーに出す。読めなかった改訂は確定させないので、読める形に置き直されれば取り込む。
