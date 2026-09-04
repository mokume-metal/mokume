---
name: gyazo-evidence
description: 描画結果・動きが変わる変更を PR / Issue に記録するとき、スケッチの絵や窓の様子を Gyazo へ上げて URL を得る。撮る経路・宛先ごとの形式・出所の残し方を扱う。Use when attaching visual evidence to a pull request or issue, when a drawing or motion change needs before/after images, when capturing an animated WebP or GIF, or when embedding images in docs.
allowed-tools: "mcp__gyazo-mac__gyazo_list_capturable_windows"
---

<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# Gyazo で視覚証跡を残す

**何を載せるかの規律は AGENTS.md 「描画に影響する変更」が正典**で、ここは手順だけを持つ。

手順が要るのは、証跡がこのリポジトリでは添え物ではないからである。CI は描画を走らせられない
([#180](https://github.com/mokume-metal/mokume/issues/180)) ので、**緑は「描けている」を意味しない**。
PR に貼られた絵が描画の唯一の検証記録になり、squash merge でブランチが消えた後には足せない。

> **人がこれを読んでいるなら、たいていここは要らない。** Issue / PR の入力欄へ画像を落とせば
> GitHub が保管して URL を返す — アカウントもトークンも要らず、そちらの方が早い。
> この文書が扱うのは**エージェントの経路**である。直接アップロードには API が無く、
> エージェントには押せる入力欄も無いため、代わりに Gyazo へ上げて URL を貼る。

## 撮る経路は 2 つ

| | 撮るもの | 撮り方 |
| --- | --- | --- |
| **A** (既定) | mokume が描いた絵 | 観測 |
| **B** | 窓・GUI・操作そのもの | 画面の撮影 |

A を既定にするのは理由が 3 つ重なるため — 同じ条件で撮り直せる / 他アプリの映り込みが構造的に無い /
窓の位置や画面構成に依存しない。**B は「描画結果ではなく画面そのものを見せたいとき」に限る。**

**撮影と送信は分ける。** Gyazo の MCP には撮って即座に上げる道具があるが、使わない。手元に落として
から上げれば、外部サービスへ送る前に写り込みを検められる。MCP から取るのは窓の一覧だけで、
`allowed-tools` にそれしか載せていないのはこのためである。

## A. スケッチの絵を撮る

走らせてから観測する。**区画を作るのが先、走らせるのが後**である。

```bash
mkdir -p <スケッチの場所>/.mokume/observe    # 起動より先に作る
swift run mokume-cli watch <スケッチの場所>  # 窓が出る
swift run mokume-cli mcp <スケッチの場所>    # エージェントの窓口を立てる
```

> **順序を逆にすると撮れない。** 観測は**起動の瞬間に区画があるときだけ**有効になる
> (`FrameObserver.makeIfEnabled`)。後から作っても、走っているスケッチは拾わない。
> 踏んだときは窓口が「区画はこの呼び出しで作ったので、**起動し直してください**」と返すので、
> **区画は作り直さず、走らせているスケッチを立ち上げ直す** ([#227](https://github.com/mokume-metal/mokume/issues/227))。

窓口の `observe` が返すのは、絵の場所と内訳 (フレーム番号・時刻・大きさ・絵の要約・走らせている
重さ・スケッチが差し出した値・**版の刻印**)。この内訳がそのまま出所の記録になるので、捨てずに取っておく。

窓口を立てずに区画へ直接置いてもよい。`.mokume/observe/request.json` へ `{"id": "<毎回変える>"}` を
原子的に置き、`.mokume/observe/report.json` の `id` が一致するまで待つ (仕様は
`Schemas/observe-request.schema.json`、置き方と待ち方の実装は `scripts/observe_lib.py`)。

### 動きも A で撮る

**識別子を変えながら要求を置き、`report.json` の `id` が一致したら `image` が指す絵を退避する** —
これを繰り返せば連番がそのまま手に入る。B のように録画から起こす必要は無い。要求に `scale` を
添えると書き出しの時点で縮むので、束ねる前の縮小も要らない。

**リポジトリの根から打つ** (`scripts/observe_lib.py` を読むため)。

```bash
python3 - <スケッチの場所>/.mokume/observe frames 70 0.5 <<'CAPTURE'
import json, pathlib, shutil, sys, time

sys.path.insert(0, "scripts")
from observe_lib import answered, place          # 置き方と待ち方の正典はこれ 1 つ

facet, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
rounds, scale = int(sys.argv[3]), float(sys.argv[4])
out.mkdir(parents=True, exist_ok=True)
previous, timing = None, []

for index in range(1, rounds + 1):
    identifier = f"f{index:04d}"
    place(facet, {"id": identifier, "scale": scale})

    name, taken = f"f.{index:04d}.png", None
    report = answered(facet, identifier, 1.5)     # 壁時計ではなく識別子の一致で完了を知る
    if report and report.get("image"):
        taken = shutil.copy(facet / report["image"], out / name)

    if taken is None and previous:                # 返らなかったら直前の絵を置く
        shutil.copy(previous, out / name)
    previous = taken or previous
    timing.append({"file": name, "at": time.time()})  # 何時に採れたか = その絵が出ていた長さ

(out / "timing.json").write_text(json.dumps(timing))
CAPTURE
```

**置き方と待ち方をここに写さない** ([#817](https://github.com/mokume-metal/mokume/issues/817))。
実装は `scripts/observe_lib.py` の 1 つで、`scripts/check-observation-roundtrip.sh` と
`scripts/measure-frame-rate.sh` も同じものを読む — 以前はこの 3 か所と文章の 4 通りに散っており、
ADR-0018 決定 3 の正典がどれなのか誰にも分からなかった。**形式の正典は `Schemas/` の
`observe-request` / `observe-report`** である (絵のファイル名も応答の `image` が名乗る — 決め打ちしない)。

> **応答が返らなかった回は直前の絵で埋める。抜けを詰めない。** 詰めると「面が黙った」ことが動きから
> 消えてしまい、それ自体が見せたい事象であることがある
> ([#310](https://github.com/mokume-metal/mokume/pull/310#issuecomment-5452377415) が実例 — 窓を畳んだ後に
> 絵が凍るか回り続けるかの差が、70 枚のうち異なる絵の枚数として出た)。

> **採れる間隔は一定ではない。等間隔で束ねると、無かった動きを作ってしまう。** 1 枚ごとに応答を待つので、
> 1 枚あたりの間隔は絵の重さや機械の都合で揺れる。角度や位置が時刻の関数である以上、**揺れた間隔で
> 等間隔に束ねると、スケッチが速さを変えていないのに速さが変わって見える** — かつて観測を続けると
> フレームレート自体が落ちていた頃には、間隔が `0.248 秒 → 0.83 秒` と 3.3 倍に開き、
> **扇が 3.3 倍速で回り出す動画**になった ([#370](https://github.com/mokume-metal/mokume/issues/370) で解消)。
>
> だから **`timing.json` を採り、各フレームの表示時間を実際の間隔から決める** (下記)。そうすれば採取が
> 揺れても動画は実時間どおりになり、絵が実際に止まったときは「止まって見える」という**本当のこと**が映る。

## B. 窓を撮る

窓の一覧を `gyazo_list_capturable_windows` で取る。**得た id はそのまま `screencapture` に渡せる。**

```bash
screencapture -l <windowId> -o shot.png       # 静止画 (窓の影を含めない)
screencapture -l <windowId> -V 5 motion.mov   # 5 秒の録画
```

**全画面 (`-l` を省く形) は撮らない** — 他アプリ・通知・手元のパスが写る。

## 動きを束ねる — 形式は宛先で決まる

| 宛先 | 静止画 | 動き | 使えないもの |
| --- | --- | --- | --- |
| PR / Issue | PNG | **WebP** | mp4 |
| 参照の面 | PNG | **GIF** | WebP / mp4 |

PR / Issue で WebP を使うのは、同じ絵で GIF より小さく、色数が多くても劣化しないため。
**参照の面は WebP を警告も出さずに落とす**ので、そちらへ出すものだけ GIF にする。

> **落ち方が「無言」である**ことを実測で確かめてある ([ADR-0027](../../../docs/decisions/0027-readable-surfaces.md)
> の「測ったこと」)。WebP を指した参照は本文から丸ごと消え、周りの文だけが残る — ビルドは緑・警告も
> 無しなので、**公開された面を見るまで気付けない**。
>
> 面を作る道具そのものは `@Video` で mp4 を扱えるが、**上げる経路が無い** (下記「うまくいかないとき」)。
> 動きを参照の面へ出す手段は、いまのところ GIF だけである。

**A は連番がそのまま手に入る**ので、束ねる所から始める。B は録画なので、まず連番へ起こす。

```bash
# 録画から連番へ (B のみ・幅 720 / 15fps が目安)
ffmpeg -y -i motion.mov -vf "fps=15,scale=720:-1:flags=lanczos" frames/f.%04d.png

# PR / Issue へ出す — WebP (B は録画なので等間隔でよい。既定が可逆で 1 ビットも劣化しない)
img2webp -loop 0 -d 67 frames/f.*.png -o motion.webp

# 参照の面へ出す — GIF (パレットを作ってから通す)
ffmpeg -y -i motion.mov -vf "fps=15,scale=720:-1:flags=lanczos,palettegen" palette.png
ffmpeg -y -i motion.mov -i palette.png \
  -lavfi "fps=15,scale=720:-1:flags=lanczos,paletteuse" -loop 0 motion.gif
```

`-d` はフレーム間隔 (ミリ秒。15fps なら 67)。

**非可逆にはしない。** `-mixed` (フレームごとに可逆 / 非可逆を選ばせる指定) を付けると、この絵では
90 フレーム全部が非可逆側へ倒れ、**淡い階調が丸ごと潰れて 16px の段差に置き換わる** — 絵は正しく
描けているのに、貼られたものを見ると壊れているように見える
([#369](https://github.com/mokume-metal/mokume/issues/369) で実測。誤差は最大 84 階調、画素の 18% が
4 階調以上ずれ、フレームを追うごとに悪化した)。証跡は「元の絵に無いものが足されていないこと」に
価値がある。

**4MB を目安に収める。** GitHub は貼られた画像を camo 経由で出すので、詰まるのは Gyazo (40MB) では
なく必ずこちらである。5,242,880 バイトを超えると `Content length exceeded` で 404 になり、**その手前でも
大きいと途中で切られる** — 4.6MB のものが 3.4MB で打ち切られ、それが `x-cache: HIT` のまま
`max-age=31536000` (1 年) で焼き付いた ([#369](https://github.com/mokume-metal/mokume/issues/369) で実測)。
壊れた側を引くかはエッジ次第なので、**貼った本人には正しく見えることがある**。実測では 3.7MB は 8 回とも
無事で、4.6MB が壊れた。

超えたときは**可逆の枠内で落とす** — `-near_lossless` は可逆圧縮の中で値を丸めるだけなので、段差が出ない:

```bash
img2webp -loop 0 -near_lossless 60 -d 67 frames/f.*.png -o motion.webp   # 最大誤差 2 階調
img2webp -loop 0 -near_lossless 40 -d 67 frames/f.*.png -o motion.webp   # 最大誤差 4 階調
```

それでも収まらないなら**短くする / 小さくする**。`-mixed` へ戻る段は作らない — 情報が減るのと、
元に無いものが足されるのは別である。

**A は `-d` を採った間隔から 1 枚ずつ決める** (`-d` はファイルごとに効く)。等間隔で束ねてはいけない理由は
経路 A の注意書きのとおり。

```bash
python3 - frames motion.webp <<'BUNDLE'
import json, pathlib, subprocess, sys

out = pathlib.Path(sys.argv[1])
rows = json.loads((out / "timing.json").read_text())
arguments = ["img2webp", "-loop", "0"]   # 既定が可逆。-mixed は付けない (下記)
for current, following in zip(rows, rows[1:]):
    gap = max(1, round((following["at"] - current["at"]) * 1000))
    arguments += ["-d", str(gap), str(out / current["file"])]
subprocess.run(arguments + ["-d", "100", str(out / rows[-1]["file"]), "-o", sys.argv[2]], check=True)
BUNDLE
```

## 上げる

トークンは **`MOKUME_GYAZO_TOKEN_CMD`** に「トークンを標準出力に出すコマンド」を渡して読む。
App の秘密鍵 (AGENTS.md 「エージェントの identity」) と同じ流儀で、**値も在処もリポジトリに書かない**。

```bash
GYAZO_TOKEN="$(eval "$MOKUME_GYAZO_TOKEN_CMD")" && curl -s \
  -F "access_token=${GYAZO_TOKEN}" \
  -F "imagedata=@motion.webp" \
  -F "title=<人が読む一言>" \
  -F "desc=<desc.txt" \
  -F "app=mokume" \
  -F "referer_url=https://github.com/mokume-metal/mokume/pull/<N>" \
  -F "metadata_is_public=true" \
  https://upload.gyazo.com/api/upload
```

**代入から始めて `&&` で繋ぐ。** `export GYAZO_TOKEN="$(...)"` と書くと終了コードが `export` のもの (0) に
化け、読み出しに失敗しても後続が走る。

返る `url` (`https://i.gyazo.com/<id>.webp`) をそのまま貼る。

`desc` に書くのは **画像だけ見て疑問に思うこと**に絞る。観測の応答と git から組み立て、手で書かない。

```
mokume <版> / stamp <刻印>
sketch: <リポジトリ相対パス> @ <SHA>
frame 128 (2.13s) / 800x600 / 59.9fps
```

`metadata_is_public=true` で**公開される**ので、載せるのはリポジトリ相対パス・SHA・版に限る。
手元の絶対パスやマシン名は入れない。

## 貼る

**コードは Gyazo ではなく GitHub 側に持つ。** `desc` は後から直せず、貼った画像からも読めないためである
(Gyazo 側に置くのは、画像から離れず・直す必要が生じない事実だけ)。

- リポジトリにあるコードは **行範囲つきの恒久リンクで指す** — 写さないので長さの問題が起きない
- 証跡のための使い捨てスケッチだけ `<details>` に全文を入れる。**1 ファイルに収める** — 収まらないなら、
  それは使い捨てではなくリポジトリに入れるべきものである

before / after は表で並べ、**幅を宣言する**。

```markdown
| before (main) | after (this PR) |
| --- | --- |
| <img src="https://i.gyazo.com/<id>.png" width="480"> | <img src="https://i.gyazo.com/<id>.png" width="480"> |
```

**素の `![]()` で並べると大きさが揃わない。** 表の列幅は中身の自然幅から比例配分されるので、原寸の差が
そのまま表示の大小になる — 静止画は観測が返した解像度をそのまま上げるのに対し、動きは `scale=720:-1` で
幅が固定されるため、静止画と動きを並べた表では**動きだけが小さく出る**
([#371](https://github.com/mokume-metal/mokume/issues/371)。[#364](https://github.com/mokume-metal/mokume/pull/364) が
960px と 720px で並んでいた)。同じ `width` を両方へ書けば揃い、GitHub は `width` を残したうえで
`max-width: 100%` を付けるので、画面が狭いときも同じ割合で縮む。

**揃えるのは幅の側で、書き出しの側ではない。** 静止画の解像度はスケッチごとに変わるので、`scale` を
それに合わせると撮るたびの作業になり、幅を上げるとファイルも太る。

静止画と動きを並べる表も同じ書き方でよい (アスペクト比が同じなら高さも揃う)。**単独で貼る絵は原寸の
ままでよい** — 幅を書くのは並べるときだけである。

**動きには撮影範囲と意図をテキストで添える。** フレームを人が後から検める代わりの記録なので、
何を撮ったか (A なら観測したスケッチと条件・B ならどの窓)・どの操作の何秒間か・どこを見てほしいかを書く。

**貼ったら camo 側を検算する。** 上のとおり camo は大きいものを途中で切ることがあり、切れた側が
キャッシュに焼かれる。**Gyazo の URL を直接叩いても気付けない** (あちらは無事なので) ので、貼った本文から
camo URL を取り、何度か叩いて**原本と同じ長さが返るか**を見る:

```bash
gh api repos/mokume-metal/mokume/pulls/<N> -H 'Accept: application/vnd.github.html+json' --jq .body_html \
  | grep -oE 'https://camo\.githubusercontent\.com/[a-f0-9]+/[a-f0-9]+' | sort -u \
  | while read -r u; do
      for _ in 1 2 3; do curl -sS -o /dev/null -w "%{size_download} " "$u"; done; echo " $u"
    done
```

長さが原本と違ったら、**上げ直して URL を変える**しかない (camo のキャッシュは消せない)。同じ絵を
上げ直しても同一バイトなら Gyazo が同じ id を返すので、**先に小さくしてから上げる**。

**貼った直後は camo URL が取れない。** `body_html` は少しの間 camo 化前を返すので、すぐ叩くと
「camo URL が 1 つも無い」で素通りしてしまう ([#374](https://github.com/mokume-metal/mokume/issues/374)
で実測。20 秒ほどで書き換わった)。**取れた URL の数が貼った絵の数と合っているか**を先に見る。

## 守ること

- **上げることは外部サービスへの送信である。** 送る前に写り込み (他アプリ・通知・手元のパス・秘密) を
  確かめる。判断がつかなければ聞く
- **動きのフレームは読み込んで検めない** — 全フレームの画像読み込みは高くつき、写り込みの確率に
  見合わない。代わりに上の「撮影範囲と意図」を書く。後から見つかったときは消す (下記)
- 証跡はリポジトリにコミットしない (`scripts/check-no-binaries.sh` が弾く)

## うまくいかないとき

- **同じ絵を上げ直したのにメタデータが変わらない** — 同一バイトの画像には既存の id が返り、
  メタデータは更新されない。決定論で撮り直して絵が同じなら、新しい `desc` は無視される
- **`desc` が自分にしか見えない** — `metadata_is_public=true` が要る。付けないと第三者からは読めない
- **`desc` を間違えた** — 後からは直せない。消して上げ直すことになり、URL が変わって貼った先が壊れる。
  貼る前に読み返す
- **写り込みに後から気付いた / 消したい**

  ```bash
  GYAZO_TOKEN="$(eval "$MOKUME_GYAZO_TOKEN_CMD")" && curl -s -X DELETE \
    -H "Authorization: Bearer ${GYAZO_TOKEN}" https://api.gyazo.com/api/images/<image_id>
  ```

  permalink が 404 になる。**貼った先の画像も消えるので、貼り直しまで面倒を見る**
- **mp4 を貼りたい** — 経路が無い。アップロード API が受け付けず、埋め込んでも展開されない。参照の面を
  作る道具の側は `@Video` で mp4 を扱える (実測) が、**置き場が無いので使えない**。動きは
  WebP (PR / Issue) か GIF (参照の面) にする
- **貼った絵が表示されない / 途中までしか動かない** — camo で詰まっている。5MB 超なら 404
  (`Content length exceeded`)、その手前なら途中切断が焼き付いている。**Gyazo 側は生きているので、URL を
  直接叩くと取れてしまい気付きにくい** — 「貼る」節の検算で camo 側の長さを見る。直すには小さくして
  上げ直す (URL が変わるので貼り直しまで面倒を見る)
- **貼った動きに 16px の四角い段差が見える / 淡い階調が消えている** — `-mixed` か `-lossy` で束ねている。
  可逆で束ね直す ([#369](https://github.com/mokume-metal/mokume/issues/369))
- **観測が「走っているスケッチが応えませんでした」と返る** — 案内が**区画をこの呼び出しで作った**と言って
  いれば、区画を起動より後に作っている (A の順序を見る)。区画はもう在るので、**起動し直すだけ**でよい。
  案内が**区画は要求を置く前から在った**と言っていれば順序の問題ではなく、そもそも走っていない
- **窓の一覧に目的の窓が出ない** — 一覧が返すのは**いま画面に出ている窓**である。背面で起動した
  (`nohup` 等) スケッチや、最小化・別の Space にある窓は出てこない。前に出してから取り直す
- **窓の一覧が空 / 撮れない** — 画面収録の許可が要る。**付与は GUI 操作なので代行せず頼む**
- **`unauthorized`** — トークンを作り直す (https://gyazo.com/oauth/applications)。OAuth フローは要らず、
  developer ページで出せる 1 本でよい

## 前提

- `img2webp` (`brew install webp`) と `ffmpeg`
- **Gyazo のアクセストークン。** https://gyazo.com/oauth/applications でアプリを登録すると出せる
  (OAuth フローは要らず、developer ページで出せる 1 本でよい)。環境変数 **`MOKUME_GYAZO_TOKEN_CMD`** へ
  「トークンを標準出力に出すコマンド」を渡し、手元の秘密管理から読ませる — 値そのものを環境変数に置かない
- 窓の一覧には Gyazo の MCP サーバーが要る (開発者向けプレビュー版・公式サポート対象外で、
  仕様が変わることがある)
