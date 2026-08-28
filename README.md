# mokume

Creative coding for Swift + Metal.

## 使う

```bash
mokume-cli new my-sketch   # そのまま動くスケッチ一式を作る
cd my-sketch
mokume-cli run             # 作って走らせる
mokume-cli watch           # 保存したら作り直して差し替える
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

## エージェントから使う

走っているスケッチを外から観測し、入力を送れる。窓口 (MCP サーバ) を繋ぐと、
撮る・作り直しの結果を読む・入力を送る・面の仕様を読む、が使える。

```bash
claude mcp add mokume -- mokume-cli mcp
```

窓口は薄い層で、能力そのものはスケッチ側にある — `.mokume/` のファイルを直に
読み書きしても同じことができる (形の正典は [`Schemas/`](Schemas))。

- 開発の見通し: [mokume Roadmap](https://github.com/orgs/mokume-metal/projects/1)

<!-- #259 の実測用の使い捨て変更。merge しない。 -->
