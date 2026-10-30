# mokume

[![Release](https://img.shields.io/github/v/release/mokume-metal/mokume?label=version)](https://github.com/mokume-metal/mokume/releases/latest)

Swift と Metal で、絵と動きをつくるクリエイティブコーディング環境。Processing や p5.js のように書き、コードを保存すると、その場で絵が変わります。

[公式サイト](https://mokume.org) · [API リファレンス](https://mokume.org/documentation/mokume/) · [作例](Sketches)

![左にスケッチのコード、右に実行中の絵。fill の行を書き換えて保存すると橙の円が水色に、circle の大きさを書き換えて保存すると円が大きくなる](https://i.gyazo.com/bf9796f5fcfea45e426a854e6c9e11ce.webp)

## はじめる

<a id="必要な環境"></a>
<a id="インストール"></a>

Apple Silicon の Mac・macOS 26 以降・Command Line Tools 26 以降が必要です。Xcode は要りません。Command Line Tools は [Homebrew](https://brew.sh) の導入時に入ります。

```bash
brew install mokume-metal/tap/mokume
mokume new my-sketch
cd my-sketch
mokume watch
```

初回はライブラリの取得とビルドに少し時間がかかります。ウィンドウが開いたら、`Sources/my-sketch/MySketch.swift` を編集して保存してください。

<details>
<summary>最初のスケッチを見る</summary>

```swift
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

`fill(77, 191, 242)` に変えて保存すると、円が水色になります。

</details>

## ドキュメント

- [利用ガイド](docs/guide.md) — 別のインストール方法、コマンド、動画の書き出し、アプリの配布、AI エージェントとの連携
- [API リファレンス](https://mokume.org/documentation/mokume/) — 絵とコードで調べる API
- [Processing / p5.js からはじめる](https://mokume.org/documentation/mokume/#Swift-で-3-つだけ違うこと) — Swift で最初に知っておくこと
- [リリース](https://github.com/mokume-metal/mokume/releases) — 更新内容とダウンロード

[開発に参加する](CONTRIBUTING.md) · [脆弱性の報告](SECURITY.md) · [MIT ライセンス](LICENSE)
