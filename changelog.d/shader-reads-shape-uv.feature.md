<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`shader()` だけを当てた形にも、形の中の位置が `in.uv` で届くようになりました ([#3797](https://github.com/mokume-metal/mokume/issues/3797))。`texture()` で絵を貼っていなくても、平面の図形は囲みの箱の 0…1、立体はメッシュの位置 (箱は面ごと・球は経緯) を受け取ります。白い 1×1 の絵を貼ったときとまったく同じ値なので、`in.uv` から作った模様は `circle` にも `rect` にも `box` にもテクスチャのように収まり、形と一緒に動きます。

```swift
shader(rings)                  // in.uv から同心円を描く断片
circle(mouseX, mouseY, 120)    // 同心円の中心が円の中心に留まる
rect(40, 40, 200, 100)         // 同じ模様が四角の中に収まる
resetShader()
```

これまで、絵を貼らずに断片を当てた形の `in.uv` は、形の中で変わらない 1 点でした。その値に頼っていた断片は描き方が変わります。粒の板も、断片を当てて作ると `in.uv` に板の 0…1 を持ちます。勾配の塗り・字・画像・輪郭と線、断片を当てていない形は変わりません。作例は参照スケッチの `pattern-and-shape` にあります。
