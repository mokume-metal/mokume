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

書ける口の説明は**参照の面**にある: <https://mokume-metal.github.io/mokume/reference/>

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
