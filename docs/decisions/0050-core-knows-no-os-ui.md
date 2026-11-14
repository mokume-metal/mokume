<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# ADR-0050: MokumeCore は OS の UI 部品を知らない — macOS の単独のウィンドウの外枠は MokumeMac に置く

## 状態

採用 (2026-11-15)

## 文脈

### ウィンドウの外枠が、描画コアと同じターゲットにあった

2026-11-08 の時点で、MokumeCore の中で AppKit・SwiftUI を import するファイルは 19 本あった。`Display/` の 15 本 (`SketchApplication`・ウィンドウ・表示リンク・カーソル・ポインタの捕まえ・ファイルの選択・閉じる前の確認・知らせの重ね・メニューバーの名乗りなど) と、`Parameters/` のつまみの UI の 4 本である。描画の中核 (Metal 4・CoreText・ImageIO) は AppKit を参照しない ([ADR-0045](0045-game-direction.md) 決定 11 の注)。

iOS / iPadOS へは単独のウィンドウではなく、埋め込めるビュー `SketchView` で出す ([ADR-0045](0045-game-direction.md) 決定 11)。外枠が Core にあるままだと、Core を iOS で組むために、19 本を `#if os(macOS)` で囲うことになる。囲った範囲は描画コアの中に散り、どこまでが macOS 専用かをファイルごとに読むことになる。

