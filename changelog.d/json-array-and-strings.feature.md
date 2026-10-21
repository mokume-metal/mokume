<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**JSON から文字・整数・真偽・配列を取り出せるようになり、最上位が配列の JSON も読める** ([#2466](https://github.com/mokume-metal/mokume/issues/2466))。`JSONObject` に `getString`・`getInt`・`getBoolean`・`getJSONArray`・`hasKey`・`keys` を足し、新しい型 `JSONArray` は `for-in` で回せる (要素は `JSONObject`。`count` で数え、数・文字・真偽は `getFloat(i)`・`getString(i)`・`getInt(i)`・`getBoolean(i)` で読む)。読む口は `loadJSONArray`・`requestJSONArray` (ファイルも URL も)、通信で届いた文字を読む `parseJSONObject`・`parseJSONArray`。公開のデータの多くが持つ配列を、Foundation に降りずに読める。

```swift
let quakes = try loadJSONObject("https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_day.geojson")
for f in quakes.getJSONArray("features") {
    let c = f.getJSONObject("geometry").getJSONArray("coordinates")
    let p = f.getJSONObject("properties")
    circle(map(c.getFloat(0), -180, 180, 0, width), map(c.getFloat(1), 90, -90, 0, height), p.getFloat("mag") * 4)
    if p.getFloat("mag") > 5 { text(p.getString("place"), 20, 20) }
}
```

**欠けた値・種類の違う値は落ちない。** 無いキーや違う種類の値は、空の値 (`getString` は `""`、`getInt` は 0、`getBoolean` は `false`、`getJSONArray` は空の配列) を返し、キーごとに 1 度だけ理由を知らせる (表の `getString` と同じ)。`getInt` は**丸めない** — `2` と `2.0` は 2、`2.5` と `Int` に収まらない数は 0 を返して知らせる。`keys` は辞書の順ではなく文字の順に並ぶので、同じ JSON から毎回同じ絵ができる。

最上位が配列の JSON を `loadJSONObject` に渡したときの失敗 (`malformed`) は、理由が `loadJSONArray` を案内するようになった。

XML は、要素の中の文字 `getContent()`・属性の文字 `getString(_:)`・最初の子 `getChild(_:)` を読めるようになった (RSS の `item.getChild("title").getContent()`)。無い子や属性は空の値を返して 1 度だけ知らせる。
