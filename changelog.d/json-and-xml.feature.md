<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**JSON と XML を、ファイルからも URL からも読めるようになった** (`loadJSONObject` / `loadXML`。待たない口 `requestJSONObject` / `requestXML` もある)。名前が `http://` か `https://` で始まれば URL から取り、それ以外は `loadImage` と同じ場所からファイルを探す。読む前に応答の形を型として宣言しなくてよい — `requestJSONObject("https://…").getJSONObject("main").getFloat("temp")` のように、キーを辿って値を取り出す。XML は `getChildren("star")` で子の要素を名前で取り出し、`getFloat("x")` で属性を数として読む。

**読めないときは理由を添えて投げる** (`DataFailure`)。URL から受け取れない (繋がらない・時間切れ・サーバが 404 などで答えた) ときは `unreachable`、JSON や XML として壊れているときは壊れていた行を添えた `malformed` になる。無いキーや数でない値を取り出しても落ちず、`getFloat` は NaN を返して初回だけ理由を知らせる (表の `getFloat` と同じ)。

同期版 (`loadJSONObject` / `loadXML`) に URL を渡すと、届くまで返らない。`setup()` の中で 1 度読むためのもので、フレームを止めずに読むには待たない口を `Task` から呼ぶ。XML の中に書かれた外の実体 (`SYSTEM`) は読まない。
