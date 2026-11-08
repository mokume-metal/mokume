<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# ADR-0048: import の入口は読み手ごとに分ける — 同じファイルで出会わない名前は衝突させてよい

## 状態

採用 (2026-11-08)

## 文脈

### 1 つの入口を、読み手の違う 3 者が共有している

[ADR-0016](0016-package-structure.md) 決定 2 は、すべてを再エクスポートするアンブレラ `mokume` を 1 つ用意し、利用者は 1 行の import で全機能に届くと決めた。内部の割り方を書き味に漏らさないためである ([ADR-0001](0001-founding-principles.md) 原則 1)。

2026-11-08 時点で、`import mokume` を書く人は 3 種類いる。

| 読み手 | 書くもの | 要るもの |
| --- | --- | --- |
| スケッチを書く人 | `final class Game: Sketch` と `draw()` | Processing に対応した面 (トップレベル関数・`Image`・`Font`・`Shape`・`Scene` …) |
| SwiftUI に埋め込む人 | `@main struct …: App` と `SketchView(Game())` | `SketchView` と、その引数に要る型 |
| 道具・外のパッケージ・検査 | 窓を出さずにスケッチを走らせ、画素を読み、入力を注入する | 実行の土台 (`SketchRuntime` など) |

1 つの入口がこの 3 者に同じものを読ませるので、次の 2 つが起きていた ([#3814](https://github.com/mokume-metal/mokume/issues/3814))。

### 埋め込むファイルで、SwiftUI と同じ名前の型が衝突する

mokume は SwiftUI と同じ名前の型を公開している: `Canvas`・`Circle`・`Font`・`Gradient`・`Image`・`Path`・`Shape`・`Shader` (`MokumeCore`)・`Scene` (`MokumeGame`)。[#2595](https://github.com/mokume-metal/mokume/issues/2595) で `Color` も加わる。[ADR-0020](0020-api-naming-and-surface.md) 決定 1 の規則 4 は、これを「衝突するのは埋め込むファイルだけで、`mokume.Circle` と書けば解ける」として許していた。

その埋め込むファイルは、例外ではなくなった。[ADR-0045](0045-game-direction.md) 決定 11 で、iOS の出口は SwiftUI の `SketchView` になった。macOS でも `SketchView` で埋め込める。SwiftUI のアプリの入口は必ず `var body: some Scene` を書く。

小さなモジュールで衝突の出方を確かめた (Swift 6.4.2・#3814)。

| 書き方 | 結果 |
| --- | --- |
| 型を書く位置 (`let t: Image?`・`var body: some Scene`) | ライブラリ側が SwiftUI を import していてもいなくても `'Image' is ambiguous for type lookup in this context` で組めない |
| 呼び出しの位置 (`Image("x")`) | ライブラリ側が SwiftUI を import していると、ライブラリの型に**黙って決まる** (import した側の宣言が import された側を隠す、という Swift の規則) |

`SketchView` の説明文は、モジュール名を付けて書き分けるか、SwiftUI の型を個別に import するよう案内していた。文書で避け方を教えるだけで、構造では防いでいなかった。

### 実行の土台が、スケッチを書く人の補完に並ぶ

`SketchRuntime`・`SketchApplication`・`SharedFrameWindow`・`InputState`・`ObservationReport` などは `public` である。[ADR-0027](0027-readable-surfaces.md) 決定 5 は、これらを参照の面 (DocC) から外したうえで「`public` は 1 つも動かさない」と決めた。道具・エージェント・外のパッケージが使えるようにするためである。そのため、文書には出ないが補完には並ぶ。

外のパッケージは実際に使っている。2026-11-08 に手元の clone を数えると、mokume-syphon・mokumesh・probes が `SketchRuntime` を窓なし実行の入口にしていた。3 つに共通する使い方は、起動 (`SketchRuntime(sketch:gpu:)`)・進める (`advance()`)・画素を読む (`target.encodeForDisplay()`)・後始末 (`closePlugins()`) の 4 つで、probes はさらに入力の注入 (`input.enqueue`) と窓の経路 (`SketchApplication(...).run()`) を使う。全員が後始末を手で呼び、内部の部品 `target` を経由して画素を読んでいる。生の部品が、そのまま外への口になっていた。

## 決定

### 1. 入口は読み手ごとに 1 つ持つ

| 読み手 | 入口 | 中身 |
| --- | --- | --- |
| スケッチを書く人 | `import mokume` | いまの面。Processing に対応した名前を手本に寄せて持つ |
| SwiftUI に埋め込む人 | `import MokumeUI` | `SketchView` と、埋め込みに要る型だけ (決定 2) |
| 道具・外のパッケージ・検査 | `import MokumeHost` | 窓を出さずにスケッチを走らせる口 (決定 3) |
| 本体の中 | なし | 実行の土台の生の部品。`package` に下げる |

**どの読み手にも、要らないものを読ませない。** 入口を分ける基準は、内部の層の割り方 (ADR-0016 決定 1) ではなく、読み手である。読み手ごとの入口は、それぞれ 1 行の import で足りる。ADR-0016 決定 2 の「内部の割り方が書き味に漏れない」は、そのまま保たれる。

`MokumeUI`・`MokumeHost` の名前は仮である。名前を変えても、この決定は変わらない。

### 2. `MokumeUI` は名指しで再エクスポートし、SwiftUI と衝突する名前を出さない

`MokumeUI` は `MokumeCore` を丸ごと再エクスポートしない。埋め込みに要る型 (`SketchSettings` など) だけを `@_exported import struct …` で宣言単位に名指しする。名指しする型は、SwiftUI と同じ名前を含まない。

これで、ADR-0020 決定 1 の規則 4 の根拠「衝突するのは埋め込むファイルだけ」を、注意書きではなく構造で保証する。埋め込むファイルは `mokume` を読まないので、スケッチ用の型は `mokume` の中で SwiftUI と同じ名前を取ってよい。スケッチと SwiftUI を同じファイルに書く人には、ファイルを分けるか、モジュール名を付けて書くよう案内する。

雛形が出すアプリの外枠 (ADR-0045 決定 12) は `import MokumeUI` を書く。

試作で確かめたこと: UI 役のモジュールが Core 役を `public import` し、`@_exported import struct Core.SketchSettings` だけを名指しした。App 側は `import SwiftUI` と `import UI` だけで、`some Scene`・`Image("logo")` が SwiftUI の型に決まった。別ファイルで書いたスケッチも `SketchView(Game(), settings: SketchSettings())` で渡せた。`MemberImportVisibility`・`InternalImportsByDefault` を有効にしても通った。

### 3. `MokumeHost` は設計した口として持ち、生の部品を外の口として固めない

外のパッケージに渡すのは、実行の土台そのものではなく、そのために設計した口である。

- **寿命は口が持つ。** 抜けたら資源が閉じる形 (`HeadlessRun.with(Game()) { run in … }` など) にし、利用者に後始末を呼ばせない
- **画素は値で渡す。** 内部の描画先を経由させない
- **入力は注入の口で受ける**
- **下限は、外の 3 リポに共通する使い方 (起動・進める・画素・後始末)**。窓を開いて走らせる口まで持つかは、probes の使い方を見て実装の段 ([#3870](https://github.com/mokume-metal/mokume/issues/3870)) で決める

生の部品 (`SketchRuntime` など) は `package` に下げる ([#3871](https://github.com/mokume-metal/mokume/issues/3871))。外のパッケージが `MokumeHost` へ移った後に下げる。

### 4. スケッチの面は変えない

- **スケッチ用の型の名前は、手本に寄せたまま残す。** `Image`・`Font`・`Shape`・`Scene`・`Color` を SwiftUI に合わせて改名しない
- **トップレベル関数 (`red`・`map`・`dist` …) と、Darwin の関数の名指しの再エクスポートを残す。** これらは Processing の API との対応 ([ADR-0041](0041-standard-scope-map.md) 決定 3) そのものである。`MokumeUI` は再エクスポートしないので、SwiftUI のファイルには入らない
- 利用者が `let red = 255` と書くと、同じ名前の関数は隠れる。これは普通の Swift の隠し方で、試作でもそれ以上の害は出なかった (`red(3)` と書けば `cannot call value of non-function type 'Int'` になる)

### 5. 退けた案

| 案 | 退けた理由 |
| --- | --- |
| 衝突する型の名前を変える (`Picture`・`Typeface` など) | 衝突は埋め込むファイルでしか起きないのに、一番大事な読み手であるスケッチを書く人の書き味を全員分変える |
| 型を `enum Mokume { … }` に入れ、スケッチ側には短い名前を別名で出す | 同上。加えて、別名は正本を 2 つにするとして ADR-0020 決定 1 が退けている |
| トップレベル関数を `Sketch` のメソッドにする (Processing の `PApplet` と同じ形) | スケッチの外の補助の struct (`Particle` など) から `dist`・`map` を呼べなくなる。Java の内部クラスと違い、Swift の別の型は `Sketch` のメンバーに届かない |
| 生の部品に `@_spi(Host)` を付けて補完から隠す | 安く済むが、`target`・`closePlugins()` のような内部の部品を、そのまま外への口として固める。二番手として残す (`MokumeHost` の設計が行き詰まったときの退避先) |
| 生の部品を `package` に下げるだけ | 外のパッケージ 3 つが組めなくなる。代わりの口 (決定 3) とセットでしか取れない |
| 文書の注意書きのまま (いまの `SketchView` の説明文) | 衝突はアプリの入口で必ず起きるので、全員がまず組めない状態に当たり、それから文書を探すことになる |

## 影響

- **置き換える決定**:
  - ADR-0016 決定 2: 入口を 1 つにする → 決定 1 で、読み手ごとに 1 つ
  - ADR-0020 決定 1 の規則 4: 根拠を決定 2 で構造に置き換える。SwiftUI と同じ名前の型を取ってよいのは、`mokume` の面に限る
  - ADR-0020 決定 7: 冒頭の前提「入口は 1 つ」を、決定 1 で置き換える。外のモジュールを丸ごと再エクスポートしない規律は、`MokumeUI` にも同じく効く
  - ADR-0027 決定 5: 「`public` は 1 つも動かさない」→ 決定 3 で、生の部品は `package` に下げ、外のパッケージには `MokumeHost` を渡す
  - ADR-0045 決定 11: `SketchView` は `MokumeUI` に置く (ADR-0045 側で改訂)
- **代償**:

  | 誰が | 何を払うか |
  | --- | --- |
  | スケッチを書く人 | なし |
  | 埋め込む人 | SwiftUI のファイルの import を `import MokumeUI` に替える |
  | 外のパッケージ (mokume-syphon・mokumesh・probes) | `SketchRuntime` から `MokumeHost` へ移る |
  | 本体 | 入口が 3 つになり、どれを使うかを文書で教える。`MokumeUI` が出す型は名指しの一覧になり、足すたびに判断する。`MokumeHost` は公開の口として版ごとの互換を保つ対象になる |

- **検査の対象**: `make api` の `API_MODULES` と参照の面 (`REFERENCE_MODULES`) に、新しいモジュールが加わる。生の部品を `package` に下げると、`REFERENCE_OMIT` の名指しの多くが要らなくなる
- **未実装** (2026-11-08): 決定 1〜3 はまだコードに無い。実装は [#3870](https://github.com/mokume-metal/mokume/issues/3870) (`MokumeHost`)・[#3871](https://github.com/mokume-metal/mokume/issues/3871) (`package` に下げる。#3870 の後)・[#3872](https://github.com/mokume-metal/mokume/issues/3872) (`MokumeUI`) が持つ。iOS ([#2605](https://github.com/mokume-metal/mokume/issues/2605)) の `SketchView` は #3872 の上に載せる
- [#2595](https://github.com/mokume-metal/mokume/issues/2595) (`LinearRGBA` → `Color`) は、この ADR の実装を待たない。`MokumeUI` は `Color` を再エクスポートしない

> 破れたとき: 埋め込むファイルが `import mokume` を書かないと SwiftUI の部品に届かない形にする (`MokumeUI` が `MokumeCore` を丸ごと再エクスポートする、または必要な型を出し漏らす)。衝突がアプリの入口に戻ってくる。
