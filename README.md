# mokume

[![Release](https://img.shields.io/github/v/release/mokume-metal/mokume?label=version)](https://github.com/mokume-metal/mokume/releases/latest)
[![Release workflow](https://github.com/mokume-metal/mokume/actions/workflows/release.yml/badge.svg?branch=main&event=schedule)](https://github.com/mokume-metal/mokume/actions/workflows/release.yml?query=event%3Aschedule)
[![Reference](https://img.shields.io/badge/reference-DocC-8A2BE2)](https://mokume.org/documentation/mokume/)
[![Swift 6.2+](https://img.shields.io/badge/Swift-6.2%2B-F05138?logo=swift&logoColor=white)](https://www.swift.org)
[![Platform macOS 26+](https://img.shields.io/badge/platform-macOS%2026%2B%20%C2%B7%20Apple%20Silicon-blue?logo=apple)](https://developer.apple.com/macos/)
[![License MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

Swift と Metal で、絵と動きをつくるクリエイティブコーディング環境。Processing や p5.js のように書き、コードを保存すると、その場で絵が変わります。

[公式サイト](https://mokume.org) · [API リファレンス](https://mokume.org/documentation/mokume/) · [作例](Sketches)

![左にスケッチのコード、右に実行中の絵。fill の行を書き換えて保存すると橙の円が水色に、circle の大きさを書き換えて保存すると円が大きくなる](https://i.gyazo.com/bf9796f5fcfea45e426a854e6c9e11ce.webp)

## できること

- **保存したら、その場で変わる** — ライブリロードで、動いている絵を見ながらコードを育てられます。
- **小さなスケッチから、立体や粒子まで** — Processing / p5.js になじみのある API で、図形・文字・3D・ライティング・パーティクルを扱えます。
- **Metal で描き、GPU で計算する** — Apple Silicon の GPU を使い、ポストエフェクトや計算した場を絵にできます。
- **作品を持ち出す** — 動画・連番画像・GIF・MP4 への書き出しや、配布用の macOS アプリの作成ができます。

## 作例

| | |
| --- | --- |
| <img src="https://i.gyazo.com/c4b16442441d68c13a63ae69b4db81fc.gif" width="400" alt="放射状の線が回りながら、にじみの強さが周期的に強くなったり弱くなったりする"><br>ポストエフェクト | <img src="https://i.gyazo.com/a1df70eb0294c3ee5aa50a930e898e1a.webp" width="400" alt="床の上に円柱・円錐・輪・箱・球が並び、視点が回るにつれて光の当たる面と影の向きが変わる"><br>3D とライティング |
| <img src="https://i.gyazo.com/e3407232bafed2fe7f49bdfef740a29e.webp" width="400" alt="円の上を向かい合って回る 2 つの噴き口から橙の粒が出て、2 本の腕のような渦を描く"><br>パーティクルと力 | <img src="https://i.gyazo.com/b31b34d167a305a409b771281a2251d8.webp" width="400" alt="光を受けた起伏のように青緑の谷と琥珀の尾根が流れて形を変え、その上を等高線が走る。頂に照準が置かれ、下の帯がその行の断面を描く"><br>GPU で計算した場 |

ソースは [Sketches](Sketches) にあります。短い API の例は `mokume examples` で探せます。

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
