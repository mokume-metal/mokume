<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# 連携: net・serial・OSC と io

Processing の公式ライブラリ `processing.net` (22 件)・`processing.serial` (17 件)・`processing.io` (36 件) のリファレンスと、第三者のライブラリ oscP5 の主なクラス (90 件) の 165 件。表の形式・バージョン・数え直す式は [README](README.md) にある。照合したのは processing-website `f4acef8` (2026-10-29) と mokume の main `5b60ed75` (2026-11-24)。oscP5 のリファレンスは processing-website に無いので、oscP5 の公式ページ (sojamo.de) の Javadoc を数えた (数え方は README の「数え直す式」)。

| 区分 | 件数 |
| --- | --- |
| 同等 | 18 |
| 入れる | 0 |
| 作例待ち | 22 |
| 持たない | 125 |
| 計 | 165 |

この領域に共通すること:

- **届いたものは、イベントでなく、フレームごとに読む列で受ける** ([ADR-0010](../decisions/0010-concurrency-model.md) 決定 5・[ADR-0028](../decisions/0028-external-inputs.md))。`draw()` の前に、前のフレームの後に届いた行・メッセージが全部、届いた順に `messages`・`lines` へ入っている (取りこぼさない列)。`clientEvent()`・`serialEvent()`・`oscEvent()` のコールバックと、`available()` で量を見て `read()` で引き出す形は持たない。状態は `state` で読む (`running`・`unavailable`・`disconnected`・`stopped`)
- **TCP・UDP・WebSocket は文字列で渡し合う** ([#2018])。TCP は改行で区切った 1 行、WebSocket と UDP は 1 通が 1 つのメッセージ。UTF-8 として読めないものは破棄する。**バイト列で受ける形は無い**
- **シリアルは行で受ける** ([#1961])。8 ビット・パリティなし・ストップビット 1 で開き、変えられるのはボーレートだけ。他のアプリが開いている間は開けない
- **OSC は UDP で受け、送る** ([#1962])。引数は `Int`・`Float`・`Double`・`String`・`Bool` と `OSCValue` (blob・64 ビットの整数・空・インパルスも持つ)。バンドルは受けると中を開いて並んだ順に渡し、バンドルの時刻は見ない
- **接続を作る API は `createTCPClient(_:_:)` ほか、`setup()`・`draw()`・入力のコールバックの中で呼ぶ。** 開く前に引数を確かめて投げ、繋がらなくても作れる (繋がるまで `state` が `unavailable`)
- **`io` は持たない。** GPIO はボードのピンで、ADR-0041 決定 2 が「入れない」と決めている

## 通信 (`processing.net`)

22 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `Client`・`Server` (2 件) | `TCPClient`・`TCPServer` (`createTCPClient(_:_:)`・`createTCPServer(_:)`) | 同等 | TCP の相手に繋ぐ側と、受ける側。どちらも `import mokume` だけで使える。WebSocket (`createWebSocketClient(_:)`・`createWebSocketServer(_:)`)・UDP (`createUDP(listen:send:)`) は同じ形で足されている。機材なしで確かめるときは、記録した文字列を `createTCPClient(messages:)` で流す | [#2018] |
| `Client.write()`・`Server.write()` (2 件) | `TCPClient.write(_:)`・`TCPServer.write(_:)` | 同等 | 文字列を書く。TCP はストリームなので書いたバイト列をそのまま流し、行の区切り (`"\n"`) は書く側が付ける (Processing と同じ)。`TCPServer.write(_:)` は繋いでいる相手全員へ。**無い形: `int`・`byte`・`byte[]` を書く形** (文字列だけ) | [#2018] |
| `Client.active()`・`Server.active()` (2 件) | `TCPClient.state`・`TCPServer.state` (`SourceState`) | 同等 | 動いているかを返す。真偽でなく `running`・`unavailable` (開く途中か、他のアプリが使っている)・`disconnected` (繋がっていたが切れた。開き直し続ける)・`stopped` を返し、理由が読める。サーバは繋いでいる数が `clientCount` | [#2018] |
| `Client.stop()`・`Server.stop()` (2 件) | `TCPClient.stop()`・`TCPServer.stop()` | 同等 | 止める。止めたものは追加し直しても止まったまま (止めたのは利用者の意思)。受けるなら新しく作る | [#2018] |
| `Client.available()`・`read()`・`readChar()`・`readString()`・`readStringUntil()`・`clear()` (6 件) | `TCPClient.messages` | 持たない | 届いた行は、`draw()` の前に全部、届いた順に `messages` へ入っている (`[String]`)。量を見て引き出す形は持たない。区切りまでの読み出し (`readStringUntil('\n')`) は、行の区切りで `messages` が分けている。消す (`clear()`) 必要も無く、フレームごとに入れ替わる | [#2018]・ADR-0010 |
| `Client.readBytes()`・`readBytesUntil()` (2 件) | — | 作例待ち | バイト列で受ける API。**mokume の受け口は UTF-8 の文字列だけで、読めないものは破棄する** (推測して読むと、通知なしに別の文字列を渡すため)。バイト列を渡す形 (`[UInt8]` を入れる列を別に持つか、`messages` に混ぜるか) は、バイナリのプロトコルを受ける作例が来てから決める | — |
| `Client.ip()` | — | 持たない | 繋いだ相手の IP アドレスを返す API。繋ぐ先は `createTCPClient(_:_:)` に渡したホストで、ホスト名を解いた先は見せない。サーバ側で来た相手を見分ける形は下の `Server.available()` | — |
| `Server.available()` | `TCPServer.messages` | 持たない | 受けた相手 (`Client`) を返す API。mokume のサーバは、繋いでいる全員から届いた行を、届いた順に 1 つの `messages` へ入れ、相手を見分けない (`clientCount` だけ読める)。相手ごとに返す形は、次の `Server.disconnect()` と同じ根 | [#2018] |
| `Server.disconnect()` | — | 作例待ち | 相手を指して切る API。**相手を指す型が無い**ので、`Client` に当たるもの (相手の識別子・相手ごとの列) を持つかが分かれる。#2018 は「どこまで送る向き・接続の管理の口を持つかは作例で詰める」と決めた。相手を区別する作例 (複数のクライアントへ別々に返す) が来てから決める | [#2018] |
| `clientEvent()`・`serverEvent()`・`disconnectEvent()` (3 件) | `TCPClient.messages`・`TCPServer.messages`・`state` | 持たない | 新しい行・新しい接続・切断のコールバック。届いたものは `messages` を `draw()` で読み、切断は `state` が `disconnected` になる。コールバックは足さない | [#2018]・ADR-0010 |

## シリアル (`processing.serial`)

17 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `Serial` (クラスのページ) | `Serial` (`createSerial(_:baudRate:)`) | 同等 | シリアルポートから行を受ける入力ソース。`new Serial(this, name, 9600)` に当たる。呼んだときだけポートを開き、繋がっていなくても作れる (`state` が `unavailable`、繋がれば受け始める)。ボーレートは 1 以上。機材なしの確認は `createSerial(lines:)` で記録した行を流す | [#1961] |
| `Serial.list()` | `serialPorts()` | 同等 | 使えるポートの一覧 (`[SerialPort]`)。`SerialPort` は `id`・`name` を持ち、文字列でなく値で選ぶ (識別子で繋ぎ直せる) | [#1961] |
| `Serial.stop()` | `Serial.stop()` | 同等 | ポートを閉じる。開いている間は他のアプリ (Arduino IDE の書き込みなど) が開けない | [#1961] |
| `Serial.available()`・`buffer()`・`bufferUntil()`・`clear()`・`last()`・`lastChar()`・`read()`・`readChar()`・`readString()`・`readStringUntil()`・`serialEvent()` (11 件) | `Serial.lines` | 持たない | 届いた行は、`draw()` の前に全部、届いた順に `lines` へ入っている (`[String]`)。バイト数を見て引き出す形・区切りを決めて溜める `bufferUntil()`・`serialEvent()` のコールバックは持たない (行の区切りは `Serial` が持つ)。最新の 1 行だけが要るなら `lines.last` | [#1961]・ADR-0010 |
| `Serial.readBytes()`・`readBytesUntil()` (2 件) | — | 作例待ち | バイト列で受ける API。mokume は行 (文字列) だけで受け、バイナリのプロトコルを受ける形は無い。通信 (`Client.readBytes()`) と同じ根で、作例が来てから決める | — |
| `Serial.write()` | — | 作例待ち | ポートへ書く API。**説明文が「送る向き (Processing の `write`) は持たない」と書いている。** #1961 は「送る向き・ボーレート以外の設定は作例に要る分だけにする」と決めたので、Arduino へ値を返す作例 (LED を点ける・モーターを回す) が来てから、文字列・バイト列・`Int` のどれを書くかを決める | [#1961] |

## 入出力ピン (`processing.io`)

36 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `GPIO`・`I2C`・`LED`・`PWM`・`SPI`・`SoftwareServo` のクラスのページ 6 件とメソッド 30 件 (GPIO 9・I2C 6・LED 3・PWM 4・SPI 4・SoftwareServo 4) (36 件) | — | 持たない | Raspberry Pi などのボードの入出力ピンを扱うライブラリ。**mokume は Apple の OS (macOS / iOS / iPadOS) の上で描く道具で、ボードの GPIO を持たない** ([ADR-0041](../decisions/0041-standard-scope-map.md) 決定 2 の「入れない」・決定 1 の最低ライン「macOS で意味の無いもの (GPIO の `io`)」を除く)。ピンの先の機材とやりとりするなら、シリアル (`createSerial(_:baudRate:)`) か OSC・TCP で渡す | [ADR-0041](../decisions/0041-standard-scope-map.md) |

## OSC (oscP5)

90 件。oscP5 は Processing の第三者のライブラリで、公式のリファレンスは Processing の本体のリファレンスに無い (数え方は README)。数えたのは、スケッチが直に呼ぶ 7 つのクラス (`OscP5`・`OscMessage`・`OscBundle`・`NetAddress`・`NetAddressList`・`OscProperties`・`OscEventListener`) で、内部の通信のクラス (`AbstractTcpClient`・`UdpServer`・`OscPacket` ほか) は数えない。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `OscP5` (クラスのページ。コンストラクタを含む) | `OSCPort` (`createOSC(listen:send:)`・`createOSC(send:)`・`createOSC(messages:)`) | 同等 | OSC を受けて送る入力ソース。受けるポートと、送り先 (省けば送らない) を渡して作る。送るだけなら `createOSC(send:)` が受けるポートを開かない。**無い形: スケッチの `this` を渡して受信のメソッドを呼ばせる形・`OscProperties` を渡す形・TCP とマルチキャスト** | [#1962] |
| `OscP5.send()` | `OSCPort.send(_:_:)` | 同等 | アドレスと引数 (`Int`・`Float`・`Double`・`String`・`Bool`・`OSCValue`) を、作るときに決めた送り先へ 1 つ送る。投げず、送れないときは理由ごとに 1 度だけ警告する。**無い形: 送るたびに宛先を渡す形 (`send(message, address)`)・宛先の一覧へ送る形・バンドルを送る形** | [#1962] |
| `OscP5.stop()` | `OSCPort.stop()` | 同等 | ポートを閉じる。止めたものは追加し直しても止まったまま | [#1962] |
| `OscP5.dispose()` | `OSCPort.stop()` | 持たない | スケッチの終了時にライブラリが呼ぶ後片付け。mokume はスケッチの終了時にポートを閉じるので、利用者は呼ばない | [#1962] |
| `OscP5.addListener()`・`removeListener()`・`listeners()`・`plug()`・`process()`・`flush()` (6 件) | `OSCPort.messages`・`latest(_:)` | 持たない | 受信のコールバック (`oscEvent`・`plug`) を登録する API。届いたメッセージは `messages` に全部、届いた順に入り、アドレスごとの最新は `latest(_:)` で引く。`plug()` のアドレスごとのメソッド呼び出しは、`message.address` を `switch` で分けて書く。`process()`・`flush()` は内部の取り込みと送出で、`send(_:_:)` を使う | [#1962]・ADR-0010 |
| `OscP5.connect()`・`disconnect()`・`remove()`・`tcpClient()`・`tcpServer()` (5 件) | — | 作例待ち | TCP の OSC (相手へ繋いで送る・受ける) の API。**mokume の OSC は UDP だけ** (#1962 の範囲)。TCP の OSC や相手を選ぶ接続の管理を持つなら、通信 (`TCPServer`) との重なりと相手を指す型が要る。名前と形は、TCP で OSC を送る作例が来てから決める。リファレンスだけでは `connect()` の使い方を読み取れなかった (未確認) | — |
| `OscP5.ip()`・`netInfo()`・`status()`・`version()`・`properties()`・`isBroadcast()`・`setTimeToLive()`・`setLogStatus()` (8 件) | `OSCPort.state`・`port`・`report` | 持たない | 自分の IP・通信の情報・状態・版・設定・ブロードキャストかどうか・マルチキャストの TTL・ログの水準。状態は `state`・`report` で読み、診断は `observe` に出る。設定は作るときの引数で決め、後から変える API は無い。ブロードキャストとマルチキャストは持たない | [#1962] |
| `OscMessage` (クラスのページ。コンストラクタを含む) | `OSCMessage` | 同等 | アドレスと引数の並びを持つ値型。`OSCMessage("/layer", 2, 0.5, "fade")` で作る。受け取った側は `messages` の要素として読む | [#1962] |
| `OscMessage.addrPattern()`・`arguments()`・`get()` (3 件) | `OSCMessage.address`・`arguments`・`float(_:)`・`int(_:)`・`string(_:)` | 同等 | アドレス・引数の並び・引数 1 つの取り出し。`get(0).floatValue()` は `float(0)` で、型が合わなければ `nil` (Processing は 0 を返す) | [#1962] |
| `OscMessage.add()`・`addArguments()`・`clear()`・`clearArguments()`・`set()`・`setAddrPattern()`・`setArguments()`・`makeBlob()` (8 件) | `OSCMessage(_:_:)`・`OSCValue.blob(_:)` | 持たない | メッセージを組み立てて書き換える API。`OSCMessage` は値型で、アドレスと引数は作るときに渡す (`let address`・`let arguments`)。`makeBlob()` は `OSCValue.blob([UInt8])` | [#1962] |
| `OscMessage.print()`・`printData()`・`toString()` (3 件) | `print(message)` | 持たない | 内容を標準出力へ書く。`OSCMessage` は `Equatable` な値で、`print`・`dump` で読める | — |
| `OscMessage.typetag()`・`getTypetagAsBytes()`・`getAddrPatternAsBytes()`・`getBytes()`・`addrInt()`・`checkAddrPattern()`・`checkTypetag()`・`isPlugged()` (8 件) | `OSCValue` の case・`message.address` | 持たない | 型タグの文字列・パケットのバイト列・アドレスの整数への変換・一致の確認・`plug` したかどうか。引数の型は `OSCValue` の case で分かり、パケットへの変換 (`OSCCodec`) は内部にある。アドレスの一致は `message.address == "/a"` で書く (ワイルドカードの一致は受け付けない) | — |
| `OscMessage.timetag()` | — | 作例待ち | メッセージの時刻。**バンドルの時刻は見ない** (受けるときに捨てる)。時刻つきで送る・時刻を読むかは、下のバンドルと同じ根で、作例が来てから決める | — |
| `OscBundle` (クラスのページ。コンストラクタを含む)・`OscBundle.add()`・`clear()`・`getBytes()`・`getMessage()`・`now()`・`remove()`・`setTimetag()`・`size()`・`timetag()` (10 件) | — | 作例待ち | 複数のメッセージを 1 つのパケットにまとめ、時刻をつける API。**受けたバンドルは中を開いて並んだ順に渡し (バンドルの時刻は見ない)、送るバンドルは作れない。** 束を送る形が分かれる: 複数のメッセージを 1 つの `send` でまとめる口・時刻つきの束を表す型・`createOSC(send:)` の送り先ごとの束。まとめて送る必要のある相手 (TouchDesigner・Max) の作例が来てから決める | [#1962] |
| `NetAddress` (クラスのページ)・`NetAddress.address()`・`inetaddress()`・`isvalid()`・`port()`・`toString()` (6 件) | `(host: String, port: Int)` | 持たない | 送り先のホストとポート。mokume は `createOSC(send: (host:, port:))` のタプルで渡し、数・空のホストは作るときに断る (`OSCFailure.invalidPort`・`invalidHost`) | [#1962] |
| `NetAddressList` (クラスのページ)・`NetAddressList.add()`・`contains()`・`get()`・`list()`・`remove()`・`set()`・`size()` (8 件) | `[OSCPort]` (送り先ごとに `createOSC(send:)`) | 持たない | 複数の送り先の一覧。mokume は 1 つの `OSCPort` が送り先を 1 つ持つので、送り先ごとに作って配列に持つ (`for port in ports { port.send(…) }`) | [#1962] |
| `OscProperties` (クラスのページ。コンストラクタを含む)・`OscProperties.datagramSize()`・`eventMethod()`・`listeners()`・`listeningPort()`・`networkProtocol()`・`remoteAddress()`・`sendStatus()`・`setDatagramSize()`・`setEventMethod()`・`setListeningPort()`・`setNetworkProtocol()`・`setRemoteAddress()`・`setSRSP()`・`srsp()`・`toString()` (16 件) | `createOSC(listen:send:)` の引数 | 持たない | 受けるポート・送り先・パケットの大きさ・受信のメソッド名・通信の方式 (UDP・TCP・マルチキャスト) を束ねた設定。受けるポートと送り先は作るときの引数 (`listen`・`send`) で、パケットは 9212 バイトまで (読み書きできる大きさは決まっている)、受信はコールバックでなく `messages`、方式は UDP だけ | [#1962] |
| `OscEventListener` (クラスのページ)・`oscEvent()`・`oscStatus()` (3 件) | `OSCPort.messages`・`state` | 持たない | 受信と状態の変化のコールバックのインターフェース。受信は `messages`、状態は `state` を `draw()` で読む | [#1962]・ADR-0010 |

## 入れる

この領域に「入れる」の行は無い。Feature は起票していない。

[#1961]: https://github.com/mokume-metal/mokume/issues/1961
[#1962]: https://github.com/mokume-metal/mokume/issues/1962
[#2018]: https://github.com/mokume-metal/mokume/issues/2018
