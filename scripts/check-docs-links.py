#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""追跡下の Markdown の相対リンクと見出しアンカーを検査する (#90)。

**外部 URL は見ない。** ネットワーク依存と flaky を CI に持ち込まないためで、
外部ホスティングに置いた画像の死活は別の問題になる (#90 が対象外と明記)。

**対象は `git ls-files '*.md'` 全部で、除外リストを持たない。** 除外を書けば
検査は名指しに戻り、次に `.md` が増えたときに同じ穴が空く
(scripts/check-workflows.sh が包む側に倒しているのと同じ理由)。

**コード塊の中は見ない。** 規範文書はコマンド例を大量に含み、その中の
`![]()` のような**書き方の例示**まで拾うと、直しようのない赤が出る
(実際に .claude/skills/gyazo-evidence/SKILL.md に 1 件ある)。フェンスと
インラインコードの両方を、リンクを探す前に空白へ潰しておく — 行と桁は
保つので、そのまま数えた行番号が元のファイルの行番号になる。

**アンカーの一致は緩く採る。** GitHub がアンカーに振る綴りの規則
(github-slugger) は公表された仕様ではなく、日本語の約物の扱いまで手元で
確かめる術が無い。厳密に比べると、こちらの綴りがずれていたときに
**GitHub では動くリンクを赤にし、動かない綴りへ直させる**ことになる — 検査が
壊れているのに、直した人は壊れたリンクを持たされる。そこで比較の前に
両側から約物と `-` を落とし、**「その見出しが在るか」だけを見る**。綴り違いは
見逃すが、この検査が塞ぎたいのは指し先の不在なので責務としては足りる。

一致しなかったときは対象ファイルの見出しアンカーを並べて出す。このリポジトリに
アンカー付きリンクは 1 本も無い (#90 のトリアージが 3 度実測した) ので、最初に
踏んだ人が出力だけで書き直せる形にしておく。
"""

import re
import subprocess
import sys
from pathlib import Path

# 見出しから slug を作るときに落とす約物。github-slugger に倣うが、上の
# とおり最終的な比較は緩く行うので、ここは「並べて見せる綴り」を決めるだけ
PUNCTUATION = re.compile(
    r"[ -⁯⸀-⹿ \\'!\"#$%&()*+,./:;<=>?@\[\]^`{|}~]"
)

# 見出しの中のリンクと HTML。GitHub は描画してからテキストを取るので、
# `[文字](URL)` はアンカーに文字だけを残す。`**強調**` や `` `コード` `` の記号は
# PUNCTUATION が落とすので、ここで重ねて書かない
HEADING_LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")
HTML_TAG = re.compile(r"<[^>]+>")

ATX_HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")

# インラインの [text](target) と ![alt](target)。target に括弧を含む URL は
# 相対リンクとしては現れないので、単純な形だけを見る
INLINE_LINK = re.compile(r"!?\[[^\]]*\]\(\s*<?([^)>\s]*)>?(?:\s+[\"'][^\"']*[\"'])?\s*\)")

# 参照リンクの定義 ([ref]: target) と利用 ([text][ref] / [ref][])
REF_DEFINITION = re.compile(r"^ {0,3}\[([^\]]+)\]:\s*<?([^>\s]+)>?", re.MULTILINE)
REF_USE = re.compile(r"!?\[([^\]]*)\]\[([^\]]*)\]")

EXTERNAL = ("http://", "https://", "mailto:", "tel:", "ftp://")

FENCE = re.compile(r"^\s{0,3}(`{3,}|~{3,})")
INLINE_CODE = re.compile(r"(`+)(?:.*?)\1", re.DOTALL)

# 緩い比較のための正規化。文字と数字だけを残す。`_` も落とす — GitHub は
# アンカーに残すが、`__強調__` のように記法として書かれた `_` は残らないので、
# どちらで書かれたかを手元で判定しない
LOOSE = re.compile(r"[\W_]", re.UNICODE)


def _blank(text: str) -> str:
    """改行だけ残して空白へ潰す (行番号を保つため)。"""
    return "".join("\n" if c == "\n" else " " for c in text)


def mask_fences(text: str) -> str:
    """フェンスドコードブロックの中身を空白へ潰す。行数と桁はそのまま保つ。"""
    out = []
    fence = None
    for line in text.split("\n"):
        m = FENCE.match(line)
        if fence is None:
            if m:
                fence = m.group(1)[0]
                out.append("")
                continue
            out.append(line)
        else:
            # 閉じるのは同じ種類のフェンスだけ (``` の中の ~~~ は本文)
            out.append("")
            if m and m.group(1)[0] == fence:
                fence = None
    return "\n".join(out)


def mask_code(text: str) -> str:
    """コード塊 (フェンスとインライン) を空白へ潰す。

    フェンスを先に潰してから残りのインラインコードを潰す — 逆順にすると
    フェンスの中のバッククォートが対になって、フェンス自体を壊す。

    **見出しにはこれを掛けない。** GitHub は描画してからアンカーを振るので、
    `` `コード` `` の中身はアンカーに残る (記号だけが落ちる)。潰してしまうと
    そこが空白になり、`-` の連なりへ化ける
    """
    return INLINE_CODE.sub(lambda m: _blank(m.group(0)), mask_fences(text))


def slug_of(heading: str) -> str:
    """見出しのテキストから GitHub と同じ形のアンカーを作る。"""
    text = HTML_TAG.sub("", heading)
    text = HEADING_LINK.sub(r"\1", text)
    text = PUNCTUATION.sub("", text)
    return text.strip().lower().replace(" ", "-")


def anchors_of(text: str) -> list[str]:
    """ファイルの見出しから、GitHub が振るアンカーを順に作る。

    同じ見出しが 2 度目に出たら -1、3 度目は -2 が付く (github-slugger と同じ)。
    """
    seen: dict[str, int] = {}
    anchors = []
    # フェンスだけを潰す (コード塊の中の `# ...` を見出しと読まないため)。
    # インラインコードは潰さない — 中身がアンカーに残るのが GitHub の挙動
    for line in mask_fences(text).split("\n"):
        m = ATX_HEADING.match(line)
        if not m:
            continue
        base = slug_of(m.group(2))
        if not base:
            continue
        n = seen.get(base, 0)
        seen[base] = n + 1
        anchors.append(base if n == 0 else f"{base}-{n}")
    return anchors


def loose(anchor: str) -> str:
    """比較のための正規化 — 約物と `-` を落として文字と数字だけにする。"""
    return LOOSE.sub("", anchor.lower())


def links_of(text: str) -> list[tuple[int, str]]:
    """(行番号, リンク先) を返す。コード塊の中と外部 URL は含まない。"""
    masked = mask_code(text)

    # 参照リンクは定義と利用が離れているので、実際に使われている名前だけを見る。
    # 定義だけあって誰も使っていないものを赤くしても直す動機が無い
    used = {
        (m.group(2).strip() or m.group(1).strip()).lower()
        for m in REF_USE.finditer(masked)
    }
    found = [
        (masked[: m.start()].count("\n") + 1, m.group(1))
        for m in INLINE_LINK.finditer(masked)
    ]
    found += [
        (masked[: m.start()].count("\n") + 1, m.group(2))
        for m in REF_DEFINITION.finditer(masked)
        if m.group(1).strip().lower() in used
    ]

    out = []
    for line, target in found:
        target = target.strip()
        if not target or target.startswith(EXTERNAL) or target.startswith("//"):
            continue
        out.append((line, target))
    return sorted(out)


def unquote(target: str) -> str:
    """%20 のような百分率符号化を戻す (リンク先の実体はファイル名なので)。"""
    return re.sub(r"%([0-9A-Fa-f]{2})", lambda m: chr(int(m.group(1), 16)), target)


def check(root: Path, files: list[str]) -> tuple[list[str], int]:
    anchor_cache: dict[Path, list[str] | None] = {}

    def anchors_for(path: Path) -> list[str] | None:
        if path not in anchor_cache:
            try:
                anchor_cache[path] = anchors_of(path.read_text(encoding="utf-8"))
            except (OSError, UnicodeDecodeError):
                anchor_cache[path] = None
        return anchor_cache[path]

    problems: list[str] = []
    total = 0
    for name in files:
        source = root / name
        try:
            text = source.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as e:
            problems.append(f"{name}: 読めない ({e})")
            continue

        links = links_of(text)
        total += len(links)
        for line, raw in links:
            path_part, _, fragment = raw.partition("#")
            path_part = unquote(path_part)
            fragment = unquote(fragment)

            if path_part:
                # 先頭の / はリポジトリのルートから数える書き方として受ける。
                # GitHub の web 上ではサイトのルートを指してしまうが、そう書いた
                # 人の意図はまず前者なので、存在の検査はルート起点で行う
                base = root if path_part.startswith("/") else source.parent
                target = (base / path_part.lstrip("/")).resolve()
                if not target.exists():
                    problems.append(f"{name}:{line}: 参照先が無い → {raw}")
                    continue
            else:
                target = source

            if not fragment:
                continue

            # Markdown 以外 (スクリプト・JSON) は見出しを持たないのでアンカーを見ない
            if target.suffix.lower() not in (".md", ".markdown"):
                continue

            anchors = anchors_for(target)
            if anchors is None:
                problems.append(f"{name}:{line}: 参照先を読めない → {raw}")
                continue
            if loose(fragment) not in {loose(a) for a in anchors}:
                available = "、".join(f"#{a}" for a in anchors) or "(見出しが無い)"
                shown = target.relative_to(root) if target.is_relative_to(root) else target
                problems.append(
                    f"{name}:{line}: 見出しが無い → {raw}\n"
                    f"      {shown} にあるアンカー: {available}"
                )
    return problems, total


def main() -> int:
    root = Path(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    )
    files = [
        f
        for f in subprocess.run(
            ["git", "-C", str(root), "ls-files", "*.md", "*.markdown"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.splitlines()
        if f
    ]

    # 検査対象が 0 件なら、通っていることに意味が無い (git の出力形式が変わった、
    # 呼ぶ場所を間違えた等)。緑のまま何も見ていない状態を作らないために落とす
    # — scripts/check-file-modes.sh と同じ守り
    if not files:
        print("Markdown が 1 つも見つからない — 検査が成立していない", file=sys.stderr)
        return 1

    problems, total = check(root, files)
    if problems:
        print("ドキュメントのリンクが切れている:", file=sys.stderr)
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        print("", file=sys.stderr)
        print(
            "参照先を直すか、移った先へリンクを張り替える。"
            "外部 URL (http / https) はこの検査の対象外。",
            file=sys.stderr,
        )
        return 1

    print(f"ok: リンクの切れなし ({len(files)} ファイル・相対リンク {total} 本を検査)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
