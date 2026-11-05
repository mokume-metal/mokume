<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# ウィンドウを撮る (経路 B)

**描画結果ではなく、ウィンドウ・GUI・操作そのものを見せたいときだけ読む。** スケッチの絵は [SKILL.md](SKILL.md) の
経路 A (`observe`) で撮る。エンコード・アップロード・貼り方は SKILL.md と同じで、ここが持つのは撮り方の違いだけである。

## 撮る

ウィンドウの一覧を `gyazo_list_capturable_windows` で取得する。得た id はそのまま `screencapture` に渡せる。
gyazo-mac の MCP が無ければ、下の「ウィンドウの矩形と子ウィンドウを取得する」の Swift (`CGWindowListCopyWindowInfo`) の
一覧の先頭の列 (ウィンドウ番号) を id に使う。

```bash
screencapture -l <windowId> -o shot.png       # 静止画 (ウィンドウの影を含めない)
screencapture -l <windowId> -V 5 motion.mov   # 5 秒の録画
```

**全画面 (`-l` を省く形) は撮らない** — 他アプリ・通知・手元のパスが写る。

`-l` を既定にするのは、写り込みが規律ではなく仕組みとして起きないからである (いずれも実測):

- **ウィンドウの外は透明で、背後のものは 1 ピクセルも入らない** (ウィンドウとパネルの隙間が `RGBA 0,0,0,0`)
- **背面のままで撮れる。** 他のウィンドウの下でも、アプリが非アクティブでも同じ画像になる。前面へ出すと他のウィンドウを隠すので、
  撮れているなら出さない
- **シート・パネルなどの子ウィンドウも一緒に入る。** 親の id でも子の id でも同じ画像が返り、サイズは親と子の
  合併矩形まで広がる。子のために撮り方を変えなくてよい ([#1127](https://github.com/mokume-metal/mokume/issues/1127))

**シートが写っていないなら、まだ表示されていない。** 要求してから表示されるまでに間があり、表示されないこともある。
撮る前に下の一覧で子ウィンドウがあることを確かめ、撮った後も画像を見る — `-l` はあるものを省かない。

### 撮れないとき — `-R` へ逃げない

ウィンドウが「いま画面に出ているウィンドウ」から消えている (別の Space にある・最小化されている) と、`-l` は何も言わずに親だけの画像を
作るのではなく、

```
could not create image from window
```

とエラーを出してファイルを作らずに終了する。MCP の一覧に出ないのも同じ原因で、下の一覧を
`[.optionOnScreenOnly]` で取得して消えていればこれである。ウィンドウをいまの画面へ出して再実行する:

```bash
osascript -e 'tell application "System Events" to set frontmost of first process whose unix id is <pid> to true'
```

**領域を撮る形 (`-R <x,y,w,h>`) は最後の手段である。** 撮るのは「その領域にいま見えているもの」なので、
対象が前面でなければ手前のアプリが入り、別の Space にあれば前面へ出した後でも対象は 1 ピクセルも写らない
(#1127 では無関係のアプリの画面を撮ったファイルが 2 度できた)。使うなら前面へ出してから撮り、
**アップロードする前に撮った画像を目で確かめる** (SKILL.md の「守ること」)。

### ウィンドウの矩形と子ウィンドウを取得する

MCP の一覧が返すのは id と名前だけで、しかもいま画面に出ているウィンドウだけである。矩形と子ウィンドウはこちらで
見る。座標は左上原点で、`-R` がそのまま要求する形である。シートはタイトルが空のウィンドウとして出る:

```bash
swift - <<'WINDOWS' | grep <アプリ名>
import CoreGraphics

// 画面に出ているウィンドウも、出ていないウィンドウも返る。表題が空の行は子ウィンドウ (シート・パネル)。
// [] を [.optionOnScreenOnly] にすると、いま画面に出ているウィンドウだけになる — `-l` が撮れるのはこちら。
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

目的のウィンドウがここにしか出ず MCP の一覧に無ければ、別の Space にある (`-R` を実行しても写らない側)。

## 録画をエンコードする

録画はまず連番の画像へ変換する。録画は等間隔なので、経路 A と違って `-d` は一定でよい (15fps なら 67 ミリ秒)。
可逆のままエンコードする理由とサイズの目安は SKILL.md の「動きをエンコードする」のとおり。リファレンスへ出す GIF も同じ節にある。

```bash
# 録画から連番へ (幅 720 / 15fps が目安)
ffmpeg -y -i motion.mov -vf "fps=15,scale=720:-1:flags=lanczos" frames/f.%04d.png

# PR / Issue へ出す — WebP (本線・退避路とも同じ。既定が可逆で 1 ビットも劣化しない)
img2webp -loop 0 -d 67 frames/f.*.png -o motion.webp
```

## うまくいかないとき

| 症状 | 対処 |
| --- | --- |
| ウィンドウの一覧に目的のウィンドウが出ない | 一覧はいま画面に出ているウィンドウだけを返す。バックグラウンドで起動した (`nohup` 等) スケッチや、最小化・別の Space のウィンドウは出ない。前面に出してから取得し直す |
| `could not create image from window` | ウィンドウが画面から消えている (背面にあるだけなら撮れる)。いまの画面へ出して再実行する。`-R` へ逃げない |
| ウィンドウの一覧が空 / 撮れない | 画面収録の許可が要る。付与は GUI 操作なので代行せず人に頼む |
