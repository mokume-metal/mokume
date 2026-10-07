<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# 窓を撮る (経路 B)

**描画結果ではなく、窓・GUI・操作そのものを見せたいときだけ読む。** スケッチの絵は [SKILL.md](SKILL.md) の
経路 A (観測) で撮る。束ね方・上げ方・貼り方は SKILL.md と同じで、ここが持つのは撮り方の違いだけである。

## 撮る

窓の一覧を `gyazo_list_capturable_windows` で取る。得た id はそのまま `screencapture` に渡せる。

```bash
screencapture -l <windowId> -o shot.png       # 静止画 (窓の影を含めない)
screencapture -l <windowId> -V 5 motion.mov   # 5 秒の録画
```

**全画面 (`-l` を省く形) は撮らない** — 他アプリ・通知・手元のパスが写る。

`-l` を既定にするのは、写り込みが規律ではなく構造で起きないからである (いずれも実測):

- **窓の外は透明で、背後のものは 1 画素も入らない** (窓とパネルの隙間が `RGBA 0,0,0,0`)
- **背面のままで撮れる。** 他の窓の下でも、アプリが非活性でも同じ絵になる。前へ出すと他の窓を隠すので、
  撮れているなら出さない
- **シート・パネルなどの子ウィンドウも一緒に入る。** 親の id でも子の id でも同じ絵が返り、大きさは親と子の
  合併矩形まで広がる。子のために撮り方を変えなくてよい ([#1127](https://github.com/mokume-metal/mokume/issues/1127))

**シートが写っていないなら、まだ下りていない。** 要求してから下りるまでに間があり、下りないこともある。
撮る前に下の一覧で子ウィンドウが居ることを確かめ、撮った後も絵を見る — `-l` は在るものを落とさない。

### 撮れないとき — `-R` へ逃げない

窓が「いま画面に出ている窓」から消えている (別の Space に居る・畳まれている) と、`-l` は黙って親だけの絵を
作るのではなく、

```
could not create image from window
```

と名乗ってファイルを作らずに終わる。MCP の一覧に出ないのも同じ原因で、下の一覧を
`[.optionOnScreenOnly]` で引いて消えていればこれである。窓をいまの画面へ出して打ち直す:

```bash
osascript -e 'tell application "System Events" to set frontmost of first process whose unix id is <pid> to true'
```

**領域を撮る形 (`-R <x,y,w,h>`) は最後の手段である。** 撮るのは「その領域にいま見えているもの」なので、
対象が前面でなければ手前のアプリが入り、別の Space に居れば前面へ出した後でも対象は 1 画素も写らない
(#1127 では無関係のアプリの画面を撮ったファイルが 2 度できた)。使うなら前面へ出してから撮り、
**上げる前に撮った絵を目で確かめる** (SKILL.md の「守ること」)。

### 窓の矩形と子ウィンドウを引く

MCP の一覧が返すのは id と名前だけで、しかもいま画面に出ている窓だけである。矩形と子ウィンドウはこちらで
見る。座標は左上原点で、`-R` がそのまま要求する形である。シートは表題が空の窓として出る:

```bash
swift - <<'WINDOWS' | grep <アプリ名>
import CoreGraphics

// 画面に出ている窓も、出ていない窓も返る。表題が空の行は子ウィンドウ (シート・パネル)。
// [] を [.optionOnScreenOnly] にすると、いま画面に出ている窓だけになる — `-l` が撮れるのはこちら。
let all = CGWindowListCopyWindowInfo([], kCGNullWindowID) as? [[String: Any]] ?? []
for window in all where (window[kCGWindowLayer as String] as? Int) == 0 {
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let name = window[kCGWindowName as String] as? String ?? ""
    print(window[kCGWindowNumber as String] ?? "", window[kCGWindowOwnerPID as String] ?? "",
          window[kCGWindowOwnerName as String] ?? "", "'\(name)'",
          bounds["X"] ?? "", bounds["Y"] ?? "", bounds["Width"] ?? "", bounds["Height"] ?? "")
}
WINDOWS
```

目的の窓がここにしか出ず MCP の一覧に無ければ、別の Space に居る (`-R` を打っても写らない側)。

## 録画を束ねる

録画はまず連番へ起こす。録画は等間隔なので、A と違って `-d` は一定でよい (15fps なら 67 ミリ秒)。
可逆のまま束ねる理由と大きさの目安は SKILL.md の「動きを束ねる」のとおり。参照の面へ出す GIF も同じ節にある。

```bash
# 録画から連番へ (幅 720 / 15fps が目安)
ffmpeg -y -i motion.mov -vf "fps=15,scale=720:-1:flags=lanczos" frames/f.%04d.png

# PR / Issue へ出す — WebP (本線・退避路とも同じ。既定が可逆で 1 ビットも劣化しない)
img2webp -loop 0 -d 67 frames/f.*.png -o motion.webp
```

## うまくいかないとき

| 症状 | 対処 |
| --- | --- |
| 窓の一覧に目的の窓が出ない | 一覧はいま画面に出ている窓だけを返す。背面で起動した (`nohup` 等) スケッチや、最小化・別の Space の窓は出ない。前に出してから取り直す |
| `could not create image from window` | 窓が画面から消えている (背面にあるだけなら撮れる)。いまの画面へ出して打ち直す。`-R` へ逃げない |
| 窓の一覧が空 / 撮れない | 画面収録の許可が要る。付与は GUI 操作なので代行せず人に頼む |
