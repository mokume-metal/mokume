<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# データ: 文字列・配列・リスト・辞書・変換

Processing 本体のリファレンスのうち、基本の型 (`int`・`float`・`color` ほか)・型の変換・配列の関数・文字列の関数と `String`・`IntList`・`FloatList`・`StringList`・`IntDict`・`FloatDict`・`StringDict` の 162 件。内訳は、基本の型 8 件、複合の型 5 件、型の変換 10 件、配列の関数 9 件、文字列の関数 10 件、`String` のメソッド 7 件、リストと辞書 113 件 (クラスのページ 6 とメソッド 107)。`JSONObject`・`JSONArray`・`Table`・`TableRow`・`XML` のクラスのページと `load`・`parse`・`save` の関数は、データ: JSON・Table・XML の表 ([data-json-table-xml.md](data-json-table-xml.md)・[#3592]) が数えているので、この表に数えない。表の形式・バージョン・数え直す式は [README](README.md) にある。照合したのは processing-website `f4acef8` (2026-10-29) と mokume の main `5b60ed75` (2026-11-24)。

| 区分 | 件数 |
| --- | --- |
| 同等 | 1 |
| 入れる | 0 |
| 作例待ち | 0 |
| 持たない | 161 |
| 計 | 162 |

この領域に共通すること:

- **Swift の言語・標準ライブラリで同じことが書けるものは「持たない」とし、理由の欄に Swift での書き方を書く** (README「行の単位とまとめ方」)。mokume にはこの領域の API が無く、`nf()`・`split()`・`IntList` に当たる名前の API を足す理由が無い。名前だけ違う API は足さない ([#2466])
- **リストは `[Int]`・`[Float]`・`[String]`、辞書は `[String: Int]`・`[String: Float]`・`[String: String]`。どれも値型で、代入するとコピーになる** (Processing のリストと辞書は参照型で、共有した変数が同時に変わる)。範囲の外の添字は Swift が実行を止める (Processing の `IntList.get()` も例外を投げる)。存在しないキーは `nil` で、`dict["key", default: 0]` で既定値を渡せる
- **`Dictionary` は並びを保たない。** Processing の辞書は入れた順に並び、`sortKeys()`・`sortValues()` で並べ替える。Swift の `Dictionary` は反復の順が保証されず、実行ごとに変わりうる。順が絵に出るなら、`dict.sorted { $0.key < $1.key }` で並べた配列を使う。決定論 ([ADR-0025](../decisions/0025-determinism-levels.md)) を守るには、順に依らない書き方にする
- **乱数を使う並べ替えは、スケッチの乱数の列を渡す。** `shuffle()` に当たる `shuffled()` は、何も渡さないと実行ごとに違う並びになる。`shuffled(using: &randomSource)` と書けば `randomSeed` に従う ([math.md](math.md) の `random()` の行)
- **数の書式 (`nf()` ほか) と文字列の前後の空白を除く `trim()` は、Foundation の `String(format:)`・`trimmingCharacters(in:)` で書く。** `import mokume` は Foundation を再輸出しないので、`import Foundation` を足す。毎フレーム呼ぶ文字列の組み立ては描画のコストに入る
- **`int("12")` のような文字列からの変換は、Swift では失敗が `nil`** (`Int("12")`)。Processing は失敗を 0 や NaN で返す。`?? 0` で同じにできる

## 基本の型

8 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `boolean`・`byte`・`char`・`double`・`float`・`int`・`long` (7 件) | `Bool`・`Int8`・`Character` (`UInt16`)・`Double`・`Float`・`Int`・`Int` (`Int64`) | 持たない | 言語の基本の型。`int` は 64 ビットの `Int` (Processing は 32 ビット)、`byte` は符号つきの `Int8` (Java と同じ。`UInt8` は 0〜255)、`char` は Unicode のスカラー値でなく書記素の `Character`。API の層の数は `Float` が基本で、`Int`・`Double` もそのまま渡せる ([ADR-0035](../decisions/0035-numeric-reception.md)) | — |
| `color` | `LinearRGBA` | 同等 | 色を持つ型。Processing の `color` は `int` だが、mokume は作業空間 (線形・乗算済み) の値型。作り方・読み方は色の表の `color()`・`red()` ほか ([color-transform-rendering.md](color-transform-rendering.md)) | [#669] |

## 複合の型

5 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `Array` | `[T]` (`Array`) | 持たない | 言語の配列。値型でコピーされ、範囲の外の添字は Swift が実行を止める。2 次元は `[[T]]` | — |
| `ArrayList` | `[T]` | 持たない | 大きさの変わる配列。Swift の `Array` がそのまま大きさが変わる (`append`・`remove(at:)`・`insert(_:at:)`) | — |
| `HashMap` | `[Key: Value]` (`Dictionary`) | 持たない | キーと値の組。並びを保たない (上の共通のこと) | — |
| `Object` | `Any`・`AnyObject` | 持たない | Java の根の型。Swift では型を決めるか、プロトコル (`Hashable` など) で書く | — |
| `String` (クラスのページ) | `String` | 持たない | 言語の文字列。値型で、長さ・添字は書記素の単位 (Processing は UTF-16 の単位)。メソッドは下の「`String` のメソッド」 | — |

## 型の変換

10 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `boolean()`・`byte()`・`char()`・`float()`・`int()`・`str()` (6 件) | `Bool(_:)`・`Int8(truncatingIfNeeded:)`・`Character(_:)`・`Float(_:)`・`Int(_:)`・`String(_:)` (または `"\(x)"`) | 持たない | 型の初期化子で変換する。`Int(x)` は小数を 0 へ向けて切り捨て (Processing の `int()` と同じ)、`Float` が数でない値や無限の値のときは実行が止まるので `Int(exactly:)` か `isFinite` で確かめる。文字列からは失敗が `nil` (上の共通のこと)。配列を渡す形 (`int(array)`) は `array.map { Int($0) }` | — |
| `binary()`・`hex()`・`unbinary()`・`unhex()` (4 件) | `String(_:radix:)`・`Int(_:radix:)` | 持たない | `String(n, radix: 2)`・`String(n, radix: 16, uppercase: true)` で書き、読み戻しは `Int(s, radix: 16)`。**桁を固定する形** (`hex(value, 6)`・`binary(value, 8)`) は、左に `0` を足して自分で揃える (`nf()` と同じ書き方)。色の 16 進は `color(hex:)` ([color-transform-rendering.md](color-transform-rendering.md)) | — |

## 配列の関数

9 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `append()`・`concat()`・`expand()`・`splice()` (4 件) | `append(_:)`・`+`・`append(contentsOf:)`・`Array(repeating:count:)`・`insert(contentsOf:at:)` | 持たない | Processing は新しい配列を返す (元は変わらない)。Swift は `var` の配列を書き換える形と、`+` で新しい配列を返す形の両方がある。`expand()` は配列の大きさを 2 倍にして返す関数で、Swift の配列は自分で大きくなるので要らない | — |
| `reverse()`・`sort()`・`shorten()`・`subset()` (4 件) | `reversed()`・`sorted()`・`dropLast()`・`array[start..<end]` | 持たない | `sorted()` は新しい配列を返し、元を並べ替えるなら `sort()`。並べ替えの順を指定する形は `sorted { $0 > $1 }`。`sort(array, count)` の先頭の `count` 個だけを並べる形は `array.prefix(count).sorted()`。`subset(array, start, count)` は `array[start..<start + count]` (`ArraySlice` なので、配列にするなら `Array(…)`) | — |
| `arrayCopy()` | 代入・`replaceSubrange(_:with:)` | 持たない | 値型なので、`let b = a` がコピーになる。範囲を別の配列へ写すのは `replaceSubrange` | — |

## 文字列の関数

10 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `join()`・`split()`・`splitTokens()` (3 件) | `joined(separator:)`・`split(separator:)`・`split(whereSeparator:)` | 持たない | `split(separator:)` は既定で空の要素を捨てる。Processing の `split()` は捨てない (`"a,,b"` が 3 要素) ので、同じにするなら `omittingEmptySubsequences: false`。`splitTokens()` は空を捨てるので、既定のままの `split(whereSeparator:)` が同じ | — |
| `trim()` | `trimmingCharacters(in: .whitespacesAndNewlines)` (Foundation) | 持たない | 前後の空白を除く。標準ライブラリだけでは書けず Foundation の関数を使う (上の共通のこと)。配列を渡す形は `map` で書く | — |
| `match()`・`matchAll()` (2 件) | `Regex`・`firstMatch(of:)`・`matches(of:)` | 持たない | 正規表現の一致。Swift の `Regex` が、全体とグループの取り出しを持つ。Processing の `match()` は一致しなければ `null`、mokume 側は `nil` | — |
| `nf()`・`nfc()`・`nfp()`・`nfs()` (4 件) | `String(format:)` (Foundation)・`formatted()` | 持たない | 数の書式。`nf(n, 4)` は `String(format: "%04d", n)`、小数は `String(format: "%.2f", x)`、桁区切りの `nfc()` は `n.formatted()`、符号を付ける `nfp()` は `"%+d"`、正の符号の位置に空白を置く `nfs()` は `"% d"`。連番のファイル名は `beginRecord("out/f-####.png")` の `####` が書く ([input-output-environment.md](input-output-environment.md)) | — |

## `String` のメソッド

7 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `String.charAt()`・`String.indexOf()`・`String.substring()` (3 件) | `s[s.index(s.startIndex, offsetBy: i)]`・`s.firstIndex(of:)`・`s.prefix(_:)`・`s.dropFirst(_:)` | 持たない | `String` の添字は整数でなく `String.Index` で、整数で数えるなら `Array(s)` にする (書記素の単位。絵文字や結合文字を 1 つとして数える)。`indexOf()` は部分文字列なら `s.range(of:)` (Foundation) | — |
| `String.equals()`・`String.length()` (2 件) | `==`・`count` | 持たない | 比較は `==` (Unicode の正規化で等しいものを等しいとする)。`count` は書記素の数で、UTF-16 の単位の数ではない | — |
| `String.toLowerCase()`・`String.toUpperCase()` (2 件) | `lowercased()`・`uppercased()` | 持たない | 小文字・大文字にした新しい文字列を返す | — |

## リストと辞書

113 件。リスト (`IntList`・`FloatList`・`StringList`) と辞書 (`IntDict`・`FloatDict`・`StringDict`) を、クラスのページとメンバーで 1 行ずつにまとめた。行ごとの件数は `(N 件)`。`FloatDict.maxIndex()`・`minIndex()` は、リファレンスの category が `floatlist` だが所属は `FloatDict` なので、`FloatDict` の行に数える。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `IntList`・`IntList.get()`・`set()`・`size()`・`append()`・`remove()`・`clear()`・`hasValue()`・`toArray()`・`array()` (10 件) | `[Int]`: `a[i]`・`a[i] = v`・`count`・`append(_:)`・`remove(at:)`・`removeAll()`・`contains(_:)`・代入 | 持たない | `toArray()`・`array()` は、すでに配列なので要らない。`remove(index)` が返す値は `remove(at:)` の戻り値。値型 (共通のことの段落) | — |
| `IntList.sort()`・`sortReverse()`・`reverse()`・`shuffle()`・`max()`・`min()` (6 件) | `sort()`・`sort(by: >)`・`reverse()`・`shuffle(using: &randomSource)`・`max()`・`min()` | 持たない | `max()`・`min()` は空の配列で `nil` (Processing は例外)。`shuffle()` は乱数の列を渡す (共通のことの段落) | — |
| `IntList.add()`・`sub()`・`mult()`・`div()`・`increment()` (5 件) | `a[i] += v`・`-=`・`*=`・`/=`・`a[i] += 1` | 持たない | 添字の 1 つの要素への演算。全要素へ掛ける形は `a.map { $0 * 2 }`。`IntList.div()` は整数の割り算 | — |
| `FloatList`・`FloatList.get()`・`set()`・`size()`・`append()`・`remove()`・`clear()`・`hasValue()`・`toArray()`・`array()` (10 件) | `[Float]` | 持たない | `IntList` と同じ。`hasValue()` は `contains(_:)` で、数でない値を探すなら `contains { $0.isNaN }` | — |
| `FloatList.sort()`・`sortReverse()`・`reverse()`・`shuffle()`・`max()`・`min()` (6 件) | `sort()`・`sort(by: >)`・`reverse()`・`shuffle(using: &randomSource)`・`max()`・`min()` | 持たない | `Float` は `Comparable` なので `sort()` が使えるが、数でない値が混じると並びが決まらない | — |
| `FloatList.add()`・`sub()`・`mult()`・`div()` (4 件) | `a[i] += v`・`-=`・`*=`・`/=` | 持たない | `IntList` の演算と同じ | — |
| `StringList`・`StringList.get()`・`set()`・`size()`・`append()`・`remove()`・`clear()`・`hasValue()`・`toArray()`・`array()` (10 件) | `[String]` | 持たない | `IntList` と同じ | — |
| `StringList.sort()`・`sortReverse()`・`reverse()`・`shuffle()` (4 件) | `sort()`・`sort(by: >)`・`reverse()`・`shuffle(using: &randomSource)` | 持たない | 文字列の並べ替えは Unicode の順 | — |
| `StringList.lower()`・`upper()` (2 件) | `map { $0.lowercased() }`・`map { $0.uppercased() }` | 持たない | 全要素を小文字・大文字にする | — |
| `IntDict`・`IntDict.get()`・`set()`・`size()`・`remove()`・`clear()`・`hasKey()`・`keys()`・`keyArray()`・`values()`・`valueArray()` (11 件) | `[String: Int]`: `d[k]`・`d[k] = v`・`count`・`removeValue(forKey:)`・`removeAll()`・`d[k] != nil`・`d.keys`・`Array(d.keys)`・`d.values`・`Array(d.values)` | 持たない | 存在しないキーの `get()` は例外 (Processing)、Swift は `nil` | — |
| `IntDict.sortKeys()`・`sortKeysReverse()`・`sortValues()`・`sortValuesReverse()` (4 件) | `d.sorted { $0.key < $1.key }`・`d.sorted { $0.value > $1.value }` | 持たない | 辞書自体は並び替えられない。並べた `[(key: String, value: Int)]` を得る。値が同じ要素の順は決まらないので、キーで 2 次の並べ替えをする | — |
| `IntDict.add()`・`sub()`・`mult()`・`div()`・`increment()` (5 件) | `d[k, default: 0] += v`・`-=`・`*=`・`/=`・`d[k, default: 0] += 1` | 持たない | キーが無ければ作る (`default:`)。Processing の `add()` は無ければ作り、`sub()`・`mult()`・`div()` は無ければ例外 | — |
| `FloatDict`・`FloatDict.get()`・`set()`・`size()`・`remove()`・`clear()`・`hasKey()`・`keys()`・`keyArray()`・`values()`・`valueArray()` (11 件) | `[String: Float]` | 持たない | `IntDict` と同じ | — |
| `FloatDict.sortKeys()`・`sortKeysReverse()`・`sortValues()`・`sortValuesReverse()`・`maxIndex()`・`minIndex()` (6 件) | `d.sorted { … }`・`d.max { $0.value < $1.value }?.key`・`d.min { … }?.key` | 持たない | `maxIndex()`・`minIndex()` は最大・最小の値を持つキーを返す。空の辞書では `nil` | — |
| `FloatDict.add()`・`sub()`・`mult()`・`div()` (4 件) | `d[k, default: 0] += v` ほか | 持たない | `IntDict` と同じ | — |
| `StringDict`・`StringDict.get()`・`set()`・`size()`・`remove()`・`clear()`・`hasKey()`・`keys()`・`keyArray()`・`values()`・`valueArray()` (11 件) | `[String: String]` | 持たない | `IntDict` と同じ | — |
| `StringDict.sortKeys()`・`sortKeysReverse()`・`sortValues()`・`sortValuesReverse()` (4 件) | `d.sorted { … }` | 持たない | `IntDict` と同じ | — |

## 入れる

この領域に「入れる」の行は無い。Feature は起票していない。

[#669]: https://github.com/mokume-metal/mokume/issues/669
[#2466]: https://github.com/mokume-metal/mokume/issues/2466
[#3592]: https://github.com/mokume-metal/mokume/issues/3592
