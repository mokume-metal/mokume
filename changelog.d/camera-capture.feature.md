<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

カメラが標準の機能になりました。`camera = try? createCapture(640, 480)` と呼べば、`draw()` の前に届いた新しい 1 枚が `camera.image` に入り、普通の `Image` として描けます。`plugins` には何も書きません。`captureDevices()` で繋がっているカメラを列挙し、`device:` で 1 台を選べます。カメラが無くても作れて、挿されたら始まり、抜かれたら `camera.state` が `disconnected` になります。許可を待ったまま 3 秒経っても絵が来ないときと、許可を拒まれたときは、どのアプリの許可を見ればよいかを 1 度だけ知らせます。`createCapture(frames:)` は記録した絵の列をカメラの代わりに流すので、機材の無い場所でもカメラを使うスケッチを確かめられます。
