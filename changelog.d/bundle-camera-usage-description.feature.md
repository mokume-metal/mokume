<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume bundle` が、カメラ・マイクの許可を求めるときの文言を `.app` へ入れるようにした。`mokume-app.json` に `cameraUsage` / `microphoneUsage` を書くと、`Info.plist` の `NSCameraUsageDescription` / `NSMicrophoneUsageDescription` になる。名前のある署名 (`MOKUME_SIGN_IDENTITY`) で束ねるときは、書いた機材の entitlement (`com.apple.security.device.camera` / `com.apple.security.device.audio-input`) も署名に付く — 強化されたランタイムの下では、これが無いとダイアログも出ずに拒否される。

**カメラを使う (`createCapture()` を呼ぶ) のに `cameraUsage` が無いときは、束ねずに止まる。** 文言の無い `.app` はカメラに触れた時点で macOS に止められ、作った手元では動くので、気付くのは配った先になるためである。止まるときは足す 1 行を見せる。`createCapture(frames:)` は機材に触れないので数えない。見るのは `Sources/` の中だけで、依存パッケージの中で使うものは見ない。マイクを使う口はまだ無いので、マイクの文言は書けるが止める検査は無い。

許可がどこに付くか (束ねない実行では起動した端末のアプリ・名前の無い署名の `.app` は束ね直すたびに外れる) も、README の「渡す」に書いた。
