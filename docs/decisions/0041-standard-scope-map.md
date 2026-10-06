<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# ADR-0041: 本体が標準で持つ領域の地図

## 状態

採用 (2026-10-03) / 改訂 (2026-10-04): 基準 1 の下限を Processing にし、「専用の道具の仕事は作らない」基準と「連携の口」の区分を足し、Syphon を本体へ移さない理由と支え方を書いた / 改訂あり (本文の「改訂 (日付)」見出し)

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

### 改訂 (2026-10-04) — 採用した地図に足りなかったもの

採用の翌日、#1959 (地図の標準の領域を入れる親) と #1957 (カメラと音) を検討するなかで、メンテナとの議論 (2026-10-03) で次の 3 点が足りないと分かった ([#1972](https://github.com/mokume-metal/mokume/issues/1972))。

1. **下限が決まっていない。** mokume は少なくとも Processing より便利でなければならない。ところが当初の地図には、Processing が本体か公式で持つものの抜けがあった (下の表)。全画面とディスプレイの選択・TCP・SVG の読み込みは、mokume のコードにも地図にも無かった (2026-10-03 に `Sources/MokumeCore` を検索して確認)
2. **「やらない」の根拠が書けない。** TouchDesigner や MadMapper は、mokume が代わりを目指す相手ではなく、連携する相手である。この線が基準に無いと、プロジェクションマッピングや DMX を「主要な環境にあるから」で入れる議論が毎回起きる。当初の基準 1 で数えると、TouchDesigner 1 つが持つだけなので「基準 1 が弱い」としか言えなかった
3. **連携の口が区分に無い。** OSC・MIDI・Syphon は「作る」ための機能ではなく、他の道具へ渡し、他の道具から受けるための口である。当初の表では、OSC・MIDI は標準に、Syphon は外のパッケージに散っていた

Processing と並ぶために足すもの:

| Processing が持つもの | mokume の現状 (2026-10-03) | 当初の地図 |
| --- | --- | --- |
| 音の合成・エフェクト (公式の Sound) | 無い | 音の行が「入力の解析・ファイル再生」だけ |
| TCP のサーバ・クライアント (本体の `net`) | 無い | 無い |
| SVG の読み込み (本体の `loadShape`) | 無い | 文脈の表に行があるが、地図に無い |
| JSON・XML の読み込み (本体の `loadJSONObject`・`loadXML`。どちらも URL を受ける) | 無い | JSON は「薄い口」、XML・URL は無い |
| 全画面・出すディスプレイの選択 (本体の `fullScreen(display)`) | 無い | 無い |
| PDF・SVG・DXF の書き出し (本体の `pdf`・`svg`・`dxf`) | 無い | PDF・SVG は「設計が重い」、DXF は無い |

