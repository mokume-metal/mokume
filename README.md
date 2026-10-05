# mokume

Creative coding for Swift + Metal.

[公式サイト](https://mokume.org) · [API リファレンス](https://mokume.org/documentation/mokume/) · [作例](Sketches) · [リリース](https://github.com/mokume-metal/mokume/releases)

![左にスケッチのコード、右に実行中の絵。fill の行を書き換えて保存すると橙の円が水色に、circle の大きさを書き換えて保存すると円が大きくなる](https://i.gyazo.com/bf9796f5fcfea45e426a854e6c9e11ce.webp)

mokume は、Processing や p5.js の書き方で絵と動きをつくる、Swift と Metal のためのクリエイティブコーディング環境です。

- **ライブリロード** — 実行したままコードを保存すると、その場で絵が差し替わります
- **なじみのある API** — `background` / `fill` / `circle` から、3D とライティング、パーティクル、ピクセル操作、ポストエフェクトまで、1 つのファイルで始められます
- **Metal ネイティブ** — Apple Silicon の GPU で直接描画します

## 作例

| | |
| --- | --- |
| <img src="https://i.gyazo.com/34337801ec22c3d5f82c6abe5b24b453.png" width="400" alt="濃い灰の背景に、橙・水色・青緑・白の小さな図形が画面いっぱいに並んだ見本"><br>図形とスタイル | <img src="https://i.gyazo.com/c4b16442441d68c13a63ae69b4db81fc.gif" width="400" alt="放射状の線が回りながら、にじみの強さが周期的に強くなったり弱くなったりする"><br>ポストエフェクト |
| <img src="https://i.gyazo.com/a1df70eb0294c3ee5aa50a930e898e1a.webp" width="400" alt="床の上に円柱・円錐・輪・箱・球が並び、視点が回るにつれて光の当たる面と影の向きが変わる"><br>3D とライティング | <img src="https://i.gyazo.com/e3407232bafed2fe7f49bdfef740a29e.webp" width="400" alt="円の上を向かい合って回る 2 つの噴き口から橙の粒が出て、2 本の腕のような渦を描く"><br>パーティクルと力 |
| <img src="https://i.gyazo.com/78efcf97619760a0c8557afa54083c72.webp" width="400" alt="琥珀色の等高線の模様が流れるように形を変え、暗い窪みが移動していく"><br>GPU で計算した場 | <img src="https://i.gyazo.com/cb8df7dbe450e31edafaddf488e6c416.webp" width="400" alt="橙の六角形と緑の葉のような立体が回り、手前に小さな箱が円盤状に大量に並んで回っている"><br>インスタンシングと 3D モデル |

ソースはすべて [Sketches](Sketches) にあります。

## 必要な環境

Apple Silicon の Mac、macOS 26 以降、Xcode 26 以降と [Homebrew](https://brew.sh) が必要です。

Xcode 26 では Metal Toolchain を別にインストールします (Xcode の Settings → Components、または `xcodebuild -downloadComponent MetalToolchain`)。入っていないと、ビルドが `unable to spawn process 'metal'` で失敗します。

## インストール

```bash
brew install mokume-metal/tap/mokume
```

<details>
<summary>Homebrew を使わない場合</summary>

```bash
mkdir -p ~/.local/bin
curl -fsSL https://github.com/mokume-metal/mokume/releases/latest/download/mokume-macos-arm64.tar.gz | tar xz -C ~/.local/bin
```

`mokume` と `mokume_*.bundle` は同じディレクトリに置いたまま使ってください。更新は同じコマンドの再実行です。

</details>

## クイックスタート

```bash
mokume new my-sketch
cd my-sketch
mokume watch
```

初回はライブラリの取得とビルドに少し時間がかかります。ウィンドウが開いたら、`Sources/my-sketch/MySketch.swift` を編集します:

```swift
import Foundation
import mokume

@main
final class MySketch: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 960, height: 540, title: "my-sketch")
    }

    func draw() {
        background(15, 18, 23)
        fill(242, 115, 51)
        let angle = time * 0.8
        circle(width / 2 + cos(angle) * 160, height / 2 + sin(angle) * 120, 80)
    }
}
```

`fill(77, 191, 242)` に変えて保存すると、ウィンドウを開き直さずに円が水色になります。ビルドに失敗したときは直前の絵が動き続け、エラーがターミナルに表示されます。

使える API は [API リファレンス](https://mokume.org/documentation/mokume/) に、実行結果の絵つきでまとまっています。

## コマンド

| コマンド | |
| --- | --- |
| `mokume new <name>` | スケッチを作成 |
| `mokume run` | ビルドして実行 |
| `mokume watch` | 実行し、保存のたびに再ビルドして差し替え |
| `mokume render` | ウィンドウを開かずに動画・連番画像へ書き出し |
| `mokume bundle` | 配布用の `.app` を作成 |
| `mokume doctor` | 環境とスケッチの状態を表示 |
| `mokume mcp` | AI エージェント向けの MCP サーバを起動 |

オプションの一覧は `mokume help` で確認できます。

### 動画に書き出す

```bash
mokume render --fps 60 --seconds 4 --out motion.mov
```

`time` は 1 フレームごとに `1 / fps` 秒ずつ進むので、描画の重さに左右されず、同じ引数からは同じ動きが得られます。`--out` には `.mov` (ProRes 4444) か、`out/frame-####.png` のような連番を指定します。

<details>
<summary>詳しい挙動</summary>

- `fps × seconds` 枚を描き終えると終了し、書き出し先と枚数を表示します。`fps × seconds` が整数にならない組み合わせはエラーになります
- 書き出しにかかる時間は、`--fps` がスケッチの `frameRate` と同じならほぼ実時間です
- 相対パスは実行した場所が基準です。スケッチの場所・`-c`・`--scratch-path` は `run` と同じように指定できます
- `Control` + `C` で中断しても、それまでの分は残ります。最後まで書き出せなかったときは 0 以外で終了します

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

`Package.swift` で宣言したリソースも同梱されます。`mokume-app.json` は `mokume new` では作られません。識別子は macOS が権限の許可を覚えるときの鍵になるので、作品ごとに付けてください。

標準では ad-hoc 署名のため、受け取った人が初めて開くときは macOS にブロックされ、「システム設定」→「プライバシーとセキュリティ」の「このまま開く」から開く必要があります。その手順を書いた `<name> を開くには.txt` が `.app` の隣にできるので、一緒に渡してください。

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

`Sources/` で `createCapture()` を呼んでいるのに `cameraUsage` が無いと、`mokume bundle` は足すべき 1 行を示して止まります (説明文の無いアプリは、カメラに触れた時点で macOS に止められるため)。依存パッケージの中や別名を通した呼び出しは検出しないので、その場合は自分で書いてください。`createCapture(frames:)` はカメラを使わないので不要です。マイクの検出はありません。

許可が記録される先は実行のしかたで変わります:

| 実行のしかた | 許可の記録先 | 備考 |
| --- | --- | --- |
| `mokume run` など | 起動したターミナルのアプリ | 同じターミナルから実行するスケッチは 1 度の許可で済みます |
| `.app` (ad-hoc 署名) | その `.app` | 中身で識別されるため、作り直すたびに許可が外れます |
| `.app` (Developer ID 署名) | 署名者と識別子 | 作り直しても同じアプリとして扱われます |

制作中の確認は `mokume run` で行い、`.app` は配布の直前に作るのがおすすめです。

</details>

<details>
<summary>Developer ID で署名する</summary>

```bash
MOKUME_SIGN_IDENTITY="Developer ID Application: 名前 (TEAMID)" mokume bundle
```

Hardened Runtime とタイムスタンプ付きで署名し、公証に提出できる形になります。公証 (`notarytool` での提出と `stapler` での添付) は `mokume bundle` の外で行ってください。どちらの署名を使ったかは出力に表示されます。

配布前に、手元のビルド結果に依存していないかは次で確かめられます:

```bash
mv .build .build-held && open bundle/Grain.app ; mv .build-held .build
```

</details>

### AI エージェントから操作する

`mokume mcp` は、実行中のスケッチのスクリーンショット・ビルド結果・マウスとキーボードの入力・API の一覧を AI エージェントに提供する MCP サーバです。`mokume new` で作ったディレクトリには `.mcp.json` が含まれているので、Claude Code ならそのまま使えます。手動で追加する場合:

```bash
claude mcp add mokume -- mokume mcp
```

### うまく動かないとき

スケッチのディレクトリで `mokume doctor` を実行すると、環境 (`What the environment provides`) とスケッチの状態 (`What is here`) が表示されます。何も変更しないので、問題の切り分けに気軽に使えます。

## コントリビュート

Issue と Pull Request を歓迎します。始め方とソースからのビルド手順は [CONTRIBUTING.md](CONTRIBUTING.md)、作業の規約は [AGENTS.md](AGENTS.md)、設計判断の記録は [docs/decisions](docs/decisions/) にあります。`.mokume/` のファイル形式は [Schemas](Schemas) で定義しています。脆弱性の報告は [SECURITY.md](SECURITY.md) を参照してください。

## ライセンス

[MIT](LICENSE)
