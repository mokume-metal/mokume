# mokume

Creative coding for Swift + Metal.

## 入れる

macOS 26 (Tahoe) 以上・Apple Silicon 専用。スケッチを作り直すのに Xcode 26 が要る。

```bash
brew install mokume-metal/tap/mokume
```

**入るのも打つのも `mokume`** という名前の道具ひとつ。`mokume-cli` はこのリポジトリを
自分でビルドしたときだけの名前なので、Homebrew では見つからない
([手元のビルドを使う](#手元のビルドを使う))。更新は `brew upgrade mokume`。

Homebrew を使わないなら、同じ配布物を直に展開してもよい:

```bash
mkdir -p ~/.local/bin
curl -fsSL https://github.com/mokume-metal/mokume/releases/latest/download/mokume-macos-arm64.tar.gz | tar xz -C ~/.local/bin
```

この場合、道具 `mokume` と、ひな形の入った `mokume_MokumeCLI.bundle` が置かれる —
**2 つで 1 組**で、同じディレクトリに並んでいる必要がある。`~/.local/bin` に PATH が
通っていなければ通す。更新は同じコマンドを打ち直す。

ライブラリ本体は入れなくてよい。`mokume new` が作るスケッチが依存として引く。

### 手元のビルドを使う

リリースを待たずに試すとき、ライブラリを触りながらスケッチで確かめるときは、この
リポジトリから道具を作る:

```bash
git clone https://github.com/mokume-metal/mokume.git
cd mokume
swift build -c release --product mokume-cli
export PATH="$PWD/.build/release:$PATH"   # この shell の間だけ
```

できるのは `mokume-cli` — 配布物の `mokume` と同じ道具で、名前だけが違う (道具は
起動された名前で名乗るので、印字される行はそのまま打てる)。ひな形の入った
`mokume_MokumeCLI.bundle` は隣に作られるので、実行ファイルだけを別の場所へ移さない。

スケッチにも手元のライブラリを引かせるなら、`--local` でこのリポジトリの場所を渡す:

```bash
cd ..
mokume-cli new --local ../mokume my-sketch
cd my-sketch
mokume-cli run
```

渡した場所は生成される `Package.swift` の `.package(path:)` へそのまま入るので、
**作られるスケッチから見た相対**で書く (絶対パスでもよい)。`--local` を付けなければ、
公開済みの版を引く。

## 使う

```bash
mokume new my-sketch   # そのまま動くスケッチ一式を作る
cd my-sketch
mokume run             # 作って走らせる
mokume watch           # 保存したら作り直して差し替える
```

走らせている間は、**速さが構成と同じ行に出る**:

```
速さ: 58.7 fps (構成: debug)
```

**数字だけを見て重い / 軽いを決めない**ための並べ方である — 速さは構成で数倍変わる。
フレームが進んでいないときは `測れない` と出る (0 とは書かない)。窓口 (`mokume mcp`)
から立てたスケッチには出ない。

スケッチは 1 ファイルから始められる:

```swift
import mokume

final class MySketch: Sketch {
    func draw() {
        background(.display(red: 0.06, green: 0.07, blue: 0.09))
        fill(.display(red: 0.95, green: 0.45, blue: 0.2))
        circle(mouseX, mouseY, 120)
    }
}

MySketch.main()
```

書ける口の説明は**参照の面**にある: <https://mokume.org/documentation/mokumecore/>

## 動かないとき

窓口も走らせたスケッチも応えないときは、端末から打つ:

```bash
mokume doctor          # 場所を省くといまいるところ
```

**環境の前提** (OS・機種・描く道具・道具立て)・**手元の状態** (スケッチ・組み上げた跡・
最後の作り直し)・**起動の瞬間に決まるもの** が同じ出力に並ぶ。前提と状態を並べないと、
「そもそも前提を満たしていない」と「前提は満たしているが区画が割れている」を分けられない。

**何も直さない。** 区画を作ったり走っているものを止めたりはせず、状態と読み方だけを出す。
読めなかったものは「判定できず」と名乗り、こちらで断定しない。

## 渡す

作った作品を、作者以外の環境で動く形に束ねる。名乗り (表示名・識別子・版) を
スケッチの直下へ 1 枚置いてから打つ:

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
なるもので、とくに識別子は権限の許可がぶら下がる鍵である — 仮の値を全員が共有する形に
しないため、作品ごとに書く。

束ねるものの正典は `Package.swift` が宣言した資材で、ソースの走査で推測しない。
宣言された資材が入らなかったときは、配る前にそこで止まる。

**保証しているのは「別の機械で起動して絵が出る」ところまで。** 署名は名前を持たない
もの (ad-hoc) なので、**受け取った側では初回の起動が止められる**。二重クリックだけでは
開けず、止められた直後にシステム設定の「プライバシーとセキュリティ」を開いて、そこに
だけ出る「このまま開く」を押すことになる。

**この往復は消えない。** 代わりに、開き方を書いた 1 枚が包みの隣に出る:

```
bundle/
  Grain.app
  Grain を開くには.txt
```

**作品と一緒に送る。** 配るたびに手順を伝え直さずに済む。

### 自分の証明書を持っているなら

署名に使う名前を環境から与えると、**公証に出せる形**で束ねる (強化されたランタイムと
タイムスタンプが当たる):

```bash
MOKUME_SIGN_IDENTITY="Developer ID Application: 名前 (TEAMID)" mokume bundle
```

与えなければ、いままでどおり名前を持たない署名になる。どちらで署名したかは束ねた後の
出力が名乗る。

**公証そのものは打たない。** 名前のある署名を当てただけでは受け取った側の往復は消えず、
`notarytool` に提出して `stapler` で結果を添付するまでが要る — そこは道具の外にある
(段の切り方は [ADR-0029](docs/decisions/0029-post-run-surfaces.md) 決定 4)。

配る前に、作者の環境に依存した解決が残っていないかを確かめる — 組み上げた場所を
退避してから起動する:

```bash
mv .build .build-held && open bundle/Grain.app ; mv .build-held .build
```

## エージェントから使う

走っているスケッチを外から観測し、入力を送れる。窓口 (MCP サーバ) を繋ぐと、
撮る・作り直しの結果を読む・入力を送る・面の仕様と公開 API を読む、が使える。

```bash
claude mcp add mokume -- mokume mcp
```

窓口は薄い層で、能力そのものはスケッチ側にある — `.mokume/` のファイルを直に
読み書きしても同じことができる (形の正典は [`Schemas/`](Schemas))。公開 API の
一覧だけは版ごとに [Releases](https://github.com/mokume-metal/mokume/releases) の
資産として配られ、窓口が `.mokume/reference/` へ取り置いて返す。

- 開発の見通し: [mokume Roadmap](https://github.com/orgs/mokume-metal/projects/1)
- 貢献の入口: [CONTRIBUTING.md](CONTRIBUTING.md)
