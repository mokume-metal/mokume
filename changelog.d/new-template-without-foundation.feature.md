<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume new` の雛形から `import Foundation` を落とした。三角関数と計算の関数が `import mokume` だけで書けるので、雛形のスケッチは `import mokume` の 1 行で組み上がる。`FileManager` など Foundation の他の語彙は、今までどおり `import Foundation` を足せば使える。
