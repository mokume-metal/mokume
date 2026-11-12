<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# データ: JSON・Table・XML

Processing 本体のリファレンスのうち、`JSONObject`・`JSONArray`・`Table`・`TableRow`・`XML` の 5 つのクラスと、それを読み書きする関数 (`loadJSONObject()` ほか 11) の 108 件。表の形式・バージョン・数え直す式は [README](README.md) にある。照合したのは processing-website `f4acef8` (2026-10-29) と mokume の main `5f6e4105` (2026-10-31)。

| 区分 | 件数 |
| --- | --- |
| 同等 | 75 |
| 入れる | 0 |
| 作例待ち | 12 |
| 持たない | 21 |
| 計 | 108 |

この領域に共通すること:

- **読み込んだデータの型はどれも値型である** ([#2466]・[#2468])。代入するとコピーになり、Processing のように取り出した行や子を書き換えて元のデータに反映させることはできない。書き換えは、それを含む側 (表・オブジェクト) に対して、番号やキーを渡して行う
- **存在しない値は空の値を返し、1 度だけ警告する** ([ADR-0020](../decisions/0020-api-naming-and-surface.md) 決定 5・[#2466])。Processing が既定値を渡す形 (`getString(key, defaultValue)` など) は、いまの mokume に無い (欠けた形。警告せずに存在を確かめられるのは `JSONObject.hasKey(_:)`)
- **読めないときは投げる。** Processing は `null` や `false` を返す (`loadJSONObject()`・`parseXML()`・`saveTable()` ほか)。mokume は `DataFailure` を投げ、`setup() throws` の `try` か `try?` で受ける
- 読み込む API は、名前が `http://` か `https://` で始まれば URL から読む ([#2470])。どれにも、フレームを止めない `request…` 版がある

## 「入れる」の API をまとめた Feature

「入れる」の 35 件は、近い API ごとに 5 つの `Feature` ([#3641] の 4 件・[#3642] の 6 件・[#3643] の 7 件・[#3644] の 9 件・[#3645] の 9 件) で入れ終え、行を「同等」に直した。残る「入れる」は無い。

## JSONObject

14 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `JSONObject` (クラス) | `JSONObject` | 同等 | 値型で、キーで値を取り出す。空のオブジェクトを作る `new JSONObject()` は `JSONObject()` ([#3643]) | [#2466]・PR [#3056] |
| `JSONObject.getBoolean()` | `JSONObject.getBoolean(_:)` | 同等 | `true` / `false` だけを読む。数値の `1` や文字列の `"true"` は真偽値として扱わない | [#2466]・PR [#3056] |
| `JSONObject.getFloat()` | `JSONObject.getFloat(_:)` | 同等 | 数値の文字列 (10 進表記の `"18.5"`) も数値として読む。数値にならなければ NaN | [#2466]・PR [#3056] |
| `JSONObject.getInt()` | `JSONObject.getInt(_:)` | 同等 | **丸めない。** `2.5` は 0 を返して警告する (Processing は切り捨てる)。整数の値だけを読み、警告なしに別の値を返すことはない。**JSON の数値は `JSONSerialization` が返した値で整数かどうかを決める**ので、読み込み時点で端数や下位の桁が失われる場合がある (39 桁以上の数字列の下位の桁も同様。`{"id": 9007199254740993.0}` は 9007199254740992、`{"id": "9007199254740993.0"}` は桁のまま 9007199254740993。正確な整数は文字列で渡す) | [#2466]・PR [#3056] |
| `JSONObject.getJSONArray()` | `JSONObject.getJSONArray(_:)` | 同等 | 返る配列は `for-in` で反復できる。配列でなければ空の配列 | [#2466]・PR [#3056] |
| `JSONObject.getJSONObject()` | `JSONObject.getJSONObject(_:)` | 同等 | オブジェクトでなければ空のオブジェクトを返すので、メソッドを連鎖させて書ける | PR [#2180]・[#2466] |
| `JSONObject.getString()` | `JSONObject.getString(_:)` | 同等 | 文字列の値だけを読み、数値や真偽値を文字列に変換しない | [#2466]・PR [#3056] |
| `JSONObject.isNull()` | `JSONObject.isNull(_:)` | 同等 | 値が `null` かを、警告せずに確かめる (`hasKey(_:)` は値が `null` でも `true`)。存在しないキーを渡すと Processing と同じく `true` を返し、警告しない (2026-10-31 の決定)。存在しないキーと `null` の値は `hasKey(_:)` と組み合わせて区別する | [#3645] |
| `JSONObject.setBoolean()`・`setFloat()`・`setInt()`・`setJSONArray()`・`setJSONObject()`・`setString()` (6 件) | `JSONObject.setBoolean(_:_:)`・`setFloat(_:_:)`・`setInt(_:_:)`・`setJSONArray(_:_:)`・`setJSONObject(_:_:)`・`setString(_:_:)` | 同等 | キーに値を書く。値型なので、これらのメソッドは `mutating` としてオブジェクトを更新する。入れ子は、取り出したコピーを書き換えて `setJSONObject` で戻す (取り出した値へ直接書こうとすると、コンパイルエラーになる)。既にあるキーは、値の型が変わっても置き換える。`setFloat` は NaN と無限大を書かず、キーごとに 1 度警告する (Processing は投げる。2026-10-31 の決定) | [#3643] |

## JSONArray

21 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `JSONArray` (クラス) | `JSONArray` | 同等 | `RandomAccessCollection` で、要素は `JSONObject` として反復できる。空の配列を作る `new JSONArray()` は `JSONArray()` ([#3644]) | [#2466]・PR [#3056] |
| `JSONArray.append()`・`remove()`・`setBoolean()`・`setFloat()`・`setInt()`・`setJSONArray()`・`setJSONObject()`・`setString()` (8 件) | `JSONArray.append(_:)`・`remove(_:)`・`setBoolean(_:_:)`・`setFloat(_:_:)`・`setInt(_:_:)`・`setJSONArray(_:_:)`・`setJSONObject(_:_:)`・`setString(_:_:)` | 同等 | 番号に値を書く・末尾に追加する・番号の値を削除する。`JSONObject` の書き換えと同じく、これらのメソッドは `mutating` になる。`append` は `Int`・`Float`・`String`・`Bool`・`JSONObject`・`JSONArray` を受ける。`remove` は削除した値を返さない (`Any` を公開 API に出さない)。NaN と無限大は書かず、API ごとに 1 度警告する。範囲外の番号には書かず、1 度だけ警告する (Processing は `null` で埋めて配列を伸ばす。2026-10-31 の決定) | [#3644] |
| `JSONArray.getBoolean()`・`getFloat()`・`getInt()`・`getJSONArray()`・`getJSONObject()`・`getString()` (6 件) | `JSONArray.getBoolean(_:)`・`getFloat(_:)`・`getInt(_:)`・`getJSONArray(_:)`・`getJSONObject(_:)`・`getString(_:)` | 同等 | 番号で読む。読み方は `JSONObject` の同じ名前のメソッドと同じ (`getInt` は丸めない。数値は `JSONSerialization` が返した値で整数かどうかを決めるので下位の桁が失われる場合がある: `[9007199254740993.0]` は 9007199254740992、`["9007199254740993.0"]` は 9007199254740993)。範囲外の番号でもクラッシュせず、空の値を返し、API ごとに 1 度警告する | [#2466]・PR [#3056] |
| `JSONArray.getIntArray()`・`getStringArray()`・`toIntArray()`・`toStringArray()` (4 件) | `(0..<array.count).map { array.getInt($0) }` (文字は `getString`) | 持たない | 番号で読む API を Swift の `map` で繰り返せば同じ配列になる。`getIntArray` と `toIntArray` はリファレンス上でも同じ働きの 2 つの名前である。整数でない要素は 0 になり、警告する (Processing は投げる)。JSON の数値の限界 (読み込みで下位の桁が失われる) も `getInt` と同じ | — |
| `JSONArray.isNull()` | `JSONArray.isNull(_:)` | 同等 | 番号の値が `null` かを、警告せずに確かめる。範囲外の番号は `true` を返し、警告しない (`JSONObject.isNull(_:)` と同じ。2026-10-31 の決定) | [#3645] |
| `JSONArray.size()` | `JSONArray.count` | 同等 | 要素数の取得はコレクションの `count` だけで、`size()` は持たない (書き方を 2 通りにしない) | [#2466]・PR [#3056] |

## Table

25 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `Table` (クラス) | `Table` | 同等 | 値型で、セルは読み込んだ文字列のまま持つ。`new Table()` と `addColumn()` は、列名を渡す `Table(columns:)` にまとめた | [#2468]・PR [#2861] |
| `Table.addColumn()` | `Table.addColumn(_:)` | 同等 | 名前を渡す形だけ。無い形: 名前なしの `addColumn()` と、型を渡す `addColumn(title, type)` (mokume の表は列の型を持たず、数値として読むのは取り出すとき) | — |
| `Table.addRow()` | `Table.addRow(_:)` | 同等 | 左の列から順に値の配列を渡す (`addRow([10, 20])`)。Processing の「空の行を追加し、返った行に書く」形は、行が読み取り専用のコピーなので採用しない。文字列の配列を受ける形は作例が来てから | [#2468]・PR [#2861] |
| `Table.clearRows()`・`removeColumn()`・`removeRow()`・`removeTokens()`・`setInt()`・`trim()` (6 件) | `Table.clearRows()`・`removeColumn(_:)`・`removeRow(_:)`・`removeTokens(_:)`・`setInt(_:_:_:)`・`trim()` | 同等 | 表の行と列を書き換える API。表は値型で、行のコピーからは書き換えられないので、表自身に持たせる。列は名前と番号の 2 つの形で、`trim`・`removeTokens` は列を指定する形 (`trim(_:)`・`removeTokens(_:_:)`) も持つ。整えるのはセルだけで、列名は書き換えない。`setInt` は `setFloat` と同じ形で、整数の表記 (`"3"`) で書く。存在しない列・表の範囲外の行には何もせず、1 度だけ警告する | [#3642] |
| `Table.findRow()`・`findRows()`・`matchRow()`・`matchRowIterator()`・`matchRows()` (5 件) | `table.rows.first(where:)`・`filter`・`firstIndex(where:)` (正規表現は Swift の `Regex` と `wholeMatch(of:)`) | 持たない | Swift 標準の API で 1 回の走査で書ける。返る行は読み取り専用のコピーなので、見つけた行を書き換えるときは `firstIndex(where:)` の番号を使って表に書く | [#2468] |
| `Table.getColumnCount()` | `Table.columnCount` | 同等 | プロパティ | — |
| `Table.getFloat()`・`getInt()`・`getString()` (3 件) | `Table.getFloat(_:_:)`・`getInt(_:_:)`・`getString(_:_:)` | 同等 | 表から行の番号と列で 1 つのセルを読む。列は名前と番号の 2 つの形。`rows` は呼ぶたびに全行のコピーを作るので、番号で繰り返すループでは行を経由せずにこの API で読む。`getInt` は `JSONObject.getInt(_:)` と同じく丸めない。存在しない列・表の範囲外の行は、行の API と同じく空の値を返し、1 度だけ警告する | [#3641] |
| `Table.getRow()` | `Table.rows[row]` | 同等 | 返るのは読み取り専用のコピーで、参照ではない (書き換えは表に対して行う) | [#2468] |
| `Table.getRowCount()` | `Table.rowCount` | 同等 | プロパティ。見出しの行は数えない | — |
| `Table.getStringColumn()` | `table.rows.map { $0.getString(column) }` | 持たない | Swift の `map` で 1 回の走査で書ける | — |
| `Table.rows()` | `Table.rows` | 同等 | プロパティで、上から順に並べた行のコピー | — |
| `Table.setFloat()` | `Table.setFloat(_:_:_:)` | 同等 | 列は名前と番号の 2 つの形。存在しない列・表の範囲外の行には書かず、1 度だけ警告する | — |
| `Table.setString()` | `Table.setString(_:_:_:)` | 同等 | 存在しない列・表の範囲外の行の扱いは `setFloat` と同じ | — |
| `Table.sort()` | — | 作例待ち | 並べ替えの方法の選択が分かれる。Processing は列の型 (文字列か数値か) で並べ方を決めるが、mokume の表は列の型を持たずセルを文字列で持つので、文字列の順か数値の順かを API の形 (引数で指定するか、API を 2 つに分けるか) で決める必要がある。並べ替えたい作例が来たら選ぶ | — |

## TableRow

9 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `TableRow` (クラス) | `TableRow` | 同等 | `Table.rows` から取り出す、読み取り専用のコピー。書き換える API を持たない | [#2468]・PR [#2861] |
| `TableRow.getColumnCount()`・`getColumnTitle()` (2 件) | `Table.columnCount`・`Table.columnTitles[column]` | 持たない | 行は表のコピーで、どの行も同じ列を持つ。列の数と名前は表が持つ | — |
| `TableRow.getFloat()` | `TableRow.getFloat(_:)` | 同等 | 列は名前と番号の 2 つの形。10 進表記だけを数値として扱い、数値でなければ NaN を返して警告する | — |
| `TableRow.getInt()` | `TableRow.getInt(_:)` | 同等 | 列は名前と番号の 2 つの形。丸めない (`"2.0"`・`"1e3"` は整数、`"2.5"` は 0 を返して列ごとに 1 度警告する)。表記は `getFloat` と同じ 10 進だけ | [#3641] |
| `TableRow.getString()` | `TableRow.getString(_:)` | 同等 | 列は名前と番号の 2 つの形。存在しない列は空の文字列を返して警告する | — |
| `TableRow.setFloat()`・`setInt()`・`setString()` (3 件) | `Table.setFloat(_:_:_:)`・`Table.setString(_:_:_:)` (整数は `Table.setInt(_:_:_:)`) | 持たない | 行は読み取り専用のコピーで、書き換えは表に行の番号を渡して行う | [#2468]・PR [#2861] |

## XML

28 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `XML` (クラス) | `XML` | 同等 | 値型の要素 1 つで、読み取り専用。空の要素を作る `new XML(name)` は、書き換えと一緒に作例待ち (下の行) | PR [#2180]・[#2466] |
| `XML.addChild()`・`format()`・`removeChild()`・`setContent()`・`setFloat()`・`setInt()`・`setLong()`・`setName()`・`setString()`・`toString()` (10 件) | — | 作例待ち | 値型の要素で、子へ書き戻す方法の選択が分かれる。Processing の `addChild` は追加した子を参照で返してそこへ書かせ、`removeChild` は削除する子を参照で指す。コピーの子を書き換えてもツリーは変わらないので、子を番号で置き換える API など、Processing に無い形を選ぶ必要がある。書き出す API (`format`・`toString`・`saveXML()`) は書き換えとセットでしか使い道が無い。書き換えて書き出す作例が来たら、API の形をまとめて決める | — |
| `XML.getAttributeCount()` | `xml.listAttributes().count` | 持たない | 要素数の取得は `count` だけにする ([#2466] の `JSONArray.size()` と同じ方針) | [#2466] |
| `XML.getChild()` | `XML.getChild(_:)` | 同等 | 名前を渡す形。番号の `getChild(index)` は、引数なしの `getChildren()` で `getChildren()[index]` と書く ([#3645])。無い形: パス (`channel/item`) の名前 (`getChild` を連鎖させて辿る) | [#2466]・PR [#3056] |
| `XML.getChildCount()`・`hasChildren()`・`listChildren()` (3 件) | `xml.getChildren().count`・`.isEmpty`・`.map { $0.getName() }` | 持たない | 子の配列から、数・有無・名前が得られる。要素数の取得は `count` だけにする ([#2466] と同じ方針) | [#2466] |
| `XML.getChildren()` | `XML.getChildren(_:)`・`XML.getChildren()` | 同等 | 名前を渡す形と、引数なしですべての子を返す形 (記述された順。[#3645])。無い形: パスの名前 | PR [#2180]・[#3645] |
| `XML.getContent()` | `XML.getContent()` | 同等 | 記述されたままの文字列 (前後の空白も残る)。文字列が無ければ空の文字列を返し、警告しない | [#2466]・PR [#3056] |
| `XML.getFloat()` | `XML.getFloat(_:)` | 同等 | 属性を数値として読む。10 進表記だけで、数値でなければ NaN を返して警告する | PR [#2180] |
| `XML.getFloatContent()`・`getInt()`・`getIntContent()`・`getName()`・`hasAttribute()`・`listAttributes()` (6 件) | `XML.getFloatContent()`・`getInt(_:)`・`getIntContent()`・`getName()`・`hasAttribute(_:)`・`listAttributes()` | 同等 | 要素の名前、属性の整数値、要素の内容の数値、属性があるか (JSON の `hasKey(_:)` に当たり、警告しない)、属性名の一覧 (JSON の `keys` に当たる。属性は順序を持たないので文字順にそろえる)。数値の表記は `getFloat(_:)` と同じ 10 進だけで、前後の空白は取り除く。**整数は丸めない** (`"4.5"` は 0 を返して警告する。Processing は切り捨てる)。読めなければ NaN か 0 を返し、1 度警告する | [#3645] |
| `XML.getParent()` | — (辿る前の要素を変数に残す) | 持たない | 値型の要素は親を持たない。子はコピーで、親から辿った経路はスケッチの作者が保持する | — |
| `XML.getString()` | `XML.getString(_:)` | 同等 | 属性を文字列として読む。無ければ空の文字列を返して警告する | [#2466]・PR [#3056] |
| `XML.parse()` | `parseXML(_:)` | 持たない | 文字列から読み込む API は関数の `parseXML(_:)` の 1 つにする (`parseJSONObject(_:)` と同じ形。書き方を 2 通りにしない) | — |

## 読み書きの関数

11 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `loadJSONArray()` | `loadJSONArray(_:)`・`requestJSONArray(_:)` | 同等 | 最上位が配列でなければ投げ、エラーの理由が `loadJSONObject` を案内する。無い形: `File` を渡す形 (ファイル名の文字列だけを受ける) | [#2466]・PR [#3056] |
| `loadJSONObject()` | `loadJSONObject(_:)`・`requestJSONObject(_:)` | 同等 | 型として読み込む方法 (`Decodable` と `JSONDecoder`) は API を足さず、`JSONObject` のドキュメントコメントに例を置いた | PR [#2180]・[#2960]・PR [#3449] |
| `loadTable()` | `loadTable(_:header:)`・`requestTable(_:header:)` | 同等 | `"header"` の選択は `header: true`。URL からも読む。無い形: 区切り文字の選択 (`"tsv"` など。区切り文字はカンマだけ) | [#2470]・PR [#2896] |
| `loadXML()` | `loadXML(_:)`・`requestXML(_:)` | 同等 | XML 宣言の `encoding` は読まず UTF-8 として読む (Processing と同じ)。外部エンティティは読み込まない | PR [#2180]・[#2466] |
| `parseJSONArray()`・`parseJSONObject()` (2 件) | `parseJSONArray(_:)`・`parseJSONObject(_:)` | 同等 | TCP・UDP・WebSocket で受信した文字列を読み込む。不正な文字列は投げる (Processing は `null`) | [#2466]・PR [#3056] |
| `parseXML()` | `parseXML(_:)` | 同等 | 受信した文字列の XML を読み込む。読み込み方は `loadXML(_:)` と同じで、不正な文字列は投げる (Processing は `null`)。投げる形は `parseJSONObject(_:)` と同じ (`path` は API の名前) | [#3645] |
| `saveJSONArray()` | `saveJSONArray(_:_:)` | 同等 | `JSONArray` を JSON のファイルに書き出す。書式 (UTF-8・LF・インデント 2・同じ値から同じファイル) は `saveJSONObject(_:_:)` と同じ。保存先の扱いと、書き込み途中のファイルを残さないことは `saveTable(_:_:)` と同じ | [#3644] |
| `saveJSONObject()` | `saveJSONObject(_:_:)` | 同等 | `JSONObject` を JSON のファイルに書き出す。キーは `keys` と同じ文字順で書き、同じ値から同じファイルになる (UTF-8・LF・インデント 2)。読み込んだ桁数の多い数値 (`JSONSerialization` が `NSDecimalNumber` で渡すもの) は桁を保ったまま書く。**読み込みで丸まった数値は丸まった値を書く** (`9007199254740993.0` は `9007199254740992.0`、`1.0000000000000001` は `1.0`)。書けなければ投げ (Processing は `false` を返す)、書き込み途中のファイルを残さないことは `saveTable(_:_:)` と同じ | [#3643] |
| `saveTable()` | `saveTable(_:_:)` | 同等 | 書けなければ投げる (Processing は `false` を返す)。無い形: 区切り文字の選択 (`"tsv"` など) | [#2468]・PR [#2861] |
| `saveXML()` | — | 作例待ち | `XML` の書き換えとセット (XML の節の作例待ちの行) | — |

[#2180]: https://github.com/mokume-metal/mokume/pull/2180
[#2466]: https://github.com/mokume-metal/mokume/issues/2466
[#2468]: https://github.com/mokume-metal/mokume/issues/2468
[#2470]: https://github.com/mokume-metal/mokume/issues/2470
[#2861]: https://github.com/mokume-metal/mokume/pull/2861
[#2896]: https://github.com/mokume-metal/mokume/pull/2896
[#2960]: https://github.com/mokume-metal/mokume/issues/2960
[#3056]: https://github.com/mokume-metal/mokume/pull/3056
[#3449]: https://github.com/mokume-metal/mokume/pull/3449
[#3641]: https://github.com/mokume-metal/mokume/issues/3641
[#3642]: https://github.com/mokume-metal/mokume/issues/3642
[#3643]: https://github.com/mokume-metal/mokume/issues/3643
[#3644]: https://github.com/mokume-metal/mokume/issues/3644
[#3645]: https://github.com/mokume-metal/mokume/issues/3645
