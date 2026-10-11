<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

URL を渡した `loadJSONObject` と `loadXML` が、説明どおり**呼んでから最長 60 秒**で返るようになりました ([#2264](https://github.com/mokume-metal/mokume/issues/2264))。60 秒で届き終わらなければ、受け取りを取り消して `DataFailure.unreachable` で投げます。文面は `Cannot read "https://…": no complete answer came back within 60.0 seconds` です。

これまでの 60 秒は「何も届かない間」の期限で、データが届くたびに数え直していました。何も返さないサーバには 60 秒で諦めましたが、少しずつ返し続けるサーバには諦めず、その間ずっと窓が固まっていました。60 秒より長くかかる読み込みは、待たない版の `requestJSONObject` / `requestXML` で読みます。
