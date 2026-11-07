#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""説明文の中の例が、実際にコンパイルできることを見る (#479)。

説明文は**参照の面と公開 API の一覧の両方を養う**ので、ここが腐ると下流が全部腐る。
そして腐った例は説明が無いより悪い — 読者はそれを写して、通らない理由を自分の側に
探す。実際に `loadModel` の例は Processing 由来の `millis()` を呼んでいて、**そんな口は
無い**。カタログの最初のページの例も通らなかった ([#556](https://github.com/mokume-metal/mokume/issues/556))。

## 何を見るか

`Sources/**/*.swift` の `///` と、カタログ (`Documentation/mokume.docc/*.md`) の中の
```swift の塊を全部集め、1 つのファイルへ包んで `swiftc -typecheck` に掛ける。
包み方は `example_wrapping.py` が持ち、**撮る側 (`example-shots.py`) と同じ規則**である。

**組み直さない。** `swift build` が作った成果物 (`.build/debug/Modules`) へ直接当てる
ので、パッケージを 2 つ目に作って CI の時間を倍にしなくて済む。だから `make build` の
後に置く必要がある (`make examples` が順序を持つ)。SwiftPM を通さない代償として、
macro の plugin だけは手で繋ぐ (`plugin_flags`)。

## 印

既定は「印なし = 組む」。**印は例外の側に付く** — 逆にすると、新しく書かれた例は
既定で誰にも見られないまま入り、それは印を忘れた人には見分けが付かない。

    /// <!-- example: 文脈 var dust: Particles! -->
    /// ```swift
    /// emit(dust, from: .point(width / 2, 40), rate: 600, life: 1...2.5)
    /// ```

    /// <!-- example: 組めない VideoSender は外のパッケージが持つ (このリポジトリには無い) -->

- `文脈` — その例が前提にしているものの宣言。囲みの直前に何行でも積める。**面には
  出ない** (`<!-- -->` は docc の出力に残らない)。読者向けの説明は本文が持つ
- `組めない` — 組み立てない。**理由は必須**。空の印は「見ていないこと」を隠すので赤にする
- `資材` — 直後の ```` ```metal ```` の囲みを、例が読む `assets/` の下の 1 本の本文として名乗る
  (#3836)。直後に続く ```` ```swift ```` の例に結ばれ、`mokume new --from` がその例と一緒に写す。
  名前は `assets/` の下の `.metal` に限り、結ばれた例が `"assets/…"` としてその名前を読んでいなければ
  赤にする。**本文を Metal として組むことはしない** — 値の宣言 (`struct Values`) は Swift の側の
  `values:` から作られ、ここで写すと Swift を読む脆い写しになる (#3836 の判断 3)

    /// <!-- example: 資材 assets/waves.metal -->
    /// ```metal
    /// float4 paint(Fragment in, Values values) { … }
    /// ```
    /// ```swift
    /// waves = try loadShader("assets/waves.metal")
    /// ```

印は囲みの**直前**に置く。離して置いたものは取り違えようがあるので、行き先の無い印は
赤にする。

## 見ていない範囲

- **例が動くことは見ない。** 型検査までで、走らせて絵にするのは `make example-shots`
  (GPU と鍵が要るので手元だけ)
- **型検査の警告は落とさない** (使われない値など)。例は断片なので、そこを揃えると
  読みにくい書き方を強いることになる
- `README.md` / `Documentation/site/` / `docs/` の例は見ない。説明文ではないので、
  ここへ足すのは実害が出てからにする ([ADR-0008](../docs/decisions/0008-mechanism-needs-demonstrated-harm.md))
- `組めない` と宣言されたもの。**何本をどこで外したかは毎回出力が挙げる**
- `資材` の本文が Metal として組めること (上の印の注記)
"""

from __future__ import annotations

import argparse
import bisect
import dataclasses
import pathlib
import re
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

# **囲みと印の綴りも example_wrapping から取る** (#815)。撮る側 (example-shots.py) と
# 同じものを読まないと、組める例と撮れる例が食い違う (#667)
# 型検査の呼び方は swift_typecheck が持つ (#820)。**片方だけが macro の plugin 名を
# 動的に解いている状態**を畳んだ — check-param-declarations.sh も同じ呼び方を通る
from swift_typecheck import typecheck  # noqa: E402

from example_wrapping import (  # noqa: E402
    ASSET_FENCE_OPEN,
    FENCE_CLOSE,
    FENCE_OPEN,
    MARK,
    MARK_ASSET,
    MARK_CONTEXT,
    MARK_SKIP,
    dedent,
    file_imports,
    strip_doc,
    wrap,
)

# 印を名乗りかけて綴りを外したもの。黙って素通しにすると「書いたのに効かない」になる。
# **これを読むのはこちらだけ** — 撮る側は綴りを外した印を「印ではない」と読んで素通しする
MARK_LOOSE = re.compile(r"^\s*(?:///\s*)?<!--\s*example:")

CATALOG = "Documentation/mokume.docc"
GENERATED = pathlib.Path(".build") / "example-check" / "examples.swift"


@dataclasses.dataclass
class Example:
    path: pathlib.Path  # 根からの相対
    line: int  # ```swift の行 (1 起点)
    body: list[str]
    context: list[str]
    skip: str | None  # 組めない理由
    # 例が読む `assets/` の下の本文 (`資材` の印)。(名前, 本文) の並びで、名前は `assets/` から書く
    assets: list[tuple[str, str]] = dataclasses.field(default_factory=list)

    @property
    def where(self) -> str:
        return f"{self.path}:{self.line}"


ASSET_DIRECTORY = "assets/"
ASSET_SUFFIX = ".metal"


def asset_name_problem(name: str) -> str | None:
    """`資材` の名前が写せる形でないときの理由。**写す先は利用者のパッケージの中** なので、
    `assets/` の外へ出る名前 (`..`・絶対パス) を通さない。"""
    parts = name.split("/")
    if not name.startswith(ASSET_DIRECTORY) or not name.endswith(ASSET_SUFFIX):
        return f"`{ASSET_DIRECTORY}` の下の `{ASSET_SUFFIX}` でなければならない"
    if any(part in ("", ".", "..") for part in parts[1:]):
        return "空・`.`・`..` の区切りを含む"
    return None


def sources(root: pathlib.Path) -> list[pathlib.Path]:
    """見るファイル。基準は「**`git add -A` したときに CI の木になるもの**」 —
    追跡されているもの + 追跡されていないもの − 無視されたもの。

    最初の設計 (#566) は追跡されたものだけだったが、それだと `git add` 前の手元で緑
    だった例が、push して初めて CI で赤になる (#1998)。無視されたもの (生成物や手元の
    書き捨て) は CI の木に入らないので、引き続き拾わない — 拾うと、他人の手元で結果が
    変わる。

    **挙がったパスが、実在するファイルとは限らない。** `git rm` していない削除・改名は
    index に旧パスが残り、エディタの退避リンク (`.#Foo.swift`) は先が無いまま未追跡で
    残る。どちらも `git add -A` の後の木には現れないので、読む前に落とす。名前は `-z` で
    割る (空白を含む名前は割れ、非 ASCII の名前は C 引用符つきで返って `.swift` の判定
    を黙って外れる)。"""
    listed = subprocess.run(
        [
            "git",
            "-C",
            str(root),
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
            "Sources",
            CATALOG,
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split("\0")
    return [
        pathlib.Path(name)
        for name in listed
        if name.endswith((".swift", ".md")) and (root / name).is_file()
    ]


def examples_in(text: str, path: pathlib.Path) -> tuple[list[Example], list[str]]:
    """1 ファイルぶんの例と、行き先の無い印。"""
    lines = text.split("\n")
    found: list[Example] = []
    problems: list[str] = []
    pending: list[tuple[str, str, int]] = []  # (種類, 中身, 行)
    assets: list[tuple[str, str, int]] = []  # (名前, 本文, 行) — 次の ```swift に結ぶ
    nowhere = "印の行き先が無い (直後は ```swift でなければならない)"
    index = 0
    while index < len(lines):
        line = lines[index]
        match = MARK.match(line)
        if match and match["kind"] == MARK_ASSET:
            name = (match["rest"] or "").strip()
            following = lines[index + 1] if index + 1 < len(lines) else ""
            if not ASSET_FENCE_OPEN.match(following):
                problems.append(f"{path}:{index + 1} 印 `資材` の直後は ```metal の囲みでなければならない")
                index += 1
                continue
            close = index + 2
            body: list[str] = []
            while close < len(lines) and not FENCE_CLOSE.match(lines[close]):
                body.append(strip_doc(lines[close]))
                close += 1
            reason = "名前が書かれていない" if not name else asset_name_problem(name)
            if reason:
                problems.append(f"{path}:{index + 1} 印 `資材` の名前 `{name}` は{reason}")
            elif any(name == other for other, _, _ in assets):
                problems.append(f"{path}:{index + 1} 印 `資材` の名前 `{name}` が同じ例に 2 本ある")
            else:
                assets.append((name, "\n".join(dedent(body)).rstrip("\n") + "\n", index + 1))
            index = close + 1
            continue
        if match:
            rest = (match["rest"] or "").strip()
            if not rest:
                kind = match["kind"]
                need = "宣言" if kind == MARK_CONTEXT else "理由"
                problems.append(f"{path}:{index + 1} 印 `{kind}` に{need}が書かれていない")
            pending.append((match["kind"], rest, index + 1))
            index += 1
            continue
        if MARK_LOOSE.match(line):
            problems.append(f"{path}:{index + 1} 印の綴りが違う (使えるのは 文脈 / 組めない / 資材)")
            index += 1
            continue
        if FENCE_OPEN.match(line):
            close = index + 1
            body = []
            while close < len(lines) and not FENCE_CLOSE.match(lines[close]):
                body.append(strip_doc(lines[close]))
                close += 1
            skip = next((rest for kind, rest, _ in pending if kind == MARK_SKIP), None)
            example = Example(
                path=path,
                line=index + 1,
                body=dedent(body),
                context=[rest for kind, rest, _ in pending if kind == MARK_CONTEXT],
                skip=skip,
                assets=[(name, contents) for name, contents, _ in assets],
            )
            # **例が読んでいない資材は赤にする** — 名前を打ち違えると、写した先で例が読む名前が無い
            source = "\n".join(example.body + example.context)
            for name, _, at in assets:
                if f'"{name}"' not in source:
                    problems.append(f"{path}:{at} 資材 `{name}` を直後の例が読んでいない")
            found.append(example)
            pending = []
            assets = []
            index = close + 1
            continue
        problems += [f"{path}:{at} {nowhere}" for _, _, at in pending + assets]
        pending = []
        assets = []
        index += 1
    problems += [f"{path}:{at} {nowhere}" for _, _, at in pending + assets]
    return found, problems


def collect(root: pathlib.Path) -> tuple[list[Example], list[str]]:
    found: list[Example] = []
    problems: list[str] = []
    for path in sources(root):
        text = (root / path).read_text(encoding="utf-8")
        if "```swift" not in text and "example:" not in text:
            continue
        part, trouble = examples_in(text, path)
        found += part
        problems += trouble
    return found, problems


def build_source(examples: list[Example]) -> tuple[str, list[int], list[Example]]:
    """全部を 1 つのファイルへ。返るのは 本文 / 各例の始まる行 / その例。"""
    # 例が自分で書いている import も集める。型の中へは入れられないので、
    # ここでファイルの先頭へ上げる。**集め方は撮る側と共有する** (file_imports の注記・#2216)
    lines = [
        "// 生成物 — 直接編集しない (scripts/check-examples.py が書く)。",
        *file_imports(example.body for example in examples),
        "",
    ]
    starts: list[int] = []
    ordered: list[Example] = []
    for number, example in enumerate(examples):
        starts.append(len(lines) + 1)
        ordered.append(example)
        lines.append(f"// {example.where}")
        lines += wrap(f"Example{number:03d}", example.body, context=example.context)
        lines.append("")
    return "\n".join(lines) + "\n", starts, ordered


def find_modules(binary: pathlib.Path) -> pathlib.Path:
    """成果物の置き場から、swiftmodule の在処を選ぶ。

    **道具立ての版で場所が違う。** Swift 6.3 までは `<置き場>/Modules/` に並んでいたが、
    Swift 6.4 の既定のビルドシステムは置き場そのものへ並べる
    ([#1276](https://github.com/mokume-metal/mokume/issues/1276))。両方を見て、
    在るほうを使う — 版を名指しで分けると、次に変わった日にまた書き足すことになる。
    """
    for candidate in (binary / "Modules", binary):
        if (candidate / "mokume.swiftmodule").exists():
            return candidate
    # 見つからないときは、いままでどおりの場所を名乗って落ちる (案内が具体的になる)
    return binary / "Modules"


def main() -> int:
    argparse.ArgumentParser(description="説明文の中の例が組めるかを見る").parse_args()

    root = pathlib.Path(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
        ).stdout.strip()
    )
    modules = find_modules(root / ".build" / "debug")
    if not (modules / "mokume.swiftmodule").exists():
        print(f"ng: {modules} に mokume が無い — 先に swift build (make build) を打つ")
        return 1

    examples, problems = collect(root)
    usable = [example for example in examples if example.skip is None]
    skipped = [example for example in examples if example.skip is not None]

    source, starts, ordered = build_source(usable)
    generated = root / GENERATED
    generated.parent.mkdir(parents=True, exist_ok=True)
    generated.write_text(source, encoding="utf-8")

    failures: dict[str, list[str]] = {}
    for line, complaint in typecheck(generated, modules):
        index = bisect.bisect_right(starts, line) - 1
        where = ordered[index].where if index >= 0 else str(GENERATED)
        failures.setdefault(where, []).append(complaint)

    print(f"例 {len(examples)} 本 — 組んだ {len(usable)} / 組めないと宣言 {len(skipped)}")
    for where, complaints in failures.items():
        print(f"  ng {where}")
        for complaint in dict.fromkeys(complaints):
            print(f"       {complaint}")
    for trouble in problems:
        print(f"  ng {trouble}")

    print("見ていない範囲:")
    print("  - 例が動くこと (型検査まで。走らせて絵にするのは make example-shots)")
    print("  - 型検査の警告 (使われない値など) — 断片なので落とさない")
    print("  - README.md / Documentation/site/ / docs/ の例 (説明文ではない)")
    attached = sum(len(example.assets) for example in examples)
    if attached:
        print(f"  - 例に添えた資材 {attached} 本の本文が Metal として組めること (印の綴りと行き先だけを見る)")
    if skipped:
        print(f"  - 「組めない」と宣言された {len(skipped)} 本:")
        for example in skipped:
            print(f"       {example.where} — {example.skip}")

    if failures or problems:
        print(f"組み立てたものは {GENERATED} にある")
        return 1
    print("ok: 説明文の中の例はすべて組める")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
