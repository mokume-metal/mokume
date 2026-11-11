<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# 利用ガイド

最初のスケッチを動かす手順は [README の「はじめる」](../README.md#はじめる) にあります。

- [インストール](#インストール) / [Homebrew を使わない場合](#homebrew-を使わない場合)
- [作例から始める](#作例から始める)
- [コマンド](#コマンド) / [動画に書き出す](#動画に書き出す) / [アプリとして配布する](#アプリとして配布する)
- [AI エージェントから操作する](#ai-エージェントから操作する) / [うまく動かないとき](#うまく動かないとき)

## 必要な環境

Apple Silicon の Mac と macOS 26 以降が必要です。

スケッチのビルドには Command Line Tools (26 以降) を使い、Xcode は要りません。Command Line Tools は [Homebrew](https://brew.sh) を入れるときに一緒に入ります。Homebrew を使わない場合は `xcode-select --install` で入れてください。

## インストール

```bash
brew install mokume-metal/tap/mokume
```

### Homebrew を使わない場合

```bash
mkdir -p ~/.local/bin
curl -fsSL https://github.com/mokume-metal/mokume/releases/latest/download/mokume-macos-arm64.tar.gz | tar xz -C ~/.local/bin
```

`mokume` と `mokume_*.bundle` は同じディレクトリに置いたまま使ってください。更新は同じコマンドの再実行です。

## 作例から始める

例を開いて始めるなら、`mokume examples` で一覧を出し、`mokume new my-shape --from triangle` のように API の名前で 1 本を選びます (括弧を含む名前はシェルでは引用符で包みます)。

使える API は [API リファレンス](https://mokume.org/documentation/mokume/) に、実行結果の絵つきでまとまっています。Processing や p5.js から来たなら、先に [Swift で 3 つだけ違うこと](https://mokume.org/documentation/mokume/#Swift-で-3-つだけ違うこと)を読むと、最初のコンパイルエラーで迷いません。

## コマンド

| コマンド | |
| --- | --- |
| `mokume new <name>` | スケッチを作成 |
| `mokume examples` | 同梱した作例の一覧 (`mokume new <name> --from <例>` で開く) |
| `mokume run` | ビルドして実行 |
| `mokume watch` | 実行し、保存のたびに再ビルドして差し替え |
| `mokume render` | ウィンドウを開かずに動画・連番画像・GIF・MP4 へ書き出し |
| `mokume bundle` | 配布用の `.app` を作成 |
| `mokume doctor` | 環境とスケッチの状態を表示 |
| `mokume mcp` | AI エージェント向けの MCP サーバを起動 |

オプションの一覧は `mokume help` で確認できます。

`mokume watch` で保存後のビルドに失敗したときは、直前の絵が動き続け、エラーがターミナルに表示されます。

`mokume watch` が監視するのは、`Package.swift`・`Sources/` の下の `.swift`・`Sources/<名前>/assets/` の下の通常のファイルです (隠しファイルとシンボリックリンクは含みません)。`.metal` のシェーダはプロセスを再起動せず、実行したまま差し替わります。**範囲の外を変えても再ビルドしません** — `Package.swift` で `assets/` 以外に宣言したリソース (`.process("Resources")`・`.copy("data.json")`・`path:` を変えた target)・`Package.resolved`・パスで指定した依存 (`--local` の mokume のチェックアウト) です。変えたときは `mokume watch` を再起動してください。

### 動画に書き出す

```bash
mokume render --fps 60 --seconds 4 --out motion.mov
```

`time` は 1 フレームごとに `1 / fps` 秒ずつ進むので、描画の重さに左右されず、同じ引数からは同じ動きが得られます。`--out` には `.mov` (ProRes 4444) か、`out/frame-####.png` のような連番を指定します。この 2 つは編集の元にする形式で、同じ引数から同じ画素が得られます。

共有用の形式として `.gif` と `.mp4` (H.264) を指定できます。外部の変換ツールは要りません。

```bash
mokume render --fps 25 --seconds 4 --out loop.gif   # 100 枚。4 秒で 1 周する作品なら継ぎ目なしのループ
```

`--scale N` (1 以上の整数) を付けると、**座標を変えずに出力の画素だけを縦横 N 倍にして**書き出します。1920×1080 で書いた作品を 4K で出すなら `--scale 2`、印刷用に 4 倍なら `--scale 4` です (作品のコードは書き換えません)。

```bash
mokume render --fps 1 --seconds 1 --scale 4 --out print-####.png   # 7680×4320 の 1 枚
```

`width` / `height` は 1920 / 1080 のまま、線の太さ・エフェクトの半径・`clip` の矩形・フラグメントシェーダが受け取る位置と大きさ・文字 (`textSize`) は座標と同じく倍率を掛けて描かれるので、構図はそのままで画素だけが増えます。実際の画素で数える `pixelWidth` / `pixelHeight` と `pixels`・`get`・`set` のインデックスは倍率を掛けた画素数 (倍率 2 なら 3840 / 2160) で、`width` を上限に画素をループする作品は倍率を掛けると絵が変わります。倍率ごとに別の絵なので (倍率 1 と 2 の画素は一致しません)、同じ倍率・同じ引数からは同じ画素が得られます。`createGraphics(w, h)` のオフスクリーンバッファも同じで、座標の大きさは `w`×`h` のまま、画素数は倍率を掛けた数 (倍率 2 の `createGraphics(1920, 1080)` は 3840×2160) になり、`image(バッファ, …)` はバッファの座標の大きさで置きます (バッファの `pixels`・`get`・`set` のインデックスも実際の画素です)。バッファから作ったバッファも倍率を引き継ぎます。バッファのメモリは倍率の 2 乗で増え、置いた後に描き換える前の内容をコピーとして最大 4 枚まで持つので、そのコピーも同じだけ増えます。**バッファにもキャンバスと同じ 16384 画素の上限があり、倍率 1 では描けた作品が、倍率 N では `setup()` (バッファを作る所) で止まることがあります** — キャンバスより大きいバッファ (たとえば `createGraphics(8192, 64)` を `--scale 3` で書き出すと 24576 画素になる) が該当します。止まるときは、倍率と、その倍率で作れる最大の大きさを示してエラーにします。シャドウマップの解像度 (`shadowDetail`) は倍率に追従しません (シャドウマップの一辺の画素数のままなので、倍率を上げても影の縁は細かくなりません)。大きなサイズでは多くのメモリが要り、`.mp4` (H.264) は大きなサイズだとエンコーダの上限に当たります (手元の Mac では 7680×4320 まで書け、8192×4608 は書き込みに失敗しました。Mac によって変わります)。大きな倍率は連番 PNG か `.mov` で書き出すことを勧めます。掛けた大きさが 16384 画素を越える組み合わせ (幅 8192 の作品の `--scale 3` など) は、最初のフレームを描く前にエラーにします。

この 2 つは配布用の形式で、**同じ引数から書き出しても画素が一致するとは保証しません** (編集の元にするなら `.mov` か連番)。書き出しの終わりにもそう表示します。GIF は 256 色で、色は sRGB に変換して書き、半透明の画素は不透明か透明かの 2 通りにします (アルファ 128 以上が不透明)。遅延は 1/100 秒の整数倍なので、`--fps` は 100 を割り切る値 (50・25・20 など) だけを受け付け、`--fps 60` はビルドの前にエラーになります。MP4 はアルファを書かず、色は sRGB に変換して書きます。H.264 は奇数の幅や高さを 1 画素削ることがあり (65×49 は 64×48 になります)、削ったときは標準エラーに書き出した大きさを表示します。

<details>
<summary>詳しい挙動</summary>

- `fps × seconds` 枚を描き終えると終了し、書き出し先と枚数を表示します。`fps × seconds` が整数にならない組み合わせはエラーになります
- 書き出しは画面のリフレッシュを待たず、描画と書き込みが許す速さで進みます。スケッチの `frameRate` にも画面のリフレッシュレートにも縛られないので、軽いスケッチは作品の長さより短い時間で書き終わります (重いスケッチは長さより長くかかります)。時刻はフレームの番号から決まるので、速さが変わっても絵は変わりません
- カメラ・マイク・URL からの読み込み・`request…` の結果が届くフレーム・`Date()` のように、実際に流れた時間で届くものを使うスケッチも書き出せますが、その部分の結果は保証しません。書き出しは全速で進むので、届くのが何枚目になるかは実行ごとに変わり、画面で実行したときとも違います
- 相対パスは実行した場所が基準です。スケッチの場所・`-c`・`--scratch-path` は `run` と同じように指定できます
- 動画 (`.mov`・`.mp4`・`.gif`) は、書いている間は書き出し先の隣の隠しファイルの一時ファイル (`.motion.mov.<番号>.tmp` のような名前) へ書き、**書き込みに失敗せずに閉じ終えたときだけ**、1 回の置き換えで書き出し先に置きます。同じ名前へ書き出し直すのは上書きですが、途中で書き出しに失敗したり、プロセスがクラッシュしたりしても、書き出し先に前からあったファイルはそのまま残ります (失敗のメッセージがそう伝えます)。クラッシュしたときの一時ファイルは、次に同じ名前へ書き出すときに削除されます。連番は 1 枚ずつ書き出し先へ書くので、この保証の外です。代償が 3 つあります: 書いている間は前のファイルと一時ファイルが並ぶので、必要なディスク容量が一時的に倍になります。書き出しの準備は開始時にするので、親のディレクトリの作成も開始時になり、1 枚も描かれないまま終わっても空のディレクトリが残ります。`.gif` は、書き込めないディレクトリにある書き込める既存ファイルを上書きできなくなりました (隣に一時ファイルを作れないため。`.mov`・`.mp4` は元からエラーにしていました)
- 連番の番号は 0 から振ります。`N` 番目のフレーム (`frameCount == N`) は番号 `N - 1` のファイルになるので、1 枚だけ欲しいときは `--seconds` を `N / fps` にして最後の 1 枚を取ります。`--fps 60 --seconds 2 --out shots/f-####.png` なら、最後の `shots/f-0119.png` が `frameCount == 120` (`time` は 1.9833…) の絵です
- 書き出しを確認してから終了コード 0 で終わり、書き出せなかったときは 0 以外で終わるので、`mokume render … --out motion.mov && open motion.mov` のようにつなぐと、書けたときだけ開けます
- `Control` + `C` で中断すると、それまでの分を閉じて書き出し先に置きます (前のファイルはその分に置き換わります)。最後まで書き出せなかったときは 0 以外で終了します

</details>

### アプリとして配布する

スケッチのディレクトリに `mokume-app.json` を置いて `mokume bundle` を実行すると、`bundle/<name>.app` ができます。

```json
{
  "name": "Grain",
  "identifier": "org.example.grain",
  "version": "0.1.0"
}
```

`Package.swift` で宣言したリソースも同梱されます。`mokume-app.json` は `mokume new` では作られません。識別子は macOS が権限の許可を記録するときのキーになるので、作品ごとに付けてください。上の例の `org.example.grain` のままだと、`mokume bundle` が警告を出します (`.app` は作ります)。`name` は `.app` と、その隣にできる開き方の説明ファイルのファイル名にもなるので、`/` は使えず、長さは 239 までです (APFS のファイル名の上限 255 から決まります)。長さは macOS がファイル名として渡す形 (UTF-16 で、文字に付いた記号を分けた形) で数えるので、アクセントや濁点の付いた文字 (é・が) と絵文字は 2、記号が 2 つ付く文字 (ệ) は 3、ハングルの音節は 2〜3、国旗は 4、ZWJ でつないだ家族の絵文字 (👨‍👩‍👧‍👦) は 11 と数えます。`/` を含めたり長さを越えたりすると、ビルドの前に止まります。

この検証は名前だけを見るので、**検証を通ってもビルドの後で止まる場合**があります。いずれも、止まったときは理由を表示して 0 以外で終わります (開き方の説明ファイルは署名の前に書くので、説明ファイルを書けなかったときに署名済みの `.app` は残りません)。

- 長さ以外の理由で APFS がファイル名にできない名前 (分解後に結合文字が 32 個以上続くもの・非文字・未割り当ての文字)
- `--out` が深く、`<name>.app` の中のパスが 1024 バイト (PATH_MAX) を越えるとき
- `--out` が exFAT や FAT32 のとき。名前を分解しない形で数えるので、240 以上と数える名前 (`が` を 120 文字など) でも作れることがあり、そのときは検証でエラーになります

すでに同じ名前の `<name>.app` があるときは、`mokume bundle` が前に作ったものだけを作り直します。mokume が作ったと確かめられないもの (無関係なフォルダやファイル、別のアプリ) は、ビルドの前に何も消さずに止まるので、要らなければ手で消してください。開き方の説明ファイル `How to open <name>.txt` も同じで、先頭の行が `How to open <name>` のファイルを、前回 mokume が書いたものとみなして上書きします (先頭の行を残して書き足したファイルも上書きされます)。先頭の行が違うファイルや、シンボリックリンクがそこにあれば、ビルドの前に何も書かずに止まります。

標準では ad-hoc 署名のため、受け取った人が初めて開くときは macOS にブロックされ、「システム設定」→「プライバシーとセキュリティ」の「このまま開く」から開く必要があります。その手順を書いた `How to open <name>.txt` が `.app` の隣にできるので、一緒に渡してください。

<details>
<summary>カメラ・マイクを使う場合</summary>

許可を求めるダイアログに出す説明文を `mokume-app.json` に書きます:

```json
{
  "name": "Grain",
  "identifier": "org.example.grain",
  "version": "0.1.0",
  "cameraUsage": "Grain は、カメラに映ったものを絵にします",
  "microphoneUsage": "Grain は、部屋の音を聞いて動きます"
}
```

説明文は Info.plist (`NSCameraUsageDescription` / `NSMicrophoneUsageDescription`) に入り、Developer ID で署名するときは対応する entitlement (`com.apple.security.device.camera` / `com.apple.security.device.audio-input`) も付きます。

`Sources/` で `createCapture()` を呼んでいるのに `cameraUsage` が無いと、`mokume bundle` は追加すべき 1 行を示して止まります (説明文の無いアプリは、カメラに触れた時点で macOS に止められるため)。依存パッケージの中や別名を通した呼び出しは検出しないので、その場合は自分で書いてください。`createCapture(frames:)` はカメラを使わないので不要です。マイクも同じで、`createAudioIn()` を呼んでいるのに `microphoneUsage` が無いと止まります。`createAudioIn(file:)` と `createAudioIn(samples:sampleRate:)` はマイクを使わないので不要です。

許可が記録される先は実行のしかたで変わります:

| 実行のしかた | 許可の記録先 | 備考 |
| --- | --- | --- |
| `mokume run` など | 起動したターミナルのアプリ | 同じターミナルから実行するスケッチは 1 度の許可で済みます |
| `.app` (ad-hoc 署名) | その `.app` | 中身で識別されるため、作り直すたびに許可が外れます |
| `.app` (Developer ID 署名) | 署名者と識別子 | 作り直しても同じアプリとして扱われます |

制作中の確認は `mokume run` で行い、`.app` は配布の直前に作るのがおすすめです。

</details>

<details>
<summary>ネットワークで送る場合</summary>

OSC (`createOSC`) や UDP (`createUDP`) で同じネットワークの別のマシンへ送る作品は、`mokume bundle` で作った `.app` ではローカルネットワークの許可が要ります。初めて送ったときに macOS がダイアログを出し、許可するまで (許可しなかったときはその後も) 送ったものは届きません。受信は許可が無くても届きます。`mokume run` で動かしている間は、起動したターミナルのアプリの許可で送れます。

ダイアログに出す説明文は `mokume-app.json` の `localNetworkUsage` に書きます:

```json
{
  "name": "Grain",
  "identifier": "org.example.grain",
  "version": "0.1.0",
  "localNetworkUsage": "Grain は、同じネットワークの TouchDesigner にメッセージを送ります"
}
```

説明文は Info.plist の `NSLocalNetworkUsageDescription` に入ります。書かなくてもダイアログは出て、`mokume bundle` も止まりません (カメラ・マイクと違います)。entitlement は付きません。

送信がブロックされているとき、送信側の `state` は `running` のままで、診断メッセージとして次の 1 行が 1 度だけ出ます (`Network is down` は Wi-Fi が切れているときにも出ます):

```
mokume: Could not send to 192.168.11.15:7000 (Network is down). If the network is up, this app may not be allowed to reach the local network: check System Settings > Privacy & Security > Local Network. It keeps waiting for the connection
```

許可の状態は「システム設定」→「プライバシーとセキュリティ」→「ローカルネットワーク」で見られ、そこでオンにすれば送れるようになります。一覧の行には `.app` の名前ではなく、中の実行ファイルの名前 (スケッチのターゲットの名前) が出ます。識別子だけを変えた `.app` は、同じ実行ファイルが許可済みでも許可を引き継がず、ダイアログも出ないままブロックされることがあります。

</details>

<details>
<summary>Developer ID で署名する</summary>

```bash
MOKUME_SIGN_IDENTITY="Developer ID Application: 名前 (TEAMID)" mokume bundle
```

Hardened Runtime とタイムスタンプ付きで署名し、公証に提出できる形になります。公証 (`notarytool` での提出と `stapler` での添付) は `mokume bundle` の外で行ってください。どちらの署名を使ったかは出力に表示されます。

配布前に、手元のビルド結果に依存していないかは次で確かめられます。描けたらアプリを閉じてください (閉じると `.build` が戻ります。Ctrl-C で止めても戻ります):

```bash
( build=.build; held=$(mktemp -d .build-held.XXXXXX) || exit; mv "$build" "$held/.build" || { rmdir "$held"; exit 1; }; trap 'mv "$held/.build" "$build" && rmdir "$held"' EXIT; trap exit HUP INT TERM; open -n -W bundle/Grain.app )
```

</details>

### AI エージェントから操作する

`mokume mcp` は、実行中のスケッチのスクリーンショット・ビルド結果・マウスとキーボードの入力・API の一覧を AI エージェントに提供する MCP サーバです。`mokume new` で作ったディレクトリには `.mcp.json` が含まれているので、Claude Code ならそのまま使えます。手動で追加する場合:

```bash
claude mcp add mokume -- mokume mcp
```

場所を渡さない MCP サーバは、起動された場所 (Claude Code ならそれを起動した場所) で動き、`MOKUME_WORK_DIR` が無ければその場所の `.mokume/` を見ます。スケッチのディレクトリで起動するか、`mokume mcp <スケッチのディレクトリ>` と場所を渡して登録してください。スケッチでない場所で起動した MCP サーバは、実行中のスケッチと接続しません (スケッチが応答しないときの返答にそう表示されます)。MCP サーバは接続した時点のハンドシェイク (`initialize`) の `instructions` でも、起動した場所とそこがスケッチかどうかを返すので、`instructions` を読むクライアントなら、最初の操作の前にスケッチでない場所で起動していることに気付けます。

### うまく動かないとき

スケッチのディレクトリで `mokume doctor` を実行すると、環境 (`What the environment provides`) とスケッチの状態 (`What is here`) が表示されます。何も変更しないので、問題の切り分けに気軽に使えます。

`draw()` の途中で止めて変数を見たいときは、`mokume run -c debug` で起動して `lldb` をアタッチします。手順は [止めて変数を見る](https://mokume.org/documentation/mokume/#止めて変数を見る) にあります。
