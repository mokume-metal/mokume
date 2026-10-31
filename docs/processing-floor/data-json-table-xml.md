<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# データ: JSON・Table・XML

Processing の本体の参照のうち、`JSONObject`・`JSONArray`・`Table`・`TableRow`・`XML` の 5 つのクラスと、それを読み書きする関数 (`loadJSONObject()` ほか 11) の 108 件。形・版・数え直す式は [README](README.md) にある。照合したのは processing-website `f4acef8` (2026-10-29) と mokume の main `5f6e4105` (2026-10-31)。

| 区分 | 件数 |
| --- | --- |
| 同等 | 40 |
| 入れる | 35 |
| 作例待ち | 12 |
| 持たない | 21 |
| 計 | 108 |

この領域に共通すること:

- **読む型はどれも値の型である** ([#2466]・[#2468])。代入すると写しになり、Processing のように取り出した行や子を書き換えて元へ届かせることはできない。書き換えは持ち主 (表・オブジェクト) に対して、番号やキーを渡して行う
- **欠けた値は空の値を返し、1 度だけ知らせる** ([ADR-0020](../decisions/0020-api-naming-and-surface.md) 決定 5・[#2466])。Processing が既定値を渡す形 (`getString(key, defaultValue)` など) は、いまの mokume に無い (欠けた形。知らせずに分けるのは `JSONObject.hasKey(_:)`)
- **読めないときは投げる。** Processing は `null` や `false` を返す (`loadJSONObject()`・`parseXML()`・`saveTable()` ほか)。mokume は `DataFailure` を投げ、`setup() throws` の `try` か `try?` で受ける
- 読む口は、名前が `http://` か `https://` で始まれば URL から読む ([#2470])。どれにも、フレームを止めない `request…` の版がある

## 入れるの束

「入れる」の 35 件は、近い口ごとに 5 本の `Feature` で入れる。

| 束 | 口 | 件数 |
| --- | --- | --- |
| #TBD-1 表から番号で読む | `Table.getFloat()`・`Table.getInt()`・`Table.getString()`・`TableRow.getInt()` | 4 |
| #TBD-2 表の行と列を書き換える | `Table.clearRows()`・`removeColumn()`・`removeRow()`・`removeTokens()`・`setInt()`・`trim()` | 6 |
| #TBD-3 JSON のオブジェクトを作って書き出す | `JSONObject.setBoolean()`・`setFloat()`・`setInt()`・`setJSONArray()`・`setJSONObject()`・`setString()`・`saveJSONObject()` (空から作る `new JSONObject()` を含む) | 7 |
| #TBD-4 JSON の配列を作って書き出す | `JSONArray.append()`・`remove()`・`setBoolean()`・`setFloat()`・`setInt()`・`setJSONArray()`・`setJSONObject()`・`setString()`・`saveJSONArray()` (空から作る `new JSONArray()` を含む) | 9 |
| #TBD-5 JSON と XML の読み口の残り | `JSONObject.isNull()`・`JSONArray.isNull()`・`XML.getName()`・`getInt()`・`getIntContent()`・`getFloatContent()`・`hasAttribute()`・`listAttributes()`・`parseXML()` (引数なしの `getChildren()` を含む) | 9 |

## JSONObject

14 件。

| 口 | mokume の口 | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `JSONObject` (クラス) | `JSONObject` | 同等 | 値の型で、キーで値を取り出す。いまは読むだけで、空から作る `new JSONObject()` は無い (#TBD-3 で入れる) | [#2466]・PR [#3056] |
| `JSONObject.getBoolean()` | `JSONObject.getBoolean(_:)` | 同等 | `true` / `false` だけを読む。数の `1` や文字の `"true"` は真偽にしない | [#2466]・PR [#3056] |
| `JSONObject.getFloat()` | `JSONObject.getFloat(_:)` | 同等 | 数の文字 (10 進の綴りの `"18.5"`) も数として読む。数にならなければ NaN | [#2466]・PR [#3056] |
| `JSONObject.getInt()` | `JSONObject.getInt(_:)` | 同等 | **丸めない。** `2.5` は 0 を返して知らせる (Processing は切り捨てる)。整数の値だけを読み、黙って別の値を返さない | [#2466]・PR [#3056] |
| `JSONObject.getJSONArray()` | `JSONObject.getJSONArray(_:)` | 同等 | 返る配列は `for-in` で回せる。配列でなければ空の配列 | [#2466]・PR [#3056] |
| `JSONObject.getJSONObject()` | `JSONObject.getJSONObject(_:)` | 同等 | オブジェクトでなければ空のオブジェクトで、繋いだまま書ける | PR [#2180]・[#2466] |
| `JSONObject.getString()` | `JSONObject.getString(_:)` | 同等 | 文字の値だけを読み、数や真偽を綴りにしない | [#2466]・PR [#3056] |
| `JSONObject.isNull()` | — | 入れる | `hasKey(_:)` は値が `null` でも `true` で、`null` を知らせずに見分ける口が無い。`getString(_:)` で読むと空の文字と知らせになり、欠けたキーと区別できない | #TBD-5 |
| `JSONObject.setBoolean()`・`setFloat()`・`setInt()`・`setJSONArray()`・`setJSONObject()`・`setString()` (6 件) | — | 入れる | キーに値を書く。値の型なので `mutating` の口になる。入れ子は、取り出した写しを書き換えて `setJSONObject` で戻す (取り出した値へ直に書くと、コンパイルが止める)。Processing の名前と引数のまま形が割れない。JSON を書く口は [#2466]・[#2468] で「作例が無い」として入れなかったが、選び直しではなく、ADR-0041 決定 3 の改訂で表から選べるようになった | #TBD-3 |

## JSONArray

21 件。

| 口 | mokume の口 | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `JSONArray` (クラス) | `JSONArray` | 同等 | `RandomAccessCollection` で、要素は `JSONObject` として回る。いまは読むだけで、空から作る `new JSONArray()` は無い (#TBD-4 で入れる) | [#2466]・PR [#3056] |
| `JSONArray.append()`・`remove()`・`setBoolean()`・`setFloat()`・`setInt()`・`setJSONArray()`・`setJSONObject()`・`setString()` (8 件) | — | 入れる | 番号に値を書く・末尾に足す・番号の値を除く。`JSONObject` の書き換えと同じく `mutating` の口で、Processing の名前と引数のまま形が割れない | #TBD-4 |
| `JSONArray.getBoolean()`・`getFloat()`・`getInt()`・`getJSONArray()`・`getJSONObject()`・`getString()` (6 件) | `JSONArray.getBoolean(_:)`・`getFloat(_:)`・`getInt(_:)`・`getJSONArray(_:)`・`getJSONObject(_:)`・`getString(_:)` | 同等 | 番号で読む。読み方は `JSONObject` の同じ名前の口と同じ (`getInt` は丸めない)。範囲の外の番号も落ちず、空の値と口ごとに 1 度の知らせ | [#2466]・PR [#3056] |
| `JSONArray.getIntArray()`・`getStringArray()`・`toIntArray()`・`toStringArray()` (4 件) | `(0..<array.count).map { array.getInt($0) }` (文字は `getString`) | 持たない | 番号で読む口を Swift の `map` で回せば同じ並びになる。`getIntArray` と `toIntArray` は参照の上でも同じ働きの 2 つの名前である。整数でない要素は 0 と知らせになる (Processing は投げる) | — |
| `JSONArray.isNull()` | — | 入れる | 番号の値が `null` かを、知らせずに見分ける口が無い (`JSONObject.isNull()` と同じ) | #TBD-5 |
| `JSONArray.size()` | `JSONArray.count` | 同等 | 数え方は collection の `count` だけで、`size()` は持たない (書き方を 2 通りにしない) | [#2466]・PR [#3056] |

## Table

25 件。

| 口 | mokume の口 | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `Table` (クラス) | `Table` | 同等 | 値の型で、セルは読んだ文字のまま持つ。`new Table()` と `addColumn()` は、見出しを渡す `Table(columns:)` にまとめた | [#2468]・PR [#2861] |
| `Table.addColumn()` | `Table.addColumn(_:)` | 同等 | 名前を渡す形だけ。無い形: 名前なしの `addColumn()` と、型を渡す `addColumn(title, type)` (mokume の表は列の型を持たず、数として読むのは取り出すとき) | — |
| `Table.addRow()` | `Table.addRow(_:)` | 同等 | 左の列からの数の並びを渡す (`addRow([10, 20])`)。Processing の「空の行を足し、返った行に書く」形は、行が読むための写しなので取らない。文字の並びを受ける形は作例が来てから | [#2468]・PR [#2861] |
| `Table.clearRows()`・`removeColumn()`・`removeRow()`・`removeTokens()`・`setInt()`・`trim()` (6 件) | — | 入れる | 表の行と列を書き換える口。表は値の型で、行の写しからは書き換えられないので、表の上に口が要る。セルの文字を整える `trim`・`removeTokens` は、いまは行の数だけ `setString` を回して Foundation で整えるしかない。`setInt` は `setFloat` と同じ形で、整数の綴りで書く | #TBD-2 |
| `Table.findRow()`・`findRows()`・`matchRow()`・`matchRowIterator()`・`matchRows()` (5 件) | `table.rows.first(where:)`・`filter`・`firstIndex(where:)` (正規表現は Swift の `Regex` と `wholeMatch(of:)`) | 持たない | Swift の標準の口で 1 度に回せる。返る行は読むための写しなので、見つけた行を書き換えるときは `firstIndex(where:)` の番号で表に書く | [#2468] |
| `Table.getColumnCount()` | `Table.columnCount` | 同等 | プロパティ | — |
| `Table.getFloat()`・`getInt()`・`getString()` (3 件) | — (いまは `table.rows[row].getFloat(column)`) | 入れる | 表から行の番号と列で 1 つのセルを読む。書く側 (`setFloat(_:_:_:)`) は表にあり、読む側だけが行を経る。`rows` は呼ぶたびに全行の写しを作るので、番号で読むループが行の数の 2 乗になる。`getInt` は `JSONObject.getInt(_:)` と同じく丸めない | #TBD-1 |
| `Table.getRow()` | `Table.rows[row]` | 同等 | 返るのは読むための写しで、参照ではない (書き換えは表へ) | [#2468] |
| `Table.getRowCount()` | `Table.rowCount` | 同等 | プロパティ。見出しの行は数えない | — |
| `Table.getStringColumn()` | `table.rows.map { $0.getString(column) }` | 持たない | Swift の `map` で 1 度に回せる | — |
| `Table.rows()` | `Table.rows` | 同等 | プロパティで、上から並べた行の写し | — |
| `Table.setFloat()` | `Table.setFloat(_:_:_:)` | 同等 | 列は名前と番号の 2 つの形。無い列・表の外の行には書かず、1 度だけ知らせる | — |
| `Table.setString()` | `Table.setString(_:_:_:)` | 同等 | 無い列・表の外の行の扱いは `setFloat` と同じ | — |
| `Table.sort()` | — | 作例待ち | 並べ方が割れる。Processing は列の型 (文字か数か) で並べ方を決めるが、mokume の表は列の型を持たずセルを文字で持つので、文字の順か数の順かを口の形 (引数か、口を 2 つにするか) で決める必要がある。並べ替えたい作例が来たら選ぶ | — |

## TableRow

9 件。

| 口 | mokume の口 | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `TableRow` (クラス) | `TableRow` | 同等 | `Table.rows` から取り出す、読むための写し。書き換える口を持たない | [#2468]・PR [#2861] |
| `TableRow.getColumnCount()`・`getColumnTitle()` (2 件) | `Table.columnCount`・`Table.columnTitles[column]` | 持たない | 行は表の写しで、どの行も同じ列を持つ。列の数と名前は表が持つ | — |
| `TableRow.getFloat()` | `TableRow.getFloat(_:)` | 同等 | 列は名前と番号の 2 つの形。10 進の綴りだけを数とし、数でなければ NaN と知らせ | — |
| `TableRow.getInt()` | — | 入れる | 整数として読む口が行に無い。`Table.getInt()` と同じく丸めない | #TBD-1 |
| `TableRow.getString()` | `TableRow.getString(_:)` | 同等 | 列は名前と番号の 2 つの形。無い列は空の文字と知らせ | — |
| `TableRow.setFloat()`・`setInt()`・`setString()` (3 件) | `Table.setFloat(_:_:_:)`・`Table.setString(_:_:_:)` (整数は #TBD-2 の `Table.setInt()`) | 持たない | 行は読むための写しで、書き換えは表に行の番号を渡して行う | [#2468]・PR [#2861] |

## XML

28 件。

| 口 | mokume の口 | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `XML` (クラス) | `XML` | 同等 | 値の型の要素 1 つで、読むだけ。空から作る `new XML(name)` は、書き換えと一緒に作例待ち (下の行) | PR [#2180]・[#2466] |
| `XML.addChild()`・`format()`・`removeChild()`・`setContent()`・`setFloat()`・`setInt()`・`setLong()`・`setName()`・`setString()`・`toString()` (10 件) | — | 作例待ち | 値の型の要素で、子へ書き戻す形が割れる。Processing の `addChild` は足した子を参照で返してそこへ書かせ、`removeChild` は消す子を参照で指す。写しの子を書き換えても木は変わらないので、子を番号で置き換える口など、Processing に無い形を選ぶ必要がある。書き出す口 (`format`・`toString`・`saveXML()`) は書き換えと組でしか使い途が無い。書き換えて書き出す作例が来たら、形をまとめて決める | — |
| `XML.getAttributeCount()` | `xml.listAttributes().count` (#TBD-5 の `listAttributes()`) | 持たない | 数え方は `count` だけにする ([#2466] の `JSONArray.size()` と同じ考え) | [#2466] |
| `XML.getChild()` | `XML.getChild(_:)` | 同等 | 名前の形。無い形: 番号の `getChild(index)` (#TBD-5 の引数なしの `getChildren()` で `getChildren()[index]` と書ける) と、パス (`channel/item`) の名前 (`getChild` を繋いで降りる) | [#2466]・PR [#3056] |
| `XML.getChildCount()`・`hasChildren()`・`listChildren()` (3 件) | `xml.getChildren().count`・`.isEmpty`・`.map { $0.getName() }` (#TBD-5 の引数なしの `getChildren()` と `getName()`) | 持たない | 子の並びから、数・有無・名前が引ける。数え方は `count` だけにする ([#2466] と同じ考え) | [#2466] |
| `XML.getChildren()` | `XML.getChildren(_:)` | 同等 | 名前の形。無い形: 引数なしのすべての子 (#TBD-5 で入れる) と、パスの名前 | PR [#2180] |
| `XML.getContent()` | `XML.getContent()` | 同等 | 書かれたままの文字 (前後の空白も残る)。文字が無ければ空の文字で、知らせない | [#2466]・PR [#3056] |
| `XML.getFloat()` | `XML.getFloat(_:)` | 同等 | 属性を数として読む。10 進の綴りだけで、数でなければ NaN と知らせ | PR [#2180] |
| `XML.getFloatContent()`・`getInt()`・`getIntContent()`・`getName()`・`hasAttribute()`・`listAttributes()` (6 件) | — | 入れる | 読み口の残り。要素の名前、属性の整数、要素の文字の数、属性があるか (JSON の `hasKey(_:)` に当たり、知らせない)、属性の名前の一覧 (JSON の `keys` に当たる。属性は順を持たないので文字の順にそろえる)。整数は丸めない | #TBD-5 |
| `XML.getParent()` | — (降りる前の要素を変数に残す) | 持たない | 値の型の要素は親を持たない。子は写しで、親から降りた道は作者が持つ | — |
| `XML.getString()` | `XML.getString(_:)` | 同等 | 属性を文字として読む。無ければ空の文字と知らせ | [#2466]・PR [#3056] |
| `XML.parse()` | `parseXML()` (#TBD-5) | 持たない | 文字から読む口は関数の `parseXML()` の 1 つにする (`parseJSONObject(_:)` と同じ形。書き方を 2 通りにしない) | — |

## 読み書きの関数

11 件。

| 口 | mokume の口 | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `loadJSONArray()` | `loadJSONArray(_:)`・`requestJSONArray(_:)` | 同等 | 最上位が配列でなければ投げ、理由が `loadJSONObject` を案内する。無い形: `File` を渡す形 (名前の文字だけを受ける) | [#2466]・PR [#3056] |
| `loadJSONObject()` | `loadJSONObject(_:)`・`requestJSONObject(_:)` | 同等 | 型で読む道 (`Decodable` と `JSONDecoder`) は口を足さず、`JSONObject` の説明文に例を置いた | PR [#2180]・[#2960]・PR [#3449] |
| `loadTable()` | `loadTable(_:header:)`・`requestTable(_:header:)` | 同等 | `"header"` の選択は `header: true`。URL からも読む。無い形: 区切りの選択 (`"tsv"` など。区切りはカンマだけ) | [#2470]・PR [#2896] |
| `loadXML()` | `loadXML(_:)`・`requestXML(_:)` | 同等 | XML 宣言の `encoding` は読まず UTF-8 として読む (Processing と同じ)。外の実体は読まない | PR [#2180]・[#2466] |
| `parseJSONArray()`・`parseJSONObject()` (2 件) | `parseJSONArray(_:)`・`parseJSONObject(_:)` | 同等 | TCP・UDP・WebSocket で届いた文字を読む。壊れた文字は投げる (Processing は `null`) | [#2466]・PR [#3056] |
| `parseXML()` | — | 入れる | 届いた文字の XML を読む口が無い (JSON には `parseJSONObject(_:)` がある)。同じ形で、壊れた文字は投げる | #TBD-5 |
| `saveJSONArray()` | — | 入れる | `JSONArray` を JSON のファイルにする。置き場と書きかけを残さないことは `saveTable(_:_:)` と同じ | #TBD-4 |
| `saveJSONObject()` | — | 入れる | `JSONObject` を JSON のファイルにする。キーは `keys` と同じ文字の順で書き、同じ値から同じファイルになる | #TBD-3 |
| `saveTable()` | `saveTable(_:_:)` | 同等 | 書けなければ投げる (Processing は `false` を返す)。無い形: 区切りの選択 (`"tsv"` など) | [#2468]・PR [#2861] |
| `saveXML()` | — | 作例待ち | `XML` の書き換えと組 (XML の節の作例待ちの行) | — |

[#2180]: https://github.com/mokume-metal/mokume/pull/2180
[#2466]: https://github.com/mokume-metal/mokume/issues/2466
[#2468]: https://github.com/mokume-metal/mokume/issues/2468
[#2470]: https://github.com/mokume-metal/mokume/issues/2470
[#2861]: https://github.com/mokume-metal/mokume/pull/2861
[#2896]: https://github.com/mokume-metal/mokume/pull/2896
[#2960]: https://github.com/mokume-metal/mokume/issues/2960
[#3056]: https://github.com/mokume-metal/mokume/pull/3056
[#3449]: https://github.com/mokume-metal/mokume/pull/3449
