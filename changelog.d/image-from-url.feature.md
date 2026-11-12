<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadImage`・`requestImage` が、`http://` か `https://` で始まる名前を URL として受け取り、その画像を読むようになりました (Processing の `loadImage(url)`・`requestImage(url)`、[#3715](https://github.com/mokume-metal/mokume/issues/3715))。`loadStrings`・`loadJSONObject`・`loadTable` などと同じ決まりで、`file://` で始まる名前は今までどおりファイルの名前として探します。

拡張子の無い URL のために、種類を添える `loadImage(url, extension: "png")` と `requestImage(url, extension: "png")` を足しました。種類は手がかりで、中身から種類が分かる画像は中身のとおりに読みます。

URL の画像は、実行のあいだ URL ごとに 1 度だけ受け取ります。`draw()` の中で読んでも毎フレーム通信しない代わりに、走らせている間にサーバの側で画像が差し替わっても拾いません。同期の `loadImage` は受け取るまで最長 60 秒フレームを止めるので、待たない `requestImage` を `Task` から呼ぶほうが向いています。URL から読んだ画像は、URL から読んだ本文と同じく記録 (`mokume run --record`) に載らず、使った作品の記録はそれを `unreproducible` に名乗ります。
