<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

公開の `ImageFailure` に `unreachable(url:reason:)` を足しました。URL から画像を受け取れなかったとき (繋がらない・時間切れ・サーバが 2xx 以外の状態で答えた) に `loadImage`・`requestImage` が投げます ([#3715](https://github.com/mokume-metal/mokume/issues/3715))。文面は `Cannot read "https://example.com/a.png": the server answered 404 (Not Found)` の形で、受け取った本文を画像として読んで「壊れた画像」とは言いません。受け取れたが画像でなかったとき (HTML など) は、今までどおり `undecodable(path:)` です。

移行: `ImageFailure` を `switch` で網羅しているコードは、case が足りないとコンパイル時に指摘されます。`case .unreachable(let url, let reason):` を足してください。失敗をまとめて扱っている (`catch` で受けて `description` を出す、`try?` で受ける、など) なら、コードの変更は要りません。以前は URL を渡すとファイルの名前として探して `notFound` を投げていたので、URL を渡して `notFound` を受けていたコードは `unreachable` (届かない) か画像そのもの (届いた) を受けるようになります。