Core からウィンドウの層を呼んでいるのは、コードの中では 3 か所だけだった: ランタイムが全画面の大きさを決めるための画面の一覧 (`Display`)・走り続けるスケッチのメニューバーの名乗り (`SketchPresence`)・入口 `Sketch.main()` である ([#3804](https://github.com/mokume-metal/mokume/issues/3804))。

## 決定

### 1. MokumeCore は AppKit・SwiftUI・UIKit を import しない。macOS の単独のウィンドウの外枠は `MokumeMac` に置く

`MokumeMac` は macOS 専用のターゲットで、スケッチを単独のウィンドウで走らせる外枠を持つ: `SketchApplication`・ウィンドウ・表示リンク・カーソル・ポインタの捕まえ・ファイルの選択・閉じる前の確認・知らせの重ね・メニューバーの名乗り・つまみの UI・`Sketch.main()`。外枠だけが使う部品 (全速で回す駆動・速さの名乗り・スクロールの単位) も同じ所に置く。

値・形式・描画・実行・観測・書き出しは Core に残す。外枠を抜いた Core の中は割らない。macOS の外枠を Core から抜けば、Core は `#if` なしで iOS 向けにも組める見込みで、macOS 専用の範囲はターゲットの名前で読める。

守らせるのは、iOS で Core を組むビルド ([#3635](https://github.com/mokume-metal/mokume/issues/3635) が足す) である。この決定のための検査は足さない。

> 破れたとき: Core に OS の UI 部品の import が戻り、iOS のビルドが組めなくなるか、`#if os(macOS)` が描画コアの中に散る。

### 2. 層は「コア依存」。入口のアンブレラが macOS のときだけ再エクスポートする

`MokumeMac` は [ADR-0016](0016-package-structure.md) 決定 1 の「コア依存」の層に置く (依存は MokumeCore と MokumeDiagnostics だけ)。利用者が選んで import する product にはしない。アンブレラ `mokume` が `.when(platforms: [.macOS])` で依存し、macOS のときだけ再エクスポートする。利用者の `import mokume` と `Game.main()` は書き換えずに動き、`Sketch.main()` の説明文と参照の面も変わらない。

[ADR-0048](0048-entry-per-reader.md) の入口のうち、`MokumeUI` は macOS で `SketchView` が包む `NSView` (`SketchHostView`) のために、`MokumeHost` は決定 3 の差し込みのために、どちらも macOS のときだけ `MokumeMac` に依存する。`MokumeHost` はウィンドウを開く口を持たない ([ADR-0048](0048-entry-per-reader.md) 決定 3 の改訂 (2026-11-08)) ままで、`MokumeMac` の口を利用者に見せない。

iOS の外枠をどこに置くか (`MokumeUI` の中に `#if` で置くか、iOS 専用のターゲットを並べるか) は、iOS の段 ([#3636](https://github.com/mokume-metal/mokume/issues/3636) 以降) で決める。[ADR-0045](0045-game-direction.md) 決定 11 (iOS へは `SketchView` で出す) は変わらない。

> 破れたとき: アンブレラが無条件に `MokumeMac` を再エクスポートし、iOS で `import mokume` が組めない。あるいは `MokumeMac` が product になり、スケッチを書く人が import を選ぶことになる。

### 3. Core が OS の UI 部品に頼る 2 つの口は、外枠が差し込む

Core は口だけを持ち、macOS の部品は `MokumeMac` の `MacPlatform.install()` が差し込む。

| 口 (Core) | 差し込むもの (MokumeMac) | 差し込まれる前 |
| --- | --- | --- |
| `Display.screenReader` (画面の読み) | `NSScreen` から読む `Display.readings()` | 空の一覧 |
| `SketchRuntime.makePresence` (名乗りの係) | `SketchPresence` | 名乗らない |

画面の一覧の組み方 (番号の振り方・全画面の大きさ・選び方) は純粋な関数で、Core に残る。差し込むのは、ランタイムを組む入口である: `SketchApplication` の組み立て (`Sketch.main()` と `SketchView` もここを通る)・`MokumeHost` の `HeadlessRun`・参照スケッチの書き出し。どれも設定 (`sketch.settings`) を読む前に差し込むので、設定の中で `displays` を読んでも、全画面を頼んでも、これまでと同じに働く。

退けた案:

- **画面を CoreGraphics だけで読む。** `CGDisplay` の系統は名前・使える範囲・カメラの切り欠きを返さない。全画面の大きさと名前が変わる。iOS には `CGDisplay` が無いので、Core に `#if` が戻る
- **`MokumeMac` の読み込み時に自動で差し込む** (`@section("__DATA,__mod_init_func")`)。検査のバンドルが窓の透明化に使っている形だが、製品のライブラリに読み込み時の副作用を持たせることになり、差し込みが入口のコードから読めない
- **ウィンドウを出さない口は差し込まない。** `HeadlessRun` を `MokumeMac` に依存させずに済むが、ウィンドウなしの実行で `displays` が空になり、全画面を頼むスケッチが組めなくなる。走り続けても名乗らなくなる。どちらもこれまでの振る舞いからの変更である

> 破れたとき: 入口が差し込みを忘れ、その入口だけ画面の一覧が空になる (全画面を頼むスケッチが「繋がっていない」で断られる)。検査は `MacPlatformTests` と `HeadlessRunPlatformTests` が、口を空に戻してから入口を組んで見る。

### 4. `MokumeMac` が使う Core の `package` の道は、外に届かない道の表に載せない

`MokumeMac` は Core の内部を `package` で使う (割ったときに、Core に残ったファイルの `package` の宣言が 42 ファイルで 216 件増えた)。[ADR-0042](0042-camera-and-audio-standard.md) 決定 3 の改訂 (2026-11-07) は、コア依存の層のターゲットが使う `package` の道を「外に届かない道」として名指しし、外のパッケージが要求したら開くと決めている。`MokumeMac` は同じ層にあるが、検索の対象 (`T`) に加えない。

その表が扱うのは、外とやりとりする領域 (カメラ・音など) で、外のパッケージも同じ領域を書きうるもの (深度カメラ・NDI など) である。`MokumeMac` の道は、Core の内部を外枠のためにターゲットの境で分けたもので、外のパッケージが同じものを書く場面が無い。スケッチをウィンドウで走らせる入口は `Sketch.main()`、埋め込む入口は `SketchView`、ウィンドウなしは `HeadlessRun` で、外のパッケージが自前の外枠を書く要求は無い ([ADR-0048](0048-entry-per-reader.md) 決定 3)。

> 破れたとき: 外のパッケージが自前のウィンドウの外枠を要求したのに、`MokumeMac` の道が表に載っていないことで、開く引き金が引かれない。そのときは決定 3 の表に行を足して扱う。

### 5. 退けた割り方

[#3804](https://github.com/mokume-metal/mokume/issues/3804) は、値・形式・観測・書き出しも別のターゲットに割る案から始まった。2026-11-08 にメンテナと議論し、外枠だけを割ると決めた。

| 案 | 退けた理由 |
| --- | --- |
| 値と形式を `nonisolated` 既定のターゲットに割る | 値の層は警告の控えと値型の `draw()` で実行時に触れていて、割るには警告の仕組みを作り直す必要がある。`nonisolated` の付け忘れの実害は 0 件で、検査の所要時間が縮むかも測っていない。`nonisolated` の運用 ([ADR-0010](0010-concurrency-model.md) 決定 1 の改訂) で足りる |
| 観測と制御・書き出しを割る | iOS にも Foundation・AVFoundation・VideoToolbox があり、Core に置いたまま組める。AI 協調の機構はコアの要件である ([ADR-0016](0016-package-structure.md) 決定 5)。割ると、描画コアから上の層を呼ぶ注入の口が増える |
| 割らずに Core の中を `#if os(macOS)` で囲う | iOS の外枠を足すときも Core の中に置くことになり、macOS 専用の範囲が `#if` でしか読めない。外枠を割る手間 (逆向きの参照 3 か所) は小さい |

再開の条件: `nonisolated` の付け忘れで実害の Bug が出たとき・文書の値を並列から読む実需が出たとき・値と形式の検査を別ターゲットに割ると検査の所要時間が縮むと測れたとき。

## 影響

- `Package.swift` に `MokumeMac` と、その検査のターゲット `MokumeMacTests` がある。`make api` と参照の面のモジュールの並び (`API_MODULES`) に `MokumeMac` が加わった。公開 API の一覧は変わらない
- 外枠の検査のうち、MokumeCoreTests と共有の手伝い (`eventually`・`FakeFilePicker`・`KeyEventFixture`・`SignalState` など) に頼るもの (`SketchApplicationTests`・`SharedFrameStageTests`・`SketchViewTests` など) は、まだ MokumeCoreTests にあり、`@testable import MokumeMac` で外枠を読む。手伝いを共有の置き場へ移して検査を移すのは、別の段で行う
- `mokume new` は `MokumeMac` という名前を、ほかのターゲットと同じく断る (同じ名前のターゲットが 2 つになる)
- iOS のビルドの段 ([#3635](https://github.com/mokume-metal/mokume/issues/3635)) は、Core の中を `#if` で囲わずに組めるかを確かめる。`Display/Sharing/` (別のプロセスへの絵の受け渡し) は AppKit を使わないので Core に残したが、iOS で組めるかはそこで確かめる
