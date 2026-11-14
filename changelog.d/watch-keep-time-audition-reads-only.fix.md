<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume watch --keep-time` の試聴 (`audition`) の版が、作品のウィンドウの版の時計を書き換えなくなりました。試聴の版は作品のウィンドウの版の時計から始まりますが、試聴の中で `pauseTime()`・`jumpTime(_:)` で止めた・飛んだ秒は、`leave` で試聴を捨てた後の作り直しへ残りません。これまでは、作品のウィンドウの版が止めている (`pauseTime()`)・`noLoop()` で止まっているときに試聴を捨てて保存すると、新しい版が試聴の版の秒から始まることがありました。試聴の間も、作品のウィンドウの版は自分の時計を書き続けます。
