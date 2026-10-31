<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`createTCPClient(_:_:)` と `createWebSocketClient(_:)` が返すクライアントは、このアプリにローカルネットワークの許可が無くて繋げないとき、約束の `denied` を名乗るようにした。これまでは `unavailable` のまま「Network is down」としか診断に出さず、許可が原因だと分からなかった。いまは `state` が `denied` になり、「blocked by macOS (Local Network). Allow it in System Settings > Privacy & Security > Local Network …」と 1 度だけ診断に出す。macOS はこのとき繋ぎの失敗を `Network is down` で待つだけで、拒まれたことは経路の理由にだけ出す。経路が本当に無いときの `Network is down` は、これまでどおり `unavailable` と「cannot connect」の診断で、許可されて繋がれば `running` に戻る ([#3593](https://github.com/mokume-metal/mokume/issues/3593))。
