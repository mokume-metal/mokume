# mokume

Creative coding for Swift + Metal.

![左にスケッチのコード、右に走っている絵。fill の行を書き換えて保存すると橙の円が水色に、circle の大きさを書き換えて保存すると円が大きくなる](https://i.gyazo.com/bf9796f5fcfea45e426a854e6c9e11ce.webp)

**コードを書き換えて保存すると、走っている絵がその場で差し替わる。** 上は `mokume watch` で
走らせたまま、色と大きさの行を 1 つずつ書き換えたところ (左はその時点のファイルの中身)。

mokume は、**コードで絵や動きを作る** (クリエイティブコーディング) ための道具である。
`background` で地を塗り、`fill` で色を選び、`circle` で円を描く — Processing や p5.js を
手本にした書き方で、それを Mac の GPU (Metal) の上で Swift から書く。2D の図形と文字、
立体と光、粒と力、画素の読み書き、描き終えた絵へのエフェクトまでを、**1 つのファイルから**
始められる。

絵と最初の 1 本は入口の 1 枚にも並んでいる: <https://mokume.org>

## 作例

どれもこのリポジトリの [参照スケッチ](Sketches) が描いたもの。

| | |
| --- | --- |
| <img src="https://i.gyazo.com/34337801ec22c3d5f82c6abe5b24b453.png" width="400" alt="濃い灰の地に、橙・水色・青緑・白の小さな図形が面いっぱいに並んだ見本板"><br>図形とスタイル | <img src="https://i.gyazo.com/c4b16442441d68c13a63ae69b4db81fc.gif" width="400" alt="放射状の線が回りながら、にじみの強さが周期的に強くなったり弱くなったりする"><br>描き終えた絵にエフェクトを重ねる |
| <img src="https://i.gyazo.com/a1df70eb0294c3ee5aa50a930e898e1a.webp" width="400" alt="床の上に円柱・円錐・輪・箱・球が並び、視点が回るにつれて光の当たる面と影の向きが変わる"><br>立体と光 | <img src="https://i.gyazo.com/e3407232bafed2fe7f49bdfef740a29e.webp" width="400" alt="円の上を向かい合って回る 2 つの噴き口から橙の粒が出て、2 本の腕のような渦を描く"><br>粒と力 |
| <img src="https://i.gyazo.com/78efcf97619760a0c8557afa54083c72.webp" width="400" alt="琥珀色の等高線の模様が流れるように形を変え、暗い窪みが移動していく"><br>GPU で計算した場を絵にする | <img src="https://i.gyazo.com/cb8df7dbe450e31edafaddf488e6c416.webp" width="400" alt="橙の六角形と緑の葉のような立体が回り、手前に小さな箱が円盤状に大量に並んで回っている"><br>まとめ描きと読み込んだモデル |

## はじめる前に

mokume は **Mac 専用**で、次がそろっている必要がある。

| 要るもの | 確かめ方・入れ方 |
| --- | --- |
| **Apple Silicon の Mac** (M1 以降) | 画面左上の  メニュー →「この Mac について」の「チップ」が `Apple M…` になっていればよい。`Intel` と出る Mac では動かない |
| **macOS 26 (Tahoe) 以上** | 同じ画面の「macOS」の版を見る。足りなければ「システム設定」→「一般」→「ソフトウェア・アップデート」 |
| **Xcode 26 以上** | App Store から入れ、**一度起動して**追加の構成要素のインストールと利用許諾を済ませる。Swift の道具一式がこれで入る |
| **Metal Toolchain** | Xcode 26 からは Xcode とは別に入れる。Xcode の「Settings…」→「Components」で Metal Toolchain の「Get」を押す (ターミナルなら `xcodebuild -downloadComponent MetalToolchain`)。**入っていないと、最初に作るときに `unable to spawn process 'metal'` で止まる** |
| **Homebrew** | Mac 用のパッケージ管理の道具。<https://brew.sh> に書かれた 1 行をターミナルに貼って入れる |

**ターミナル**は、文字でコマンドを打つためのアプリ。Finder の「アプリケーション」→
「ユーティリティ」→「ターミナル」にある (Spotlight で「ターミナル」と打っても開ける)。
以下の `mokume …` の行は、すべてここに打つ。

## 入れる

```bash
brew install mokume-metal/tap/mokume
```

**入るのも打つのも `mokume`** という名前の道具ひとつ。更新は `brew upgrade mokume`。
`mokume-cli` はこのリポジトリを自分でビルドしたときだけの名前なので、Homebrew では
見つからない ([手元で作る](CONTRIBUTING.md#手元で作る))。

<details>
<summary>Homebrew を使わずに入れる</summary>

同じ配布物を直に展開してもよい:

```bash
mkdir -p ~/.local/bin
curl -fsSL https://github.com/mokume-metal/mokume/releases/latest/download/mokume-macos-arm64.tar.gz | tar xz -C ~/.local/bin
```

道具 `mokume` と、隣に置く資源 (`mokume_*.bundle`) が展開される — **同じディレクトリに
並んだまま使う**。`~/.local/bin` に PATH が通っていなければ通す。更新は同じコマンドを
打ち直す。

</details>

ライブラリ本体は入れなくてよい。次の `mokume new` が作るスケッチが、必要なものを自分で取ってくる。

## 最初の 1 本

### 1. スケッチを作る

**スケッチ**は、mokume で作る 1 つの作品のこと。中身は Swift のパッケージ (フォルダ) である。

```bash
mokume new my-sketch
cd my-sketch
```

`my-sketch` というフォルダができる。書き換えるのは**描く中身の 1 ファイルだけ**でよい:

| ファイル | 何か |
| --- | --- |
| **`Sources/my-sketch/MySketch.swift`** | **絵を描くコード。ここを書き換える** |
| `Sources/my-sketch/assets/` | 画像や音を置く場所 |
| `Package.swift` | パッケージの設定 (mokume を使うことが書いてある)。はじめは触らなくてよい |
| `AGENTS.md` / `CLAUDE.md` / `.mcp.json` | AI エージェントと一緒に作るときの案内 ([エージェントから使う](#エージェントから使う)) |

### 2. 走らせる

```bash
mokume run
```

作ってから窓を開き、絵を動かし始める。**初回だけ、必要なライブラリの取得とビルドで
しばらく待つ** (回線と Mac によって数十秒から数分。2 回目からは数秒)。

窓には、暗い地の上を橙の円が回る絵が出る。ターミナルには速さが出続ける:

```
Rate: 58.7 fps (debug)
```

1 秒に何枚描けているかと、どの構成 (debug / release) で作ったかを並べている。速さは
構成で数倍変わるので、**重い / 軽いは数字だけで決めない**。

**止めるときは、窓を閉じるか、ターミナルで `Control` + `C`**。

### 3. 読む

`MySketch.swift` を好きなエディタで開く (はじめてなら Xcode でも、テキストエディットでもよい)。
中身はこうなっている:

```swift
import Foundation
import mokume

@main
final class MySketch: Sketch {
    // 窓の大きさと題
    var settings: SketchSettings {
        SketchSettings(width: 960, height: 540, title: "my-sketch")
    }

    // 1 秒に何十回も呼ばれ、そのたびに 1 枚を描く
    func draw() {
        background(.display(red: 0.06, green: 0.07, blue: 0.09))  // 地を暗い色で塗る
        fill(.display(red: 0.95, green: 0.45, blue: 0.2))        // これから描く図形の色 (橙)
        let angle = time * 0.8                                     // time は走り始めてからの秒数
        circle(width / 2 + cos(angle) * 160, height / 2 + sin(angle) * 120, 80)  // 中心 x, 中心 y, 直径
    }
}
```

`draw()` が毎回呼ばれ、`time` が進むので、円の位置が少しずつずれて回って見える。

### 4. 書き換えて、保存したら差し替わるのを見る

走らせ方を `watch` に変える (`run` で走っていれば、先に止める):

```bash
mokume watch
```

走らせたまま `MySketch.swift` を開き、`fill` の行の数字を変えて保存する — 例えば
`red: 0.3, green: 0.75, blue: 0.95` にすると、**窓を開き直さなくても円が水色に変わる**
(冒頭の動きと同じ操作)。`circle` の最後の `80` を `140` にすれば大きくなる。

保存するたびに作り直して、走っている絵を差し替える。**書き間違えて作れなかったときは、
前の絵が走り続け、ターミナルに理由が出る** — 直して保存し直せばよい。

### 5. 次に読むもの

- **書ける命令の一覧と説明**は参照の面にある。1 つずつ、そのまま動く例と実行結果の絵がつく:
  <https://mokume.org/documentation/mokume/>
- **もっと大きな例**は [参照スケッチ](Sketches) (上の作例を描いたもの)

## ことば

| ことば | 意味 |
| --- | --- |
| **スケッチ** | mokume で作る作品 1 つ。`mokume new` が作るフォルダ |
| **Swift** | Apple が作ったプログラミング言語。スケッチはこれで書く |
| **Metal** | Mac の GPU を使って絵を描くための Apple の仕組み。mokume は描く部分をこれで動かすので、書く側が直接触る必要はない |
| **ビルド** | 書いたコードを、動くプログラムに変換すること。`mokume run` / `watch` が代わりに行う |

## 動かないとき

窓が出ない・走らせたスケッチが応えないときは、スケッチのフォルダで打つ:

```bash
mokume doctor
```

**この Mac がそろえているもの** (`What the environment provides` — OS・機種・GPU・
Swift の道具) と、**そのフォルダの状態** (`What is here` — スケッチ・ビルドの跡とその
置き場・最後の作り直し) が 1 つの出力に並ぶ。「前提がそろっていない」のか「前提は
そろっているが手元の状態がおかしい」のかを、ここで見分ける。

**何も直さない。** 状態と読み方だけを出す。判定できなかったものは `cannot tell` と名乗る。

よく踏むもの:

- **`unable to spawn process 'metal'` で作れない** — Metal Toolchain が入っていない。
  [はじめる前に](#はじめる前に) の表のとおり入れる
- **`command not found: mokume`** — 道具が入っていない、または PATH が通っていない。
  `brew install` をやり直すか、ターミナルを開き直す

## 渡す

作った作品を、自分以外の Mac でも動く形 (`.app`) に束ねる。まず作品の名乗り
(表示名・識別子・版) を、スケッチのフォルダの直下に `mokume-app.json` として置く:

```json
{
  "name": "Grain",
  "identifier": "org.example.grain",
  "version": "0.1.0"
}
```

```bash
mokume bundle          # bundle/<表示名>.app が出来る
```

**この名乗りはひな形に入っていない。** 書かなくても走るが、書かないまま配ると事故に
なる — とくに識別子は macOS の権限の許可がぶら下がる鍵なので、作品ごとに書く。

束ねるものは `Package.swift` が宣言した資材で、宣言された資材が入らなかったときは
配る前にそこで止まる。

**保証しているのは「別の Mac で起動して絵が出る」ところまで。** 署名は名前を持たない
もの (ad-hoc) なので、**受け取った側では初回の起動が止められる**。二重クリックだけでは
開けず、止められた直後にシステム設定の「プライバシーとセキュリティ」を開いて、そこに
だけ出る「このまま開く」を押すことになる。

この往復は消えないので、代わりに開き方を書いた 1 枚が包みの隣に出る。**作品と一緒に送る**:

```
bundle/
  Grain.app
  Grain を開くには.txt
```

### 自分の証明書を持っているなら

署名に使う名前を環境から与えると、**公証に出せる形**で束ねる (強化されたランタイムと
タイムスタンプが当たる):

```bash
MOKUME_SIGN_IDENTITY="Developer ID Application: 名前 (TEAMID)" mokume bundle
```

与えなければ名前を持たない署名になる。どちらで署名したかは束ねた後の出力が名乗る。

**公証そのものは打たない。** 名前のある署名を当てただけでは受け取った側の往復は消えず、
`notarytool` に提出して `stapler` で結果を添付するまでが要る — そこは道具の外にある。

配る前に、自分の環境に依存したものが残っていないかを確かめる — ビルドの跡を退避してから
起動する:

```bash
mv .build .build-held && open bundle/Grain.app ; mv .build-held .build
```

## エージェントから使う

走っているスケッチを、Claude Code などの AI エージェントが外から見て、入力を送れる。
窓口 (MCP サーバ) を繋ぐと、絵を撮る・作り直しの結果を読む・入力を送る・書ける命令の
一覧を読む、が使える。`mokume new` が作ったフォルダには `.mcp.json` が入っているので、
そこで Claude Code を開き、使ってよいかを聞かれたら許可すれば繋がる。自分で足すなら:

```bash
claude mcp add mokume -- mokume mcp
```

窓口は薄い層で、能力そのものはスケッチ側にある — `.mokume/` のファイルを直に
読み書きしても同じことができる (形の正典は [`Schemas/`](Schemas))。公開 API の
一覧は版ごとに [Releases](https://github.com/mokume-metal/mokume/releases) の
資産として配られ、窓口が `.mokume/reference/` へ取り置いて返す。

## もっと読む

- 書ける命令の説明 (参照の面): <https://mokume.org/documentation/mokume/>
- 入口の 1 枚: <https://mokume.org>
- 開発の見通し: [mokume Roadmap](https://github.com/orgs/mokume-metal/projects/1)
- mokume 自体を触る (手元で作る・貢献の入口): [CONTRIBUTING.md](CONTRIBUTING.md)
