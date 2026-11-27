<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# 同じ時刻で、`@Param` の値を変えたフレームを並べる

雲の密度・光の強さ・レイマーチングのステップ数のように、映像への寄与が独立した `@Param` を 1 つずつ変え、同じ時刻の絵を並べて見比べる手順です ([#4135](https://github.com/mokume-metal/mokume/issues/4135))。**新しいコマンドや MCP ツールは使いません。** 動いているスケッチの `.mokume/params` (値の書き込み) と `.mokume/observe` (撮影) を組み合わせるだけで足ります。複数の条件を 1 度に受け付ける機能は持たない、と決めています (比較や差分の機能を CLI に足さない方針は [#1923](https://github.com/mokume-metal/mokume/issues/1923))。

## この手順が前提にすること

4 枚が「同じ状態から撮れた」と言えるのは、次が揃ったときだけです。

| 揃えるもの | どう揃えるか |
| --- | --- |
| 時刻 | `observe` の `time` に同じ秒数を渡す。その 1 フレームを `deltaTime` 0 で描き直す |
| `@Param` の値 | 3 つ以上あるなら**毎回すべて書く**。変えない値も書き、前の条件の値を引きずらない |
| 画面の大きさ・解像度 | 同じスケッチのまま撮る (`settings` の大きさ。`scale` を変えない) |
| 乱数・状態 | 絵が `time` と `@Param` だけの関数であることを前提にする (下) |

**前提を満たさないスケッチがある。** `time` を同じにしても、描くたびに状態を積み上げるスケッチ (`deltaTime` を足し込んだ風の変位、フレーム間で持ち越す乱数の状態、入力で動く値) は、同じ内部状態になりません。次の「実測」で、`deltaTime` を足し込む 1 行を入れたスケッチは、**同じ条件・同じ `time` で撮り直すだけで絵が変わる**ことを確かめています。

- 位置や色を `time` と `@Param` から直接計算できるなら、この手順で足ります。スケッチの側で積算をやめるか、`time` から式で求める形にしてください
- 積み上げる状態が避けられないときは、フレームの時計 (`clock: .frames`) で走らせ、`mokume run --record` / `mokume watch --record` で記録し、`mokume replay` で再生します。再生は記録した入力・`@Param` の書き込み・時計を同じフレームへ入れ直し、記録した値と絵 (60 フレームごとと最後) に一致するかを調べます。**この手順は replay を使っていません。** 記録した 1 回の走行を再現するもので、同じ履歴のまま `@Param` だけ別の値にした 4 本を 1 回の記録から作る機能は、確かめていません。揃えられないスケッチは、揃っていないものとして並べ、そう書いてください

## 手順

### 1. 区画を作ってから起動する

`.mokume/observe` と `.mokume/params` は、スケッチが起動した瞬間にディレクトリがあるときだけ働きます。後から作ると、起動し直すまで届きません。

```bash
mkdir -p <スケッチ>/.mokume/observe <スケッチ>/.mokume/params
mokume watch <スケッチ>
```

### 2. 値を宣言するスケッチ

3 つの `@Param` を宣言した最小のスケッチです。位置は `time` だけの関数にしています。

```swift
import mokume

@main
final class Compare: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 480, height: 270, title: "compare")
    }

    /// 円の数・色相 (度)・円ごとの輪の数。
    @Param(1...12) var circles: Int = 6
    @Param(0...360) var hue: Double = 20
    @Param(1...8) var rings: Int = 3

    func draw() {
        background(15, 18, 23)
        noFill()
        strokeWeight(2)
        // 位置は time だけの関数にする (deltaTime で積算しない)
        let angle = time * 0.8
        for index in 0..<circles {
            let phase = angle + Float(index) / Float(circles) * 2 * Float.pi
            let x = width / 2 + cos(phase) * 160
            let y = height / 2 + sin(phase) * 80
            for ring in 1...rings {
                stroke(color(hue: Float(hue), saturation: 80, brightness: 95))
                circle(x, y, Float(ring) * 14)
            }
        }
    }
}
```

### 3. 条件ごとに「値を書く → 撮る → 絵と条件を退避する」

次のスクリプトは、4 条件 (基準・円を減らす・色を変える・輪を減らす) を同じ `time` で 1 枚ずつ撮ります。

- 値の書き込みは `.mokume/params/request.json` に置き、`report.json` が自分の `id` を返すまで待つ (形式は [Schemas/params-request.schema.json](https://github.com/mokume-metal/mokume/blob/main/Schemas/params-request.schema.json))
- 撮影は `.mokume/observe/request.json` に `time` と `keep: true` を置く (形式は [Schemas/observe-request.schema.json](https://github.com/mokume-metal/mokume/blob/main/Schemas/observe-request.schema.json))。`keep` した絵は `.mokume/kept/<id>/` に残り、次の観測で消えない。同じ場所の `kept.json` に、絵の時刻・フレーム番号・**描き終えた時点の `@Param` の値**が載る。条件と絵の対応はこれで取る (MCP の `observe` は `keep` を受け取らず、`@Param` の値も返さないので、対応を取るには `expose` で差し出す手間が増える)
- `id` は毎回変える。答えた `id` は処理し直されない
- 書き込みは保存値 (`.mokume/state/params.json`) を書き換えるので、`finally` で元の値へ戻す

```python
#!/usr/bin/env python3
"""4 条件を、同じ time で 1 枚ずつ撮って並べる。使い方: compare.py <スケッチ> <出力先> <time>"""
import json
import os
import shutil
import sys
import time as clock

sketch, out, at = sys.argv[1], sys.argv[2], float(sys.argv[3])
facet = os.path.join(sketch, ".mokume")
os.makedirs(out, exist_ok=True)

# 条件名 → 3 つの値。毎回すべての値を書く (前の条件の値を引きずらない)
base = {"circles": 6, "hue": 20.0, "rings": 3}
conditions = {
    "base": {},
    "fewer-circles": {"circles": 2},
    "other-hue": {"hue": 200.0},
    "fewer-rings": {"rings": 1},
}


def place(directory, name, body):
    """一時ファイルへ書いてから rename で置く (書き込みの途中を読ませない)"""
    tmp = os.path.join(directory, f".{name}.tmp")
    with open(tmp, "w") as handle:
        json.dump(body, handle)
    os.replace(tmp, os.path.join(directory, name))


def answered(directory, request_id):
    """report.json が自分の id を返すまで待つ。待つ側が期限を持つ"""
    deadline = clock.monotonic() + 20
    path = os.path.join(directory, "report.json")
    while clock.monotonic() < deadline:
        try:
            with open(path) as handle:
                report = json.load(handle)
            if report.get("id") == request_id:
                return report
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        clock.sleep(0.1)
    sys.exit(f"{request_id}: 応答が来ない ({directory})")


def write_params(values, request_id):
    entries = [{"name": k, "type": "int" if isinstance(v, int) else "float", "value": v}
               for k, v in values.items()]
    place(os.path.join(facet, "params"), "request.json", {"id": request_id, "values": entries})
    report = answered(os.path.join(facet, "params"), request_id)
    # 断られた値・範囲へ丸められた値があれば、その条件は「書いた値」ではない
    assert not report["rejected"] and not report["clamped"], report


rows = []
run = os.getpid()  # id は毎回変える (答えた id は再処理されない)
try:
    for index, (label, change) in enumerate(conditions.items()):
        values = {**base, **change}
        write_params(values, f"cmp-{run}-{index}-p")

        observe_id = f"cmp-{run}-{index}-o"
        place(os.path.join(facet, "observe"), "request.json",
              {"id": observe_id, "time": at, "keep": True})
        answered(os.path.join(facet, "observe"), observe_id)
        # keep した絵は .mokume/kept/<id>/ に残り、次の観測で消えない。kept.json に絵の時刻と
        # 描き終えた時点の @Param の値が載るので、条件と絵の対応はこれで取る
        kept = os.path.join(facet, "kept", observe_id)
        with open(os.path.join(kept, "kept.json")) as handle:
            catalogue = json.load(handle)
        shutil.copy(os.path.join(kept, catalogue["image"]), os.path.join(out, f"{label}.png"))
        rows.append({"condition": label, "asked": values, "params": catalogue["params"],
                     "time": catalogue["time"], "frame": catalogue["frame"],
                     "stamp": catalogue["stamp"], "image": f"{label}.png"})
finally:
    # @Param の書き込みは保存値 (.mokume/state/params.json) を書き換える。途中で落ちても元へ戻す
    write_params(base, f"cmp-{run}-restore")

with open(os.path.join(out, "conditions.json"), "w") as handle:
    json.dump(rows, handle, indent=2, ensure_ascii=False)
for row in rows:
    print(row["condition"], row["asked"], "time", row["time"], "frame", row["frame"], row["image"])
```

```bash
python3 compare.py <スケッチ> out 2.0
```

`out/` に条件名の PNG と、条件名・入力値・時刻・フレーム番号・`stamp` を並べた `conditions.json` ができます。

### 4. 並べる・差を見る

並べる・差を出すのは mokume の外のツールの仕事です。ImageMagick なら次のとおりです。

```bash
montage -label '%t' out/base.png out/fewer-circles.png out/other-hue.png out/fewer-rings.png \
  -tile 2x2 -geometry +6+6 -background '#202020' -fill white grid.png
compare -metric AE out/base.png out/other-hue.png diff-other-hue.png   # 基準との差の画素数
```

同じ手順をもう 1 度回し、条件ごとに `compare -metric AE` が 0 になれば、絵が `time` と `@Param` だけで決まっている (前提を満たしている) ことの確認になります。

## 決めていないこと

- 5 本以上の条件、差分の自動表示、条件の履歴を扱う機能は作りません。必要になったら、この手順のどこで手間が増えたかを添えて Issue で提案してください
- 並べる絵のメタデータ (条件名・入力値) は `conditions.json` に残るだけで、画像ファイルには埋め込みません