Processing 4 の本体に同梱されるライブラリは `dxf`・`io`・`net`・`pdf`・`serial`・`svg` の 6 つで ([processing4/java/libraries](https://github.com/processing/processing4/tree/main/java/libraries))、Sound と Video は Processing Foundation の公式ライブラリとして別に配られる。

## 決定

### 1. 標準にする基準は 5 つ。すべてを満たすものだけを標準にする (2026-10-04 改訂)

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

#### 当初の決定と、改訂の理由

当初の基準は 4 つで、基準 1 は「主要な環境の多くで、本体か公式が持っている」だけだった。改訂で次の 2 つを変えた。

- **基準 1 に下限を置いた。** 「多く」を数えるだけでは、Processing が本体で持つ全画面・TCP が地図から漏れ、SVG の読み込みは文脈の表に行がありながら地図に載らなかった (文脈の改訂の節の表)。物差しの 5 環境のうち Processing だけが持つものは「多く」に届かず、入れる根拠が作品の実需しか無かった。mokume が最低限並ぶべき相手を Processing と決め、Processing が持つものは数えずに満たすことにした
- **基準 5 を足した。** 当初は「やらない」を基準 1 の弱さでしか言えず、TouchDesigner が本体で持つもの (マッピング・DMX) を入れる議論が、領域ごとに起きうる形だった。他の道具の代わりを目指さないことを基準として書き、やらない理由を「その道具の仕事で、連携の口で渡せる」と言えるようにした

### 2. 地図 (2026-10-04 改訂)

区分は 2 つの軸で分ける。**mokume の仕事か、他の道具と渡し合う連携の口か**と、**本体に持つか、外のパッケージか、持たないか**である。決定 3・5 が「標準」と呼ぶのは、mokume の仕事と連携の口の両方の標準の区分 (設計が重いものを含む) である。

| 区分 | 領域 | 理由 |
|---|---|---|
| **mokume の仕事 (標準)** | カメラ | 5 環境のうち 4 つが本体に持つ (Processing は公式)。AVFoundation で書ける。形は [ADR-0042](0042-camera-and-audio-standard.md) |
| | 音 (入力の解析・ファイル再生) | 3 環境が本体、2 環境が公式。AVFAudio・Core Audio・Accelerate で書ける。形は [ADR-0042](0042-camera-and-audio-standard.md) |
| | 音の合成とエフェクト (2026-10-04 追加) | 基準 1: 最低ライン (Processing の公式 Sound が持つ)。基準 2: AVFAudio の音の流れで書ける。基準 3: 再生と同じ音の流れに入り、入力・再生と同じ解析の関数に通る。基準 4: manual rendering (オフライン) で、機材なしに同じサンプル列を確かめられる。基準 5: 範囲は Processing Sound 並み (オシレータ・ノイズ・エンベロープ・フィルタ・簡単なエフェクト) に留め、DAW にしない。形は [ADR-0042](0042-camera-and-audio-standard.md) 決定 6 |
| | 動画の読み込みと再生 | 4 環境が本体に持つ。AVFoundation で書ける。カメラと同じ「外から来た画素を `Image` にする」道を使う |
| | シリアル | Processing・openFrameworks・TouchDesigner が本体に持つ。termios と IOKit で書けて、OS の許可も要らない |
| | ゲームパッド | 本体に持つのは Unity・TouchDesigner の 2 つで、基準 1 は弱い。補うのは、展示やインタラクティブな作品で手軽な入力機器として使われることと、GameController だけで小さく書けること |
| | 3D モデルの形式 | Unity・TouchDesigner は本体で多くの形式を読み、openFrameworks は公式の addon (Assimp) で読む。mokume はいま OBJ だけ。Model I/O で USD・STL・PLY を読める |
| | 文字列・CSV の読み書き | 5 環境すべてが本体に持つ。Foundation で書ける |
| | JSON・XML の読み込みと、URL からの読み込み (2026-10-04 追加) | 基準 1: 最低ライン (Processing の本体の `loadJSONObject`・`loadXML`。どちらも URL を受ける)。基準 2: Foundation (`JSONSerialization`・`XMLParser`・`URLSession`) で書ける。基準 3: 読んだ値は本体の値として返し、面に Foundation の型を出さない ([ADR-0020](0020-api-naming-and-surface.md) 決定 6)。基準 4: ファイルは手元の標本で、URL は応答を差し替えて検査できる。基準 5: 当たらない |
| | SVG の読み込み (2026-10-04 追加) | 基準 1: 最低ライン (Processing の本体の `loadShape`)。openFrameworks は公式、TouchDesigner は本体にも持つ。基準 2: `XMLParser` で読める。基準 3: 読んだものは画素ではなく本体の図形 (パス) になり、色・変換・書き出しがそのまま効く。基準 4: 図形になるので、これまでの描画の検査で確かめられる。基準 5: 当たらない |
| | 全画面と、出すディスプレイの選択 (2026-10-04 追加) | 基準 1: 最低ライン (Processing の本体の `fullScreen(display)`)。基準 2: AppKit (`NSScreen`) で書ける。基準 3: 描く側はこれまでのフレームのまま変わらない。基準 4: ディスプレイの一覧を差し替えて、選んだ結果を検査できる。基準 5: 複数台にまたがる 1 枚の表示と、重なりのぼかしはしない (マッピングの仕事) |
| **mokume の仕事 (標準だが設計が重い)** (領域ごとの Design で決める) | ベクター書き出し (PDF・SVG・DXF) | Processing・openFrameworks が本体に持ち、ペンプロッタ・印刷の文化では定番。Metal で描く道とは別の描き先が要る。DXF (2026-10-04 追加) は Processing の本体の `dxf` で、最低ラインに入る。線を CAD やレーザーカッターへ渡す形式で、同じ描き先の問題なので同じ Design で扱う |
| | Vision (手・顔・体・人物の切り抜き) | OS のフレームワークで書け、カメラと組むと強い。[ADR-0014](0014-machine-learning-role.md) の地図の上で決める |
| | 書き出しに音声を載せる | 音を入れた後の統合の仕事 |
| **mokume の仕事 (外のパッケージ)** | 深度カメラ・Kinect・Leap | 第三者の SDK を要する (基準 2) |
| **連携の口 (標準)** | OSC の送受信 | 最低ラインに入れた (決定 1)。openFrameworks は公式、TouchDesigner は本体に持つ。TouchDesigner と繋ぐ主な経路。Network.framework と小さなパーサで書ける |
| | MIDI の入出力とクロック (2026-10-04 に入力だけから広げた) | 本体か公式に持つのは TouchDesigner だけで、基準 1 は弱い。補うのは、mokume がライブ用途を要件に持つこと ([ADR-0012](0012-view-layer.md) 決定 5) と、MIDI がライブの定番の操作卓で、DAW・TouchDesigner とテンポを揃える経路でもあること。揃えるには入力だけでなく、クロックの送受信と出力が要る。CoreMIDI で書ける |
| | TCP・UDP・WebSocket (2026-10-04 追加) | 基準 1: 最低ライン (Processing の本体の `net` が TCP のサーバとクライアントを持つ)。UDP と WebSocket は Processing では第三者のライブラリだが、同じ Network.framework の同じ口 (`NWListener`・`NWConnection`) で書け、ブラウザや他のアプリと繋ぐ経路になる。基準 2: Network.framework で書ける。基準 3: 届いたメッセージは落とさない列に入る ([ADR-0028](0028-external-inputs.md) 決定 2)。基準 4: ループバックか注入で、相手なしに検査できる。基準 5: 他の道具へ渡す口そのもの |
| **連携の口 (外のパッケージ)** | Syphon | バイナリ配布物を要する (原則 6)。`mokume-syphon` のまま置き、本体が検査で支える (決定 7) |
| | NDI・Ableton Link | NDI は第三者の SDK を要する (基準 2)。Ableton Link は GPL か個別の許諾で配られ、MIT の本体には入れられない |
| **やらない (他の道具の仕事)** (2026-10-04 追加) | プロジェクションマッピング | MadMapper などの仕事 (基準 5)。mokume は描いた絵を Syphon で渡す |
| | DMX・Art-Net・sACN | 照明卓・TouchDesigner の仕事 (基準 5)。mokume は OSC・MIDI で合図を送る |
| | Audio Unit のホスト | DAW の仕事 (基準 5)。音の合成は Processing Sound 並みに留める |
| | 画面のキャプチャ | 他のアプリの絵は、そのアプリから Syphon で受ける (基準 5) |
| **入れない** | 物理 | 本体に持つのはゲームエンジン寄りの 2 環境だけで、作り方の好みが割れる。前身のライブラリでも、物理を使う作例は仕組みの実演の 1 本だけだった |
| | GPIO・Web/DOM | macOS 専用の mokume には要らない |
| | Web ページの描画 (2026-10-04 追加) | 読み込む先のページが変われば、同じ入力から同じ絵にならない ([ADR-0001](0001-founding-principles.md) 原則 2) |
| | ノードエディタ・タイムラインの GUI (2026-10-04 追加) | mokume はコードで書く道具である ([ADR-0001](0001-founding-principles.md) 原則 1)。GUI で組む仕事はノード環境の仕事でもある (基準 5) |

ここに無い領域は、まだどの区分にも入っていない。入れたいときは決定 4 の手続きで地図に載せる。

> 破れたとき: 領域ごとに「本体か外か」「そもそも入れるか」を決め直し、決めるたびに別の基準が使われる。

#### 当初の表と、改訂で動かした行

当初の表の区分は「標準 / 標準だが設計が重い / 外のパッケージ / 入れない」の 4 つで、mokume の仕事と連携の口を分けていなかった。改訂で動かした行と理由:

| 行 | 当初 | 改訂後 | 理由 |
|---|---|---|---|
| OSC・MIDI | 標準 | 連携の口 (標準) | 作るための機能ではなく、他の道具と渡し合う口である (文脈の改訂の節の 3) |
| MIDI | 入力だけ | 入出力とクロック | 連携の口として DAW・TouchDesigner とテンポを揃えるには、入力だけでは足りない |
| Syphon・NDI | 外のパッケージ | 連携の口 (外のパッケージ) | 同上。NDI の理由は当初「バイナリ配布物」だったが、要るのは第三者の SDK なので基準 2 に直した。Ableton Link を足した |
| DMX・Art-Net | 外のパッケージ | やらない (sACN を足した) | 当初の理由は「主要な環境で本体に持つのは TouchDesigner だけ」で、外のパッケージとして作る道が残っていた。照明の制御は照明卓の仕事で、mokume は合図を送れば足りる (基準 5) |
| 文字列・CSV の行の JSON | `Codable` で足りるので薄い口 | JSON・XML・URL の行に分けた | Processing の `loadJSONObject` は型を宣言せずに読める。`Codable` は先に型の宣言が要るので、スケッチの気楽さ (原則 1) で Processing に並ばない |
| ベクター書き出し | PDF・SVG | PDF・SVG・DXF | DXF は Processing の本体が持つ (最低ライン) |

### 3. 地図の標準に載った領域は、作品の実需を待たずに入れる。口の形は作例と作品で詰める

**決めるのは、領域が本体に入るかどうかだけである。** 口の形 (名前・引数・返す型・どこまで揃えるか) は、これまでどおり作例と作品で詰める。

- 名前は Processing / p5.js に倣う ([ADR-0020](0020-api-naming-and-surface.md) 決定 1)
- 口の形を先回りで広げない。能力の宣言や新しいフックを先回りで作らない ([ADR-0024](0024-extension-seams.md) 決定 9)
- 面に出す外の型には、1 つずつ理由を書く ([ADR-0020](0020-api-naming-and-surface.md) 決定 6)

**入れる単位は、領域ごとの Issue 1 本である。** 地図に載っていることが、その Issue の動機になる。作品で踏んだ記録は要らない。

たとえばシリアルなら、「Arduino から届いた値で円を動かす」最小の作例が書けるところまでを最初の口にする。ボーレート以外の設定や、送る向きの口をどこまで持つかは、作例と作品で踏んでから足す。

> 破れたとき: 地図に載った領域で、使う先の無い口まで一度に面へ出る。公開の面なので、使われないまま消せなくなる ([ADR-0028](0028-external-inputs.md) 決定 8 が挙げていた害)。

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
| [ADR-0001](0001-founding-principles.md) 原則 6・[ADR-0026](0026-plugin-repository-alignment.md) | 変えない。別リポジトリにするのはバイナリ配布物を要する拡張だけで、外のパッケージの規約は ADR-0026 のまま |
| [ADR-0042](0042-camera-and-audio-standard.md) 決定 1・6 (2026-10-04 追加) | 変えない。カメラと音の形を決めた ADR で、決定 1 の作法 (呼べば使え、`plugins` に書かせない) が本 ADR 決定 1 の「Processing より便利」の中身になる。決定 6 の音の範囲 (解析・再生・合成まで。Audio Unit のホストはしない) は、決定 2 の表の音の行と、やらないの区分の Audio Unit の行に一致する |

### 7. Syphon は外のパッケージのまま置き、本体が検査で支える (2026-10-04 改訂で追加)

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
