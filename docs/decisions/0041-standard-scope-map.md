<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# ADR-0041: 本体が標準で持つ領域の地図

## 状態

採用 (2026-10-03) / 改訂 (2026-10-04): 基準 1 の下限を Processing にし、「専用の道具の仕事は作らない」基準と「連携の口」の区分を足し、Syphon を本体へ移さない理由と支え方を書いた / 改訂あり (本文の「改訂 (日付)」見出し)

改訂の経緯 (当初の決定・各改訂の理由・置き換わった決定) は [history/0041.md](history/0041.md) にある。本文は現行の決定を書く。

## 文脈

### 「あって然るべきもの」を入れる判断に、拠りどころが無い

メンテナは、**普通のクリエイティブコーディング環境にあって然るべきものは本体に入れる**と判断した ([#1958](https://github.com/mokume-metal/mokume/issues/1958))。最初の適用はカメラと音である ([#1957](https://github.com/mokume-metal/mokume/issues/1957))。

ところが、いまの正典はこの判断を認めていない。

| 正典 | 何と言っているか |
| --- | --- |
| [ADR-0001](0001-founding-principles.md) 原則 4 | 機能の追加は実際の作品制作で踏まれた必要によって正当化する。「想定だけの API を先回りで作らない」 |
| [ADR-0022](0022-production-track.md) 決定 6 | 実需として「一般にそういう API があるから」を認めない |
| [ADR-0028](0028-external-inputs.md) 決定 8 | 「いま作る受け口は映像だけ」。音・機材・通信・カメラは、それを要求する作品か外のパッケージが現れた日に足す |

作品の側からも、これらの領域の実需は戻ってきていない。作品のリポジトリの 14 作品 (2026-09-25 時点) に音・カメラ・シリアル・OSC・MIDI を使ったものは無く、これらを求める `Feature` も 0 件である。[#1734](https://github.com/mokume-metal/mokume/issues/1734) の合意 (2026-09-27) も、外部入力を「具体的な作品の実需で再検討する」として保留にしていた。

**原則 4 のままでは、誰もが要ると知っている領域が、作品が踏むまでいつまでも入らない。** 逆に、原則 4 を外して「あって然るべき」だけで入れると、線がどこにも引けなくなる。

### 線引きは「そのとき決める」で残っている

本体に入れるか、外のパッケージにするかは、領域ごとに先送りされてきた。

- ADR-0028 決定 8: カメラを本体に同梱するか外のパッケージにするかは「そのとき決める」
- [ADR-0014](0014-machine-learning-role.md) 決定 5: 機械学習のモジュール上の置き場は本 ADR では決めない
- [ADR-0016](0016-package-structure.md) 決定 1: 何が独立領域になるかは、実装してみるまで確定しない

別リポジトリにする根拠として書かれているのは、[ADR-0001](0001-founding-principles.md) 原則 6 の「バイナリ配布物を要する拡張だけ」の 1 つだけである。それ以外の線は無い。外のパッケージとして作られた `mokume-audio` / `mokume-camera` / `mokume-serial` / `mokume-osc` は、どれも README と LICENSE だけのまま止まっている。

### 他の環境は、どこに線を引いているか

凡例: ● 本体 / ○ 公式 (別配布か core addon) / △ コミュニティ製 / — 無い。

| 領域 | Processing | p5.js | openFrameworks | Unity | TouchDesigner |
|---|---|---|---|---|---|
| カメラ | ○ | ● | ● | ● | ● |
| 音の入力の解析・ファイル再生 | ○ | ○ | ● | ● | ● |
| 動画の読み込み・再生 | ○ | ● | ● | ● | ● |
| シリアル | ● | △ | ● | △ | ● |
| OSC | △ | — | ○ | △ | ● |
| MIDI | △ | △ | △ | △ | ● |
| ゲームパッド | △ | — | △ | ● | ● |
| 文字列・CSV・JSON の読み書き | ● | ● | ● | ● | ● |
| SVG の読み込み | ● | — | ○ | — | ● |
| ベクター書き出し (PDF・SVG) | ● | — | ● | — | — |
| 物理 | △ | △ | △ | ● | ● |
| 画面越しの映像共有 (Syphon・NDI) | △ | — | △ | △ | ● |

Processing・p5.js・openFrameworks の欄は一次資料で確かめた ([processing4/java/libraries](https://github.com/processing/processing4/tree/main/java/libraries)・[openFrameworks/addons](https://github.com/openframeworks/openFrameworks/tree/master/addons) ほか)。Unity と TouchDesigner の欄は概観の精度である。

**外に出す理由として各環境が書いているのは、主に依存の重さである。** Processing は Sound と Video を「大きくなりすぎた」として同梱から外した ([Changes in 3.0](https://github.com/processing/processing/wiki/Changes-in-3.0))。Video は GStreamer を抱えて 300MB ある。

**本体に何でも持つ側の代償も、記録に残っている。**

- OpenSiv3D は第三者のライブラリを 90 抱える。macOS 版は 2026-10 の時点でも Apple Silicon では Rosetta でしか動かず、対応の Issue は 2021 年から open のままである ([Siv3D/OpenSiv3D#681](https://github.com/Siv3D/OpenSiv3D/issues/681))
- openFrameworks では、本体のカメラの実装が新しい OS の API を使ったために、1 つ前の macOS でビルドできなくなった ([openFrameworks#8230](https://github.com/openframeworks/openFrameworks/issues/8230))。プラットフォームの固有のコードを本体に持つと、OS が変わるたびに本体が壊れうる

mokume が使えるのは OS のフレームワークで、第三者の依存も配布物も要らない。**外に出す理由の筆頭 (依存の重さ) は当てはまらない。** 当てはまるのは、OS の変化で本体が壊れうることと、公開面と保守の対象が増えることである。

### 先例は ADR-0014 にある

[ADR-0014](0014-machine-learning-role.md) は、機械学習という「あると良さそう」が最も溜まりやすい領域で、**API ではなく地図を作った**。どの機構が何を担うかの表だけを先に引き、API は作品制作で必要になった経路から実装する、と決めた。表そのものが議論の置き場になる (同 影響節)。

同じやり方を、本体が持つ領域の範囲に当てはめる。

## 決定

### 1. 標準にする基準は 5 つ。すべてを満たすものだけを標準にする

1. **少なくとも Processing と並ぶ。** 「あって然るべき」を、メンテナの印象ではなく他の環境の実物で言い換えたもの。次のどちらかに当たれば満たす
   - **最低ライン: Processing の本体と、Processing Foundation の公式ライブラリ (Sound・Video) が持つ機能、それに OSC。** macOS で意味の無いもの (GPIO の `io`) は除く。OSC は Processing では第三者のライブラリ (oscP5) だが、TouchDesigner と繋ぐ主な経路で、連携の口の要なので最低ラインに入れる
   - 主要な環境の多くで、本体か公式が持っている。文脈の表を物差しにする
2. **OS のフレームワークだけで書ける。** 第三者のパッケージ・SDK・バイナリ配布物を要らない ([ADR-0001](0001-founding-principles.md) 原則 5・6)
3. **本体の型に合流する。** 外から来た画素は `Image`、届いた出来事は入力、時刻はフレームの時刻に揃う。受け口は差込口 (`Inlet`) を通る ([ADR-0028](0028-external-inputs.md) 決定 1・5)
4. **注入の道で、機材なしに検査できる** ([ADR-0028](0028-external-inputs.md) 決定 6)
5. **専用の道具の仕事は作らない。** mokume は絵と動きを作る側である。プロジェクションマッピング・照明卓・ミキサーと DAW・ノード環境の仕事は代わりに作らず、**連携の口 (OSC・MIDI・通信・Syphon) で渡す**。範囲が専用の道具の仕事へはみ出す領域は、はみ出す手前で線を引く (音の合成は Processing Sound 並みに留め、DAW にしない — 決定 2 の表)

**Processing より便利であることの中身は、追加のインストールも `plugins` の 1 行も無く、`import mokume` だけで使えることである** ([ADR-0042](0042-camera-and-audio-standard.md) 決定 1 の作法)。Processing は Sound と Video を別に入れる必要があり、OSC は第三者のライブラリを探して入れる。

基準 1 だけでは OpenSiv3D の形になる。**基準 2 と 4 が、標準を広げる代償を抑える。** 2 は依存の重さと配布物を持ち込ませず、4 は OS の変化で壊れたときに機材の無い CI でも気付けるようにする。**基準 5 は、基準 1 の物差しに TouchDesigner のような何でも持つ環境が入っていても、他の道具の仕事まで地図に入らないようにする。**

> 破れたとき: 「どこかの環境にある」だけで領域が入り、第三者の依存と、機材を挿さないと確かめられない口が本体に積み上がる。基準 5 が破れると、マッピングや照明の制御を、専用の道具より劣る形で本体が抱え、連携すれば済んだ仕事を保守し続ける。

### 2. 地図

区分は 2 つの軸で分ける。**mokume の仕事か、他の道具と渡し合う連携の口か**と、**本体に持つか、外のパッケージか、持たないか**である。決定 3・5 が「標準」と呼ぶのは、mokume の仕事と連携の口の両方の標準の区分 (設計が重いものを含む) である。

| 区分 | 領域 | 理由 |
|---|---|---|
| **mokume の仕事 (標準)** | カメラ | 5 環境のうち 4 つが本体に持つ (Processing は公式)。AVFoundation で書ける。形は [ADR-0042](0042-camera-and-audio-standard.md) |
| | 音 (入力の解析・ファイル再生) | 3 環境が本体、2 環境が公式。AVFAudio・Core Audio・Accelerate で書ける。形は [ADR-0042](0042-camera-and-audio-standard.md) |
| | 音の合成とエフェクト (2026-10-04 追加) | 基準 1: 最低ライン (Processing の公式 Sound が持つ)。基準 2: AVFAudio の音の流れで書ける。基準 3: 再生と同じ音の流れに入り、入力・再生と同じ解析の関数に通る。基準 4: manual rendering (オフライン) で、機材なしに同じサンプル列を確かめられる。基準 5: 範囲は Processing Sound 並み (オシレータ・ノイズ・エンベロープ・フィルタ・簡単なエフェクト) に留め、DAW にしない。形は [ADR-0042](0042-camera-and-audio-standard.md) 決定 6 |
| | 書き出しの動画に音声を載せる (2026-10-23 に「標準だが設計が重い」から移した) | 基準 1 は弱い。載せた動画を書く口を、最低ライン (Processing の本体と公式の Sound・Video) は持たない。補うのは、音に反応する絵は音が付いて初めて作品になること、書き出しが固定の時計で絵の時刻を決めるので、音の時刻を絵に合わせられるのは書き出しの側だけであること。基準 2: AVFAudio の manual rendering と AVAssetWriter で書ける。基準 3: 音の流れ (再生と合成) をそのまま載せ、時刻はフレームの時刻から導く。基準 4: 機材なしで、書いた標本を読み戻して突き合わせられる。基準 5: スケッチ自身が鳴らした音だけを載せ、マイクの録音・ミキシング・書き出し後の編集はしない。形は [ADR-0042](0042-camera-and-audio-standard.md) 決定 6 の改訂 (2026-10-23) |
| | 動画の読み込みと再生 | 4 環境が本体に持つ。AVFoundation で書ける。カメラと同じ「外から来た画素を `Image` にする」道を使う |
| | シリアル | Processing・openFrameworks・TouchDesigner が本体に持つ。termios と IOKit で書けて、OS の許可も要らない |
| | Vision (手の関節点から。2026-10-23 に「標準だが設計が重い」から移した) | 基準 1 は弱い。最低ライン (Processing の本体と公式の Sound・Video) は持たない。補うのは、前身のライブラリで周辺の領域の中で作例が最も多かったこと、カメラと組むと強いこと。基準 2: OS の Vision で書ける (自前のモデルも第三者のコードも要らない)。基準 3: 結果は点の値で、入り口の最新の 1 つに入り、元のコマの時刻を持つ。人物の切り抜きを足すときは `Image` になる。基準 4: 記録した結果を注入して、機材も Vision も使わずに検査できる。基準 5: OS が持つ組み込みの要求で足りる範囲に留め、モーションキャプチャの収録・解析の道具の仕事にはしない。顔・体・人物の切り抜きは、次の作例が来てから足す。形は [ADR-0014](0014-machine-learning-role.md) の改訂 (2026-10-23) |
| | ゲームパッド | 本体に持つのは Unity・TouchDesigner の 2 つで、基準 1 は弱い。補うのは、展示やインタラクティブな作品で手軽な入力機器として使われることと、GameController だけで小さく書けること |
| | 3D モデルの形式 | Unity・TouchDesigner は本体で多くの形式を読み、openFrameworks は公式の addon (Assimp) で読む。mokume はいま OBJ だけ。Model I/O で USD・STL・PLY を読める。glb (glTF のバイナリ。2026-10-14 追加) は、骨とクリップを含めて本体の JSON の読み込みの延長で読む ([ADR-0045](0045-game-direction.md) 決定 2) |
| | 文字列・CSV の読み書き | 5 環境すべてが本体に持つ。Foundation で書ける |
| | JSON・XML の読み込みと、URL からの読み込み (2026-10-04 追加) | 基準 1: 最低ライン (Processing の本体の `loadJSONObject`・`loadXML`。どちらも URL を受ける)。基準 2: Foundation (`JSONSerialization`・`XMLParser`・`URLSession`) で書ける。基準 3: 読んだ値は本体の値として返し、面に Foundation の型を出さない ([ADR-0020](0020-api-naming-and-surface.md) 決定 6)。基準 4: ファイルは手元の標本で、URL は応答を差し替えて検査できる。基準 5: 当たらない |
| | SVG の読み込み (2026-10-04 追加) | 基準 1: 最低ライン (Processing の本体の `loadShape`)。openFrameworks は公式、TouchDesigner は本体にも持つ。基準 2: `XMLParser` で読める。基準 3: 読んだものは画素ではなく本体の図形 (パス) になり、色・変換・書き出しがそのまま効く。基準 4: 図形になるので、これまでの描画の検査で確かめられる。基準 5: 当たらない |
| | 全画面と、出すディスプレイの選択 (2026-10-04 追加) | 基準 1: 最低ライン (Processing の本体の `fullScreen(display)`)。基準 2: AppKit (`NSScreen`) で書ける。基準 3: 描く側はこれまでのフレームのまま変わらない。基準 4: ディスプレイの一覧を差し替えて、選んだ結果を検査できる。基準 5: 複数台にまたがる 1 枚の表示と、重なりのぼかしはしない (マッピングの仕事) |
| | ファイルの受け渡し (窓へのドロップ・選ばせるダイアログ。2026-10-21 追加) | 基準 1: 最低ライン (Processing の本体の `selectInput`。同じ口の `selectOutput`・`selectFolder` もここに当たる)。ドロップは openFrameworks (`dragEvent`)・Cinder (`fileDrop`)・OPENRNDR (`window.drop`)・nannou (`dropped_file`) が窓の出来事として持ち、p5.js は `drop`、Processing は第三者のライブラリである。基準 2: AppKit (`NSOpenPanel` と、ドラッグを受ける `NSDraggingDestination`) で書ける。基準 3: ドロップはフレームに属し、`Codable` な入力の出来事に乗る。受けたパスは絶対パスなので、`loadImage`・`createVideo`・`loadSound`・`loadTable` がそのまま読める。基準 4: ドロップは入力の注入の道 (`Schemas/input-request.schema.json`) で、窓も機材も無しに検査できる。選ばせるダイアログは、`NSOpenPanel` の結果を差し替える注入の道を決めてから入れる。基準 5: 当たらない。**macOS の窓 (自前の窓と道具の窓) だけと名乗る。** iOS・`SketchView` のホストからの受け方と、セキュリティスコープ付きの URL は [#2604](https://github.com/mokume-metal/mokume/issues/2604)・[#2605](https://github.com/mokume-metal/mokume/issues/2605) で決める。実装の `Feature` は、ドロップを先に、選ばせるダイアログを後の 2 本に分ける |
| | ゲーム (`MokumeGame`。2026-10-14 追加): シーン管理・アーケード物理・タイルマップ (Tiled 形式)・セーブスロット・カメラの追従・簡易 GUI (仮置き) | 基準 1 は弱い。Processing・p5.js・openFrameworks は本体にも公式にも持たず、物理を本体に持つのは Unity・TouchDesigner だけである。補うのは、想定する利用者 (授業やゲームジャムでゲームまで作りたい学生) と、ゲームも書ける方向 ([ADR-0045](0045-game-direction.md)) である。別のパッケージにせず、本体の別ターゲットをアンブレラが再公開する形にして、入口が `import mokume` の 1 つ・1 リポジトリ 1 版のまま使えるようにした (ADR-0045 決定 4)。基準 2: 自前の Swift と Foundation で書ける。アーケード物理は速度・重力・矩形や円のめり込みの解消・接地の判定までにする (Phaser の Arcade Physics に当たる)。基準 3: 本体の値型 (図形・`Vector2`) とフレームの時刻の上に載り、描画は本体の口を通る。基準 4: 純粋な計算なので、機材も GPU も無しに検査できる。物理も決定論を保つ。基準 5: エディタ・シーンの木の GUI は持たない (下の「入れない」のノードエディタの行)。剛体物理はこの行に入れない (外のパッケージの行) |
| **mokume の仕事 (標準だが設計が重い)** (領域ごとの Design で決める) | ベクター書き出し (PDF・SVG・DXF) | Processing・openFrameworks が本体に持ち、ペンプロッタ・印刷の文化では定番。Metal で描く道とは別の描き先が要る。DXF (2026-10-04 追加) は Processing の本体の `dxf` で、最低ラインに入る。線を CAD やレーザーカッターへ渡す形式で、同じ描き先の問題なので同じ Design で扱う |
| **mokume の仕事 (外のパッケージ)** | 深度カメラ・Kinect・Leap | 第三者の SDK を要する (基準 2) |
| | 剛体物理 (2026-10-14 に「入れない」から移した) | 積み重ね・関節・回転する衝突は、第三者のコード (2D は Box2D・3D は Jolt) を要する (基準 2)。作例が求めたときに外のリポジトリで包む。第三者のコードを本体で保守しない理由は、決定 7 の Syphon と同じである |
| **連携の口 (標準)** | OSC の送受信 | 最低ラインに入れた (決定 1)。openFrameworks は公式、TouchDesigner は本体に持つ。TouchDesigner と繋ぐ主な経路。Network.framework と小さなパーサで書ける |
| | MIDI の入出力とクロック (2026-10-04 に入力だけから広げた) | 本体か公式に持つのは TouchDesigner だけで、基準 1 は弱い。補うのは、mokume がライブ用途を要件に持つこと ([ADR-0012](0012-view-layer.md) 決定 5) と、MIDI がライブの定番の操作卓で、DAW・TouchDesigner とテンポを揃える経路でもあること。揃えるには入力だけでなく、クロックの送受信と出力が要る。CoreMIDI で書ける |
| | TCP・UDP・WebSocket (2026-10-04 追加) | 基準 1: 最低ライン (Processing の本体の `net` が TCP のサーバとクライアントを持つ)。UDP と WebSocket は Processing では第三者のライブラリだが、同じ Network.framework の同じ口 (`NWListener`・`NWConnection`) で書け、ブラウザや他のアプリと繋ぐ経路になる。基準 2: Network.framework で書ける。基準 3: 届いたメッセージは落とさない列に入る ([ADR-0028](0028-external-inputs.md) 決定 2)。基準 4: ループバックか注入で、相手なしに検査できる。基準 5: 他の道具へ渡す口そのもの |
| **連携の口 (外のパッケージ)** | Syphon | バイナリ配布物を要する (原則 6)。`mokume-syphon` のまま置き、本体が検査で支える (決定 7) |
| | NDI・Ableton Link | NDI は第三者の SDK を要する (基準 2)。Ableton Link は GPL か個別の許諾で配られ、MIT の本体には入れられない |
| **やらない (他の道具の仕事)** (2026-10-04 追加) | プロジェクションマッピング | MadMapper などの仕事 (基準 5)。mokume は描いた絵を Syphon で渡す |
| | DMX・Art-Net・sACN | 照明卓・TouchDesigner の仕事 (基準 5)。mokume は OSC・MIDI で合図を送る |
| | Audio Unit のホスト | DAW の仕事 (基準 5)。音の合成は Processing Sound 並みに留める |
| | 画面のキャプチャ | 他のアプリの絵は、そのアプリから Syphon で受ける (基準 5) |
| **入れない** | GPIO・Web/DOM | mokume は Apple の OS (macOS / iOS / iPadOS) の上で描く道具で、ボードの GPIO もブラウザの DOM も持たない |
| | Web ページの描画 (2026-10-04 追加) | 読み込む先のページが変われば、同じ入力から同じ絵にならない ([ADR-0001](0001-founding-principles.md) 原則 2) |
| | ノードエディタ・タイムラインの GUI (2026-10-04 追加) | mokume はコードで書く道具である ([ADR-0001](0001-founding-principles.md) 原則 1)。GUI で組む仕事はノード環境の仕事でもある (基準 5) |

ここに無い領域は、まだどの区分にも入っていない。入れたいときは決定 4 の手続きで地図に載せる。

> 破れたとき: 領域ごとに「本体か外か」「そもそも入れるか」を決め直し、決めるたびに別の基準が使われる。

空間音響は、3D の段で作例が求めたときに音の行と [ADR-0042](0042-camera-and-audio-standard.md) 決定 6 の範囲を改訂して足す ([ADR-0045](0045-game-direction.md) 決定 2)。地図の音の行はまだ動かさない。

#### 改訂 (2026-10-21) — ファイルの受け渡しの行を足す

窓へのドロップと、ファイルを選ばせるダイアログは、地図に無い領域だった。2026-10-12 の書き味レビュー ([#2409](https://github.com/mokume-metal/mokume/issues/2409)) で、文字・画像の担当と音・データの担当が同じ欠けを挙げ、写真・音のファイル・CSV を落として加工する道具型のスケッチは、パスをコードに書いて走らせ直すしかないと分かった ([#2452](https://github.com/mokume-metal/mokume/issues/2452))。決定 4 の手続きで、表に 1 行を足した。

- **区分は mokume の仕事 (標準)。** 基準 1 は最低ライン (Processing の本体の `selectInput`) で満たす。ドロップは openFrameworks・Cinder・OPENRNDR・nannou が窓の出来事として持つ
- **ドロップはフレームに属し、`Codable` な入力の出来事に乗せる。** 入力の注入の道 (`Schemas/input-request.schema.json`) で機材なしに検査でき (基準 4)、リプレイの記録 ([#2603](https://github.com/mokume-metal/mokume/issues/2603)) と入力の層の検め ([#2731](https://github.com/mokume-metal/mokume/issues/2731)) を通る。`mokume watch` では、窓を持つ道具が受けて子へ渡す ([ADR-0032](0032-window-ownership.md) 決定 4)
- **実装は `Feature` 2 本に分け、ドロップを先にする。** `selectInput` は、窓を持たない子 (`mokume watch` の下) でダイアログを出す主体と、`NSOpenPanel` の結果を差し替える注入の道を決めてから入れる
- **macOS の窓 (自前の窓と道具の窓) だけと名乗る。** iOS・`SketchView` のホストからの受け方と、セキュリティスコープ付きの URL は [#2604](https://github.com/mokume-metal/mokume/issues/2604)・[#2605](https://github.com/mokume-metal/mokume/issues/2605) で決める

退けた案: ドロップだけ入れて選ばせる口を持たない (Processing の本体の `selectInput` に届かない — 最低ラインを割る)。持たないと地図に書く (道具型のスケッチがパスの書き換えのまま残る)。

代償: 入力の出来事の種類が 1 つ増えるので、スキーマの版が変わる。自前の窓と道具の窓の 2 か所に同じ受けを書く。窓を持たない子からダイアログを誰が出すかの設計が要る (`selectInput` の Feature が決める。決定論は注入の道があれば保てる)。

この改訂の PR で、改訂の見出しが上限 (5 つ) に達していた本 ADR の経緯を [history/0041.md](history/0041.md) へ移した ([docs/decisions/AGENTS.md](AGENTS.md) の手順)。

#### 改訂 (2026-10-23) — 書き出しの動画に音声を載せる行を、標準へ移す

「標準だが設計が重い」に置いていた「書き出しに音声を載せる」を、領域ごとの Design ([#1969](https://github.com/mokume-metal/mokume/issues/1969)) で形が決まったので、標準 (mokume の仕事) へ移した。形は [ADR-0042](0042-camera-and-audio-standard.md) 決定 6 の改訂 (2026-10-23)、符号化と水準は [ADR-0025](0025-determinism-levels.md) 決定 3 の追補 (2026-10-23) にある。基準を当てた結果は表の理由の欄に書いた。同じ PR で、`AGENTS.md` の「してはならないこと」の要約も直した (決定 4)。

- **基準 1 は弱い。** 最低ライン (Processing の本体と公式の Sound・Video) には、音を載せた動画を書く口が見当たらない。補うのは、音に反応する絵は音が付いて初めて作品になること、書き出しが固定の時計で絵の時刻を決めるので、音の時刻を絵に合わせられるのは書き出しの側だけで、外の道具で後から重ねると時刻の対応が利用者の手に残ること
- **基準 5 の線は、スケッチ自身が鳴らした音だけを載せるところに引く。** マイクの録音・ミキシング・書き出し後の編集は、DAW や編集ソフトの仕事で、やらない

退けた案: 地図の外に置き、外の道具で音を重ねるよう案内する (時刻の対応が利用者に残る — 上の補いが効かない)。外のパッケージにする (音の流れは本体の型で、書き手は本体の `MovieFile` の中にあり、外からは触れない)。

代償: 本体が書き手の入力を 2 本持つ。使われなければ決定 5 で削る候補になる。

#### 改訂 (2026-10-23) — Vision の行を、標準へ移す

「標準だが設計が重い」に置いていた Vision を、領域ごとの Design ([#1968](https://github.com/mokume-metal/mokume/issues/1968)) で形が決まったので、標準 (mokume の仕事) へ移した。形は [ADR-0014](0014-machine-learning-role.md) の改訂 (2026-10-23) にある。基準を当てた結果は表の理由の欄に書いた。同じ PR で、`AGENTS.md` の「してはならないこと」の要約も直した (決定 4)。

- **範囲は手の関節点から。** 顔・体・人物の切り抜きは、同じ行の中で、次の作例が来てから足す (決定 3・[ADR-0043](0043-features-start-from-examples.md))。行を分けない
- **基準 1 は弱い。** 最低ラインの Processing の本体と公式の Sound・Video は持たない。補うのは、前身のライブラリで周辺の領域の中で作例が最も多かったことと、カメラと組むと強いこと

退けた案: 外のパッケージにする (OS の Vision だけで書け、第三者のコードを抱えない — 基準 2 を満たす)。「標準だが設計が重い」のまま置く (カメラが入り、置き場・受け方・決定論が決まって、重さの理由が無くなった)。

代償: 公開の面が増える。使われなければ決定 5 で削る候補になる。結果は OS のモデルに頼るので、OS の更新で変わりうる。

### 3. 地図の標準に載った領域は、作品の実需を待たずに入れる。口の形は作例と作品で詰める

**決めるのは、領域が本体に入るかどうかだけである。** 口の形 (名前・引数・返す型・どこまで揃えるか) は、これまでどおり作例と作品で詰める。

- 名前は Processing / p5.js に倣う ([ADR-0020](0020-api-naming-and-surface.md) 決定 1)
- 口の形を先回りで広げない。能力の宣言や新しいフックを先回りで作らない ([ADR-0024](0024-extension-seams.md) 決定 9)
- 面に出す外の型には、1 つずつ理由を書く ([ADR-0020](0020-api-naming-and-surface.md) 決定 6)

**入れる単位は、領域ごとの Issue 1 本である。** 地図に載っていることが、その Issue の動機になる。作品で踏んだ記録は要らない。

たとえばシリアルなら、「Arduino から届いた値で円を動かす」最小の作例が書けるところまでを最初の口にする。ボーレート以外の設定や、送る向きの口をどこまで持つかは、作例と作品で踏んでから足す。

> 破れたとき: 地図に載った領域で、使う先の無い口まで一度に面へ出る。公開の面なので、使われないまま消せなくなる ([ADR-0028](0028-external-inputs.md) 決定 8 が挙げていた害)。

#### 改訂 (2026-10-23) — 下限は口の単位で確かめる。対応表で選んだ下限の口は、作例を待たずに入れる ([#2472](https://github.com/mokume-metal/mokume/issues/2472))

決定 1 は下限を「Processing の本体と公式ライブラリが持つ**機能**」と書き、この決定は「決めるのは**領域**が入るかどうかだけ。口の形は作例と作品で詰める」と書く。[ADR-0043](0043-features-start-from-examples.md) 決定 2 は「作例に要らない口は作らない」と重ねた。**下限は領域の単位でしか満たされず、領域の内側の口は、最初の作例 1 本分で止まる。**

- 見送りの記録が残っている。`loadJSONArray`・`getString` など ([#2070](https://github.com/mokume-metal/mokume/issues/2070))・`saveStrings` ([#1964](https://github.com/mokume-metal/mokume/issues/1964))・Processing の `Client` ([#2018](https://github.com/mokume-metal/mokume/issues/2018))・Sound の `Pulse`・`BrownNoise`・`AllPass` ([#1980](https://github.com/mokume-metal/mokume/issues/1980))
- 2026-10-12 の書き味レビュー ([#2409](https://github.com/mokume-metal/mokume/issues/2409)) は、同じ形の欠けを 16 件挙げた (`loadFont`・`Image` の `copy`・`resize`・`save`・`Movie.speed`・3D の `line`・`point`・`bezier()`・`curve()`・`randomGaussian`・定数・`noCursor`・`filter(THRESHOLD)`・`arc` の `OPEN`・`CHORD`・`PIE` ほか)。1 件ずつは小さいが、Processing から来た人が「ある前提」で書いて詰まる
- **無い口は作品が使わないので、Issue にならない** (ADR-0043 の文脈)。地図は領域の単位でこれを解いたが、同じ構造が領域の内側に口の単位で残っていた

**2026-10-16 の棚卸し (メンテナ同席) で、案 B を採った。**

- **Processing の口との対応表を、口の単位で作る。** Processing の最低ライン (決定 1 の 1 つ目) の公開の口ごとに、mokume の口か、「入れる」「作例待ち」「持たない (理由)」を書く。表は Processing の版を名乗る
- **表で「入れる」と選んだ下限の口は、作例を待たずに入れてよい。** 作例を Issue に先に置くことは要らない ([ADR-0043](0043-features-start-from-examples.md) 決定 2 の例外)。トリアージの印は要る (同 決定 1)。口を説明する例は、公開の説明に書く
- **選ぶ基準**:
  - 「入れる」: Processing の参照が基本の口として載せていて、決定 1 の基準 2〜5 を満たす (OS のフレームワークだけで書ける・本体の型に合流する・機材なしで検査できる・専用の道具の仕事でない)
  - 「持たない (理由)」: macOS で意味が無い・基準 2〜5 を割る・mokume の別の口が同じことをする (そのときは同等の口を書く。名前だけ違う口を足さない)
  - 「作例待ち」: 下限の口だが、名前・引数の選び方が割れる。作例が来て入れる
- **範囲は最低ラインの口だけ。** 決定 1 の 2 つ目 (主要な環境の多くが持つ) で標準になった領域の口は、これまでどおり作例で足す
- **表は ADR の外に置く。** 置き場・保守の主体・Processing の版が上がったときの見直しは、表を作る `Task` が決める。地図 (決定 2) には、領域ごとの下限の口の要約だけを置く。**この改訂は表の中身を決めない**
- **一括の流入は、表で選んだ口でも防ぐ。** 入れる単位は、領域の中の近い口の束ごとの `Feature` で、1 度に数十の口を面へ出さない。公開面の規範の検査 (`make api`) は変わらず効く
- 作例を持つ欠け ([#2466](https://github.com/mokume-metal/mokume/issues/2466)・[#2468](https://github.com/mokume-metal/mokume/issues/2468)・[#2470](https://github.com/mokume-metal/mokume/issues/2470) など) は、この改訂を待たずに、それぞれの判断で進める。作例の無い欠けは、表で下限に選ばれるまで印を待つ

具体例: 変更前は、[#2449](https://github.com/mokume-metal/mokume/issues/2449) が範囲から外した `Image` の切り出し・`resized`・`mask`・画面の写しの `get()` のような下限の口は、作例が来るまで印を付けられなかった。変更後は、表でその口を「入れる」に選べば、作例なしで印を付けて入れられ、根拠に本決定を引ける。

退けた案: 表を作り、足りない口を機械的にすべて埋める (公開面が数十〜百の単位で一度に増え、ADR-0043 決定 2 とぶつかる。使われない口は消しにくい)。今のまま、作例が来た口から足す (面は増えないが、同じ形の欠けは表が無いので、見つかった分だけが起票される)。

代償: 表を保守する手間が要る (Processing の版が上がるたび)。領域ごとに口を選ぶ判断が要る。表と地図の 2 か所に下限の記述が残る (地図は要約だけにして重ねない)。

> 破れたとき: 下限が領域の単位でしか確かめられず、「Processing にある口が無い」が Issue にならずに残る。あるいは表が一括の流入の入口になり、使われない口が公開面に残る。

### 4. 区分を動かすのは本 ADR の改訂だけ。表が議論の置き場になる

領域を地図に載せる・区分を動かす・地図から外すときは、本 ADR の決定 2 の表を改訂する。改訂の PR と表の理由の欄に、決定 1 の基準を領域に当てた結果を書く (2026-10-04 の改訂で足した行が例)。

基準 1 が弱い領域を標準に置くときは、MIDI の行のように、何で補ったかを理由の欄に書く。

> 破れたとき: 地図の外で領域が入り、表が実態とずれる。表を読んでも何が標準か分からなくなる。

### 5. 標準に入れた領域でも、使われなければ削る候補になる

地図を改訂するとき、標準に入れた領域のうち、**作品でも公開の作例でも使われていないもの**は削る候補として挙げる。[ADR-0022](0022-production-track.md) 影響節の「次の作品で踏まれなかった機能は、そのとき削る候補になる」を、領域の単位に当てたものである。

削るほうに実害は求めない ([ADR-0008](0008-mechanism-needs-demonstrated-harm.md) 決定 4)。0.x の間は破壊的変更を許容しているので ([ADR-0001](0001-founding-principles.md) 原則 6)、削ることはできる。

> 破れたとき: 決定 3 で作品を待たずに入れた領域が、使われないまま保守の対象として残り続ける。原則 4 が防いでいた「使われない面」が、地図を通って入り込む。

### 6. 既存の ADR との関係

| ADR | 扱い |
| --- | --- |
| [ADR-0001](0001-founding-principles.md) 原則 4 | 改訂する。領域の範囲は本 ADR の地図が決め、口の形は引き続き実需が駆動する。原則の本文は書き換えず、改訂の節を足す |
| [ADR-0022](0022-production-track.md) 決定 6 | 一部置換する。「一般にそういう API があるから」を認めない線は、口の形については生きる。領域の範囲については本 ADR が代わる |
| [ADR-0028](0028-external-inputs.md) 決定 8 | 一部置換する。「ほかは実需が出てから」と「本体に同梱するか外のパッケージにするかは、そのとき決める」を、本 ADR の地図が代わる。決定 1〜7 と、足す日にやることの表は、地図に載った受け口を足すときの作法としてそのまま効く |
| [ADR-0008](0008-mechanism-needs-demonstrated-harm.md) 決定 1 | 変えない。「業界の標準であることは実需の証明にならない」の射程は、2026-09-27 の改訂のとおり運用の機構 (ゲート・検査・hook・ラベル・ワークフロー・スクリプト) である。製品の領域は本 ADR が扱う |
| [ADR-0001](0001-founding-principles.md) 原則 6・[ADR-0026](0026-plugin-repository-alignment.md) | 変えない。別リポジトリにするのはバイナリ配布物を要する拡張だけで、外のパッケージの規約は ADR-0026 のまま。**2026-10-14 に原則 6 を改訂した** — 第三者のコードを抱える拡張 (剛体物理) も別リポジトリに置く ([ADR-0045](0045-game-direction.md) 決定 4) |
| [ADR-0042](0042-camera-and-audio-standard.md) 決定 1・6 (2026-10-04 追加) | 変えない。カメラと音の形を決めた ADR で、決定 1 の作法 (呼べば使え、`plugins` に書かせない) が本 ADR 決定 1 の「Processing より便利」の中身になる。決定 6 の音の範囲 (解析・再生・合成まで。Audio Unit のホストはしない) は、決定 2 の表の音の行と、やらないの区分の Audio Unit の行に一致する |

### 7. Syphon は外のパッケージのまま置き、本体が検査で支える

Syphon は他のアプリと絵を渡し合う連携の口の要だが、**本体のリポジトリへは移さない。** `mokume-syphon` のまま置き、本体の側が版の追随と検査で支える。

**移す案と比べた。** 本体へ移せば、版への追随が要らなくなり (mokume-syphon の Issue 19 件のうち 8 件が本体の版への追随だった — [#1957](https://github.com/mokume-metal/mokume/issues/1957))、専用機で毎回検査できる。採らないのは、**第三者のコードを本体で保守することになる**からである。

- いまの `mokume-syphon` は、上流の Syphon-Framework を submodule で持ち、xcframework に焼いて binaryTarget で引いている。本体に移すには、ソースのまま SwiftPM のターゲットとして持つことになる
- 持つことになるのは、上流のうち OpenGL を除いた Objective-C と C で約 3,500 行 (2026-10-04 時点の上流の `.m`・`.c` で 3,507 行) である
- そのままでは SwiftPM で使えないので、手直しも本体が抱える。読み込み時に走る `+load` (`SyphonServerDirectory.m`) は、Syphon を使わないスケッチでも、読み込んだだけで共有の一覧を作り、他のアプリの通知を受け始める。読み込み時の副作用を持たない取り決め ([ADR-0024](0024-extension-seams.md) 決定 5) と衝突する。シェーダは `newDefaultLibraryWithBundle` で読むので、`swift build` が既定のライブラリを作らない SwiftPM では読み方を変える必要がある

代わりに、同梱に近い便利さを次の仕組みで取る。どれも本 ADR では足さず、それぞれの Issue が [ADR-0008](0008-mechanism-needs-demonstrated-harm.md) 決定 5 の順で形を決める。

| 取りたいもの | 置き場 |
| --- | --- |
| 本体の新しい版への追随 | [mokume-metal/mokume-syphon#30](https://github.com/mokume-metal/mokume-syphon/issues/30) (Dependabot) |
| GPU を要する検査 (送出・受け取り) | [mokume-metal/mokume-syphon#31](https://github.com/mokume-metal/mokume-syphon/issues/31)・[#1971](https://github.com/mokume-metal/mokume/issues/1971) (専用機の共用) |
| 本体の変更で Syphon が壊れたことを、本体の PR の時点で知る | [#1973](https://github.com/mokume-metal/mokume/issues/1973) (本体の下流の検査) |

上流の Syphon-Framework が SwiftPM でそのまま使えるようになれば (SemVer のタグが付き、`swift build` でシェーダが読める)、本体の別の product として上流に依存する道が開く。そのときは移す案を比べ直す。上流への提案は、まだしない。

> 破れたとき: 連携の口の要だからと本体へ移し、第三者のコードの手直しを本体の保守として抱える。逆に外に置いたまま支えなければ、本体の版が進むたびに Syphon が遅れ、使う人が本体の新しい版と組み合わせられない期間が続く ([mokume-metal/mokume-syphon#28](https://github.com/mokume-metal/mokume-syphon/issues/28) では 9 minor 遅れた)。

## 影響

- **`import mokume` の公開面と保守の対象は、これまでで最も大きく増える。** 2026-10-04 の改訂で、Processing と並ぶための領域 (音の合成・通信・SVG の読み込み・JSON と XML と URL・全画面とディスプレイの選択・DXF) がさらに加わった。OS が変わったときに本体が壊れる面も増える。抑えるのは決定 1 の基準 2 と 4 で、増えた口には [ADR-0020](0020-api-naming-and-surface.md) の規範検査 (`make api`) がそのまま効く
- **実装の順番と進み具合は Issue が持つ。** 本 ADR に進捗の台帳を複製しない。地図に載った領域ごとの Issue は、親 Issue ([#1959](https://github.com/mokume-metal/mokume/issues/1959)) の下に置く
- **やらないの区分に載った領域は、Issue が来ても「その道具の仕事で、連携の口で渡す」と答えて閉じられる。** 連携の口のほうが足りなければ、そちらを広げる Issue にする
- `mokume-audio` / `mokume-camera` / `mokume-serial` / `mokume-osc` の外のパッケージは、標準の区分に入ったので外のパッケージとしては作らない。リポジトリをどうするかは本 ADR の範囲外
- 本 ADR は検査・hook・ラベル・ワークフローを 1 つも足さない。地図に載っているかの判定は表を読めば足り、機械で見張る対象が無い ([ADR-0008](0008-mechanism-needs-demonstrated-harm.md) 決定 1)
- **地図に載っていても、作品で踏んだ記録は引き続き価値がある。** 口の形を詰める材料は作品から来る (決定 3)。作品で踏んだ欠けは、これまでどおり `Feature` で起票する ([ADR-0022](0022-production-track.md) 決定 3)
