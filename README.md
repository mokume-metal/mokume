# mokume

Creative coding for Swift + Metal.

![左にスケッチのコード、右に実行中の絵。fill の行を書き換えて保存すると橙の円が水色に、circle の大きさを書き換えて保存すると円が大きくなる](https://i.gyazo.com/bf9796f5fcfea45e426a854e6c9e11ce.webp)

mokume は、**コードを書いて絵やアニメーションを作る** ためのツールです
(このような作り方を「クリエイティブコーディング」と呼びます)。

- **Processing や p5.js に近い書き方**で、`background` で背景を塗り、`fill` で色を選び、`circle` で円を描きます。言語は Swift です
- **保存するとすぐ反映されます。** 上の動画のように、実行したままコードを書き換えて保存すると、ウィンドウを開き直さずに絵が変わります
- 2D の図形と文字、3D の立体とライティング、パーティクルと力、ピクセルの読み書き、描いた絵に重ねるエフェクトまで、**1 つのファイルから**始められます
- 描画には Mac の GPU (Metal) を使います

**Apple Silicon (M1 以降) の Mac 専用**です。Intel の Mac・Windows・Linux では動きません。

公式サイト: <https://mokume.org> ／ API リファレンス: <https://mokume.org/documentation/mokume/>

## 作例

どれもこのリポジトリの [Sketches](Sketches) にあるスケッチで描いたものです。

| | |
| --- | --- |
| <img src="https://i.gyazo.com/34337801ec22c3d5f82c6abe5b24b453.png" width="400" alt="濃い灰の背景に、橙・水色・青緑・白の小さな図形が画面いっぱいに並んだ見本"><br>図形とスタイル | <img src="https://i.gyazo.com/c4b16442441d68c13a63ae69b4db81fc.gif" width="400" alt="放射状の線が回りながら、にじみの強さが周期的に強くなったり弱くなったりする"><br>描いた絵にエフェクトを重ねる |
| <img src="https://i.gyazo.com/a1df70eb0294c3ee5aa50a930e898e1a.webp" width="400" alt="床の上に円柱・円錐・輪・箱・球が並び、視点が回るにつれて光の当たる面と影の向きが変わる"><br>3D の立体とライティング | <img src="https://i.gyazo.com/e3407232bafed2fe7f49bdfef740a29e.webp" width="400" alt="円の上を向かい合って回る 2 つの噴き口から橙の粒が出て、2 本の腕のような渦を描く"><br>パーティクルと力 |
| <img src="https://i.gyazo.com/78efcf97619760a0c8557afa54083c72.webp" width="400" alt="琥珀色の等高線の模様が流れるように形を変え、暗い窪みが移動していく"><br>GPU で計算した値を絵にする | <img src="https://i.gyazo.com/cb8df7dbe450e31edafaddf488e6c416.webp" width="400" alt="橙の六角形と緑の葉のような立体が回り、手前に小さな箱が円盤状に大量に並んで回っている"><br>大量の図形の一括描画と 3D モデルの読み込み |

## 用語

この README に出てくる言葉です。

| 用語 | 意味 |
| --- | --- |
| **スケッチ** | mokume で作る作品 1 つ分のこと。中身は Swift のパッケージ (フォルダ) です |
| **Swift** | Apple が開発したプログラミング言語。スケッチはこの言語で書きます |
| **Metal** | Mac の GPU で絵を描くための Apple の仕組み。mokume が内部で使うので、スケッチから直接触る必要はありません |
| **ビルド** | 書いたコードを、実行できるプログラムに変換すること。`mokume run` などのコマンドが自動で行います |
| **ターミナル** | 文字でコマンドを入力するアプリ。Finder の「アプリケーション」→「ユーティリティ」→「ターミナル」にあります (Spotlight で「ターミナル」と入力しても開けます)。以下の `mokume …` のコマンドはすべてここに入力します |

## 必要な環境

| 必要なもの | 確認方法・入手方法 |
| --- | --- |
| **Apple Silicon の Mac** (M1 以降) | 画面左上の  メニュー →「この Mac について」で、「チップ」が `Apple M…` になっていれば使えます。`Intel` と表示される Mac では動きません |
| **macOS 26 (Tahoe) 以降** | 同じ画面の「macOS」の欄で確認します。古い場合は「システム設定」→「一般」→「ソフトウェア・アップデート」から更新します |
| **Xcode 26 以降** | App Store からインストールし、**一度起動して**追加コンポーネントのインストールと利用規約への同意を済ませます。Swift の開発ツール一式もこれで入ります |
| **Metal Toolchain** | Xcode 26 からは Xcode とは別にインストールが必要です。Xcode の「Settings…」→「Components」で Metal Toolchain の「Get」を押します (ターミナルなら `xcodebuild -downloadComponent MetalToolchain`)。**入っていないと、最初のビルドが `unable to spawn process 'metal'` というエラーで止まります** |
| **Homebrew** | Mac 用のパッケージ管理ツール。<https://brew.sh> に書かれている 1 行をターミナルに貼り付けてインストールします |

## インストール

```bash
brew install mokume-metal/tap/mokume
```

これで `mokume` コマンドが使えるようになります。更新するときは `brew upgrade mokume` です。

<details>
<summary>Homebrew を使わずにインストールする</summary>

配布されているファイルを直接展開することもできます:

```bash
mkdir -p ~/.local/bin
curl -fsSL https://github.com/mokume-metal/mokume/releases/latest/download/mokume-macos-arm64.tar.gz | tar xz -C ~/.local/bin
```

`mokume` コマンド本体と、その実行に必要なファイル (`mokume_*.bundle`) が展開されます。**この 2 つは同じフォルダに置いたまま使ってください。** `~/.local/bin` に PATH が通っていない場合は通してください。更新するときは同じコマンドをもう一度実行します。

</details>

mokume のライブラリ本体を別にインストールする必要はありません。次の `mokume new` で作るスケッチが、必要なものを自動で取得します。

## はじめてのスケッチ

### 1. スケッチを作る

```bash
mokume new my-sketch
cd my-sketch
```

`my-sketch` というフォルダができます。はじめのうちは、**書き換えるのは 1 つのファイルだけ**です:

| ファイル | 内容 |
| --- | --- |
| **`Sources/my-sketch/MySketch.swift`** | **絵を描くコード。ここを書き換えます** |
| `Sources/my-sketch/assets/` | 画像や音などの素材を置くフォルダ |
| `Package.swift` | パッケージの設定 (mokume を使うことが書かれています)。はじめは触らなくて大丈夫です |
| `AGENTS.md` / `CLAUDE.md` / `.mcp.json` | AI エージェントと一緒に作るための設定 ([AI エージェントと一緒に使う](#ai-エージェントと一緒に使う)) |

### 2. 実行する

```bash
mokume run
```

ビルドしてからウィンドウを開き、絵を動かし始めます。**初回だけは、必要なライブラリの取得とビルドに時間がかかります** (回線と Mac によって数十秒から数分。2 回目からは数秒です)。

暗い背景の上を橙色の円が回る絵が表示されます。ターミナルには描画の速さが表示され続けます:

```
Rate: 58.7 fps (debug)
```

1 秒間に何枚描けているか (fps) と、どちらの設定 (debug / release) でビルドしたかを表しています。速さは設定によって数倍変わるので、**この数字だけで重い・軽いを判断しないでください**。

**止めるときは、ウィンドウを閉じるか、ターミナルで `Control` + `C` を押します。**

### 3. コードを読む

`MySketch.swift` を好きなエディタで開きます (Xcode でも、テキストエディットでも構いません)。中身は次のとおりです (コメントは説明のためにこの README で足したものです):

```swift
import Foundation
import mokume

@main
final class MySketch: Sketch {
    // ウィンドウの大きさとタイトル
    var settings: SketchSettings {
        SketchSettings(width: 960, height: 540, title: "my-sketch")
    }

    // 1 秒間に何十回も呼ばれ、そのたびに 1 枚の絵を描く
    func draw() {
        background(15, 18, 23)   // 背景を暗い色で塗る (赤・緑・青をそれぞれ 0〜255 で指定)
        fill(242, 115, 51)       // これから描く図形の色 (橙)
        let angle = time * 0.8   // time は実行を始めてからの秒数
        circle(width / 2 + cos(angle) * 160, height / 2 + sin(angle) * 120, 80)  // 中心の x, 中心の y, 直径
    }
}
```

`draw()` が繰り返し呼ばれ、そのたびに `time` が少しずつ進むので、円の位置がずれていき、回っているように見えます。

### 4. 書き換えて、その場で反映させる

`mokume run` で実行中なら先に止めてから、`watch` で実行し直します:

```bash
mokume watch
```

実行したまま `MySketch.swift` を開き、`fill` の行の数字を変えて保存してみてください。たとえば `fill(77, 191, 242)` にすると、**ウィンドウを開き直さなくても円が水色に変わります** (冒頭の動画と同じ操作です)。`circle` の最後の `80` を `140` にすれば、円が大きくなります。

`watch` は保存のたびにビルドし直して、実行中の絵を差し替えます。**コードに誤りがあってビルドできなかったときは、前の絵のまま動き続け、ターミナルにエラーの内容が表示されます。** 直して保存し直せば反映されます。

### 5. 次に読むもの

- **使える関数の一覧と説明**は [API リファレンス](https://mokume.org/documentation/mokume/) にあります。関数ごとに、そのまま動くコード例と実行結果の絵が付いています
- **もっと大きな例**は [Sketches](Sketches) にあります (上の作例を描いたスケッチです)

## うまく動かないとき

ウィンドウが開かない、実行したスケッチが反応しないといったときは、スケッチのフォルダで次を実行します:

```bash
mokume doctor
```

出力は 2 つに分かれています:

- **`What the environment provides`** — この Mac の状態 (macOS・機種・GPU・Swift の開発ツール)
- **`What is here`** — 今いるフォルダの状態 (スケッチ・ビルドの結果とその置き場所・最後のビルド)

これを見れば、「必要な環境がそろっていない」のか、「環境はそろっているが、手元のフォルダの状態がおかしい」のかを切り分けられます。`mokume doctor` は状態を表示するだけで、何も変更しません。判断できなかった項目には `cannot tell` と表示されます。

よくあるエラー:

- **`unable to spawn process 'metal'` でビルドが止まる** — Metal Toolchain が入っていません。[必要な環境](#必要な環境) の表のとおりにインストールしてください。`mokume doctor` を実行すると、`Shader compiler` の行に見つからない旨とインストール方法が表示されます
- **`command not found: mokume`** — mokume がインストールされていないか、PATH が通っていません。`brew install` をやり直すか、ターミナルを開き直してください

## 動画に書き出す

スケッチの動きを、一定のフレームレートの動画として書き出せます。ウィンドウは開きません:

```bash
mokume render --fps 60 --seconds 4 --out motion.mov
```

- `--fps` × `--seconds` 枚 (この例では 240 枚) を描き終えると自動で終了し、書き出し先と枚数を表示します
- スケッチの `time` は 1 枚ごとに `1 / fps` 秒ずつ進みます。そのため、**途中に重いフレームがあっても動きが乱れず、同じ指定なら毎回同じ動画になります**。スケッチのコードを書き換える必要はありません
- 書き出しにかかる時間は、ほぼ実際の再生時間と同じです (スケッチの `frameRate` の設定と `--fps` が同じ場合。240 枚なら約 4 秒)
- `--out` には `.mov` (ProRes 4444) か、連番画像のパターン (`out/frame-####.png` のように、番号が入る場所を `#` で示す) を指定します。相対パスは、コマンドを実行した場所が基準です
- `fps × seconds` が整数にならない組み合わせはエラーになります (枚数を丸めません)
- 対象のスケッチの場所や `-c`・`--scratch-path` は `mokume run` と同じように指定できます
- 途中で `Control` + `C` を押して止めても、それまでに描いた分の動画は残ります。最後まで書き出せなかったとき (途中で止めた・書き込めなかった) は、終了コードが 0 以外になります

## アプリにして配布する

作品を、ほかの Mac でもダブルクリックで開けるアプリ (`.app`) にまとめられます。

まず、作品の情報 (表示名・識別子・バージョン) を書いた `mokume-app.json` を、スケッチのフォルダの直下に置きます:

```json
{
  "name": "Grain",
  "identifier": "org.example.grain",
  "version": "0.1.0"
}
```

次に、アプリを作ります:

```bash
mokume bundle          # bundle/<表示名>.app ができる
```

**`mokume-app.json` は `mokume new` では作られません。** 無くても実行はできますが、配布するなら必ず作品ごとに書いてください。特に識別子 (`identifier`) は、macOS がカメラなどの使用許可をアプリごとに覚えるときの鍵になります。

アプリには `Package.swift` で宣言した素材 (assets) が含まれます。宣言した素材が含められなかった場合は、アプリを作る段階でエラーになります。

### 受け取った人の開き方

`mokume bundle` が保証するのは、「ほかの Mac で起動して絵が表示される」ところまでです。

標準の署名は名前の無い署名 (ad-hoc 署名) なので、**受け取った人が初めて開くときは macOS にブロックされます。** ダブルクリックだけでは開けず、ブロックされた直後に「システム設定」→「プライバシーとセキュリティ」を開き、そこに表示される「このまま開く」を押す必要があります。

この手順を省くことはできないため、開き方を書いたテキストファイルがアプリの隣に作られます。**アプリと一緒に送ってください**:

```
bundle/
  Grain.app
  Grain を開くには.txt
```

### カメラ・マイクを使う作品

カメラやマイクを使う作品では、**使用許可を求めるダイアログに表示する説明文**を `mokume-app.json` に書き足します。使う機器の分だけ、受け取る人に伝わる言葉で書いてください:

```json
{
  "name": "Grain",
  "identifier": "org.example.grain",
  "version": "0.1.0",
  "cameraUsage": "Grain は、カメラに映ったものを絵にします",
  "microphoneUsage": "Grain は、部屋の音を聞いて動きます"
}
```

`mokume bundle` は、この説明文をアプリの Info.plist (`NSCameraUsageDescription` / `NSMicrophoneUsageDescription`) に書き込みます。Developer ID で署名する場合 ([下の節](#developer-id-で署名する)) は、カメラ・マイクを使うための entitlement (`com.apple.security.device.camera` / `com.apple.security.device.audio-input`) も自動で付けます。書くのは説明文だけで大丈夫です。

**カメラを使っているのに説明文が無い場合、`mokume bundle` はアプリを作らずにエラーで止まり、書き足す 1 行を表示します。** 説明文の無いアプリは、カメラを使おうとした時点で macOS に止められてしまうためです (手元の `mokume run` ではターミナルのアプリに許可が付いているので動いてしまい、配布して初めて気付くことになります)。ただし、次の場合は検出されないので、自分で説明文を書いてください:

- 依存しているパッケージの中でカメラを使っている
- `createCapture()` を別名を通して呼んでいる

録画した映像を流す `createCapture(frames:)` はカメラに触れないので、説明文も許可も要りません。マイクについては、まだマイクを使う機能が無いため検出もしません (説明文は書けます)。

**使用許可がどこに記録されるかは、実行のしかたによって変わります:**

| 実行のしかた | 許可が記録される先 | 起きること |
| --- | --- | --- |
| アプリにせずに実行 (`mokume run` など) | スケッチを起動した**ターミナルのアプリ** | 初めて使うときに macOS が許可を求めます。同じターミナルから実行するスケッチは、1 度許可すればすべて使えます。別のターミナルのアプリを使うと、改めて求められます |
| アプリにして実行 (標準の ad-hoc 署名) | そのアプリ | 初めて使うときに macOS が許可を求めます。**アプリを作り直すたびに許可が外れ**、次の起動でまた求められます |
| アプリにして実行 (Developer ID で署名) | 署名した人と識別子 | 初めて使うときに macOS が許可を求めます。作り直しても同じアプリとして扱われます |

ad-hoc 署名のアプリは中身から識別されるので、作り直して中身が変わると、macOS からは別のアプリに見えます。制作中に何度も確認するなら `mokume run` で確かめ、アプリにするのは配布の直前の 1 回にするのがおすすめです。一度断った許可を変更するときは、「システム設定」→「プライバシーとセキュリティ」から行います。

### Developer ID で署名する

Apple の Developer ID 証明書を持っている場合は、環境変数で署名に使う名前を指定すると、**公証 (notarization) に提出できる形**でアプリを作ります (Hardened Runtime とタイムスタンプが付きます):

```bash
MOKUME_SIGN_IDENTITY="Developer ID Application: 名前 (TEAMID)" mokume bundle
```

指定しなければ ad-hoc 署名になります。どちらで署名したかは、`mokume bundle` の出力に表示されます。

**公証そのものは `mokume bundle` では行いません。** 署名しただけでは、受け取った人が開くときのブロックは無くなりません。`notarytool` で提出し、`stapler` で結果をアプリに添付するところまでを自分で行ってください。

### 配布する前の確認

アプリが手元の環境に依存していないかを確かめるには、ビルドの結果 (`.build`) を一時的に別名に移してから起動します:

```bash
mv .build .build-held && open bundle/Grain.app ; mv .build-held .build
```

## AI エージェントと一緒に使う

Claude Code などの AI エージェントから、実行中のスケッチを見たり操作したりできます。MCP サーバをつなぐと、エージェントが次のことをできるようになります:

- 実行中の絵のスクリーンショットを撮る
- ビルドの結果を読む
- マウスやキーボードの入力を送る
- 使える関数の一覧を読む

`mokume new` で作ったフォルダには `.mcp.json` が入っているので、そのフォルダで Claude Code を開き、使用を許可するか聞かれたら許可すればつながります。自分で追加する場合は次のコマンドです:

```bash
claude mcp add mokume -- mokume mcp
```

## リンク

- 公式サイト: <https://mokume.org>
- API リファレンス: <https://mokume.org/documentation/mokume/>
- 作例のスケッチ: [Sketches](Sketches)
- リリースと変更履歴: [Releases](https://github.com/mokume-metal/mokume/releases)

## mokume の開発に参加する

ここから先は、mokume そのものに手を入れたい人向けです。

- **貢献の入口**: [CONTRIBUTING.md](CONTRIBUTING.md) — Issue・PR の出し方、このリポジトリからビルドする手順 (ビルドしたコマンドは `mokume-cli` という名前になります)
- **規約**: [AGENTS.md](AGENTS.md) — 人間にも AI エージェントにも共通の作業の規約
- **設計の判断**: [docs/decisions/](docs/decisions/) — ADR (設計判断の記録)
- **ファイル形式**: [Schemas/](Schemas) — スケッチと MCP サーバがやりとりする `.mokume/` のファイルの形式 (MCP サーバを通さず、これらを直接読み書きしても同じ操作ができます)
- **脆弱性の報告**: [SECURITY.md](SECURITY.md)
