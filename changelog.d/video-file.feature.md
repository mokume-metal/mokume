<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

動画ファイルを流して、いま映っているコマを絵として描けるようになりました。`clip = try? createVideo("assets/clip.mov")` で開き、`clip?.loop()` で流すと、`draw()` の前にそのフレームのコマが `clip.image` に入り、普通の `Image` として貼れます (Processing の `Movie`・p5.js の `createVideo()` に当たります)。操作は `play()`・`loop()`・`pause()`・`jump(_:)` で、位置は `clip.time`、長さは `clip.duration` で読めます。`plugins` には何も書きません。

どのコマが映るかはスケッチの時刻で決まり、実時間の再生時計は使いません。`mokume run` では実時間で流れ、`mokume render` で書き出すと、何度書き出しても同じフレーム番号に同じコマが出ます。

見つからない・動画として読めない・映像が入っていない (音声だけの) ファイルは、作るときに理由を添えて投げます (`MovieFailure`)。流している途中で読めなくなったら投げず、最後に読めたコマを残して `clip.state` が `disconnected` になり、理由を 1 度だけ知らせます。音は鳴らしません。
