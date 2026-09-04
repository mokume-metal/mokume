#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""外に置いた資産 (絵・動き) が生きているかを見る (#483)。

**塞ぐのは「公開した後にリンクが切れる」である。** [ADR-0027](../docs/decisions/0027-readable-surfaces.md)
決定 2 により、実行結果の絵はリポジトリに入らず外部ホスティングに置かれ、説明文には
それを指す 1 行だけが残る。指し先はこちらの都合と無関係に消えうるので、**壊れる瞬間は
どの PR とも一致しない** — PR ごとの検査では原理的に捕まらず、定期で引くしかない。

**見るのは資産として参照している URL だけである。** 素のリンク (本文から他の文書へ
飛ぶもの) は見ない — 追跡下の Markdown が持つ外部リンクを全部引けば、相手側の一時的な
不調やレート制限で検査が揺れる。外部 URL を per-PR の検査から外した判断は
[#90](https://github.com/mokume-metal/mokume/issues/90) が既に下しており、ここはその
外側に「資産の死活だけを、定期で」を足す形になる。

**0 件なら赤にする。** 書式が変わって 1 本も拾えなくなった状態は、全部生きているのと
同じ緑で表れる。検査が空回りしていることを緑で隠さない (`check-published-reference.py` /
`check-docs-links.py` と同じ守り)。

**出所を必ず添える。** 切れた URL だけを見せられても、24 本ある指し先のどれを撮り直せば
よいか分からない。ファイルと行を出せば、そのまま `///` の該当行へ飛べる。

**探すのは説明文と Markdown の本文だけ。** ADR-0027 決定 2 が絵の URL の置き場をそこに
定めているので、それ以外に書かれた URL は資産ではない — 実際、検査の資材 (テストの中の
`https://example.invalid/…`) を資産として数えると、**壊れているべきものを死活の赤として
報告する**ことになる。Swift は `///` の行だけを見、Markdown はコード塊を潰してから見る
(書き方の例示を実物と数えないため。潰し方の正典は `check-docs-links.py` にあり、写さずに
借りている)。
"""

from __future__ import annotations

import argparse
import importlib.util
import pathlib
import re
import subprocess
import sys
import urllib.error
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

# タイムアウトと `<img>` の綴りは site_source が持つ (#815)
from site_source import FETCH_TIMEOUT_SECONDS, HTML_IMAGE  # noqa: E402

# 資産として参照している外部 URL の書き方は 2 つある。
#   - Markdown の画像 `![説明](https://…)` — `///` の中も普通の .md も同じ書式
#   - docc の `@Image(source: "https://…")` / `@Video(source: "https://…")`
# 素のリンク `[文字](https://…)` は拾わない (`!` の有無で分かれる)
MARKDOWN_IMAGE = re.compile(r"!\[[^\]]*\]\((https?://[^)\s]+)\)")
DOCC_SOURCE = re.compile(r"@(?:Image|Video)\s*\(\s*source:\s*\"(https?://[^\"]+)\"")
# HTML の絵 `<img src="https://…">`。入口のページ (#482) が絵を外に置くので、
# **いちばん人目に付く絵だけが死活の外**にならないようここも見る。
# 綴りは site_source が持つ (#815) — 入口を検める側 (check-entry.py) と同じものを読む

# Swift の説明文。ADR-0027 決定 2 により、絵を指す行はここに置かれる
DOC_COMMENT = re.compile(r"^\s*///")

# 相手が bot を弾かないように名乗る。無名の要求を落とす配信は珍しくない
USER_AGENT = "mokume-external-assets-check (+https://github.com/mokume-metal/mokume)"


def _mask_code():
    """Markdown のコード塊を潰す関数を `check-docs-links.py` から借りる。

    **写さない。** フェンスとインラインコードの潰し方には対の取り方の細部があり、
    2 か所に置くと片方だけが直る。名前にハイフンを含むので import は経路から行う。
    """
    path = pathlib.Path(__file__).resolve().parent / "check-docs-links.py"
    spec = importlib.util.spec_from_file_location("check_docs_links", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.mask_code


mask_code = _mask_code()


class Reference:
    """1 本の指し先と、その出所。"""

    def __init__(self, url: str, path: str, line: int) -> None:
        self.url = url
        self.path = path
        self.line = line

    @property
    def origin(self) -> str:
        return f"{self.path}:{self.line}"


def tracked_files(root: pathlib.Path) -> list[str]:
    """追跡下の、説明文を持ちうるファイル。

    **名指しするのは形式だけで、置き場は名指ししない** — `Sources/` の下に限る等の
    絞りを書くと、次に説明文の置き場が増えたときに同じ穴が空く。読めない形式や
    説明文を持たない形式は、下の `readable` が素通りさせる。
    """
    completed = subprocess.run(
        ["git", "ls-files", "*.swift", "*.md", "*.html"],
        cwd=root,
        capture_output=True,
        text=True,
        check=True,
    )
    return [line for line in completed.stdout.splitlines() if line]


def readable(name: str, text: str) -> str:
    """指し先を探してよい部分だけを残す (行数と行番号はそのまま保つ)。"""
    if name.endswith(".swift"):
        return "\n".join(line if DOC_COMMENT.match(line) else "" for line in text.split("\n"))
    if name.endswith(".html"):
        # HTML にはコード塊の書式が無いので、そのまま見る
        return text
    return mask_code(text)


def references_in(text: str, path: str) -> list[Reference]:
    """指し先と、その出所の行。

    **1 行ずつではなく本文全体を見る。** HTML は属性を改行で分けて書けるので
    (`<img` の次の行に `src="…"`)、行で切ると 2 つが別の行に落ちて 1 本も拾えない。
    しかも拾えなかったことは緑で表れる。行番号は一致した位置から数える
    (`readable` は行数を保つので、潰した後でも元の行と一致する)。
    """
    readable_text = readable(path, text)
    found = []
    for pattern in (MARKDOWN_IMAGE, DOCC_SOURCE, HTML_IMAGE):
        for match in pattern.finditer(readable_text):
            found.append(
                Reference(match.group(1), path, readable_text.count("\n", 0, match.start()) + 1)
            )
    return sorted(found, key=lambda reference: reference.line)


def collect(root: pathlib.Path) -> list[Reference]:
    found = []
    for name in tracked_files(root):
        path = root / name
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            # 読めないもの (削除済み・想定外の符号化) に指し先は書けない
            continue
        found.extend(references_in(text, name))
    return found


def probe(url: str) -> str | None:
    """引けたら None、引けなければ理由。

    **HEAD ではなく GET で引く。** HEAD に 405 を返す配信があり、その 405 を死活の
    判定に混ぜると生きている資産まで赤くなる。本文は読み捨てる。
    """
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=FETCH_TIMEOUT_SECONDS) as response:
            response.read(1)
        return None
    except urllib.error.HTTPError as error:
        return f"HTTP {error.code}"
    except Exception as error:  # 名前解決・接続・証明書の失敗をそのまま名乗る
        return str(error)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parents[1],
        help="走査するリポジトリ (既定: このスクリプトのリポジトリ)",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="引かずに、見つけた指し先とその出所を並べる",
    )
    arguments = parser.parse_args()

    references = collect(arguments.root)
    if not references:
        print(
            "外部資産の指し先を 1 つも見つけられない — 検査が成立していない。\n"
            "説明文の絵の書き方が変わったなら、この道具の拾い方も直す",
            file=sys.stderr,
        )
        return 1

    # 同じ絵は複数の場所から指されうる。引くのは 1 回でよいが、赤くなったときは
    # 出所を全部見せる (撮り直しは指している側の全部に効く)
    origins: dict[str, list[str]] = {}
    for reference in references:
        origins.setdefault(reference.url, []).append(reference.origin)

    print(f"外部資産の指し先: {len(origins)} 本 ({len(references)} 箇所から)")
    if arguments.list:
        for url, where in sorted(origins.items()):
            print(f"  {url}\n    {' / '.join(where)}")
        return 0

    dead = []
    for url, where in sorted(origins.items()):
        reason = probe(url)
        if reason is None:
            continue
        dead.append((url, reason, where))

    if dead:
        print("外に置いた資産が引けない:", file=sys.stderr)
        for url, reason, where in dead:
            print(f"  {url} — {reason}", file=sys.stderr)
            for origin in where:
                print(f"    {origin}", file=sys.stderr)
        print(
            "\n撮り直しの手順は .claude/skills/gyazo-evidence/ が持つ。"
            "撮り直したら、指している行の URL を差し替える (ADR-0027 決定 2)。",
            file=sys.stderr,
        )
        return 1

    print(f"ok: {len(origins)} 本すべて引けた")
    return 0


if __name__ == "__main__":
    sys.exit(main())
