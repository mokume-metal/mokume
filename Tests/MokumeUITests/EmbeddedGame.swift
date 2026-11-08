// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 埋め込まれるスケッチ。スケッチのファイルは `import mokume` で書く (#3872)。

import mokume

final class EmbeddedGame: Sketch {
    func draw() {
        background(26, 26, 31)
        circle(mouseX, mouseY, 60)
    }
}
