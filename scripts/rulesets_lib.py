#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""ルールセット定義ファイルの検査と、実設定との照合 (#98)。

正本はリポジトリの `.github/rulesets/*.json` で、GitHub 側の状態はその写しに
すぎない (ADR-0006)。ここは二つの問いだけに答える:

    shape <定義ディレクトリ>                 定義が API に投げられる形か (token 不要)
    diff  <定義ディレクトリ> <実設定ディレクトリ>  定義と実設定が一致しているか
          [--without-bypass-actors]          bypass_actors を読めない認証を許す (名乗った上で)

入口は scripts/check-rulesets.sh と scripts/apply-rulesets.sh。実設定の取得
(gh の呼び出し) はそちらが持ち、ここは受け取った JSON だけを見る。
"""

import difflib
import json
import sys
from pathlib import Path

# GET は返すが PUT には渡せない鍵 — 環境ごとに決まる識別子と、GitHub 側の派生値。
# 定義ファイルがこれらを持つと、他の org へ持って行った瞬間に嘘になる。
DROP = {
    "id",
    "node_id",
    "_links",
    "created_at",
    "updated_at",
    "source",
    "source_type",
    "current_user_can_bypass",
}

# 定義ファイルが必ず持つ鍵。bypass_actors は空でも省略しない — ADR-0003 決定 1 の
# 「App を bypass list に入れない」は、書かれていて初めて検査できる。
REQUIRED = ("name", "target", "enforcement", "conditions", "rules", "bypass_actors")

TARGETS = {"branch", "tag", "push"}
ENFORCEMENTS = {"active", "evaluate", "disabled"}


def canon(ruleset):
    """比較できる形に落とす。

    DROP を除き、順序に意味の無い配列 (rules と ref_name の include/exclude) を
    並べ替える。API が返す順は保証が無いので、順序差だけで赤くしない。
    """
    out = {k: v for k, v in ruleset.items() if k not in DROP}

    rules = out.get("rules")
    if isinstance(rules, list):
        out["rules"] = sorted(
            rules, key=lambda r: json.dumps(r, sort_keys=True) if isinstance(r, dict) else str(r)
        )

    ref_name = out.get("conditions", {}).get("ref_name") if isinstance(out.get("conditions"), dict) else None
    if isinstance(ref_name, dict):
        for key in ("include", "exclude"):
            if isinstance(ref_name.get(key), list):
                ref_name[key] = sorted(ref_name[key], key=str)

    actors = out.get("bypass_actors")
    if isinstance(actors, list):
        out["bypass_actors"] = sorted(actors, key=lambda a: json.dumps(a, sort_keys=True))

    return out


def dumps(ruleset):
    return json.dumps(ruleset, indent=2, ensure_ascii=False, sort_keys=True)


def load_dir(path):
    """ディレクトリ内の *.json を {ファイル名: 中身} で読む。"""
    loaded = {}
    for f in sorted(Path(path).glob("*.json")):
        try:
            loaded[f.name] = json.loads(f.read_text())
        except json.JSONDecodeError as e:
            print(f"NG: {f} は JSON として不正: {e}", file=sys.stderr)
            loaded[f.name] = None
    return loaded


def check_shape(defs_dir):
    """定義ファイルが API に投げられる形かを見る。token も通信も要らない。"""
    files = load_dir(defs_dir)
    if not files:
        print(f"NG: {defs_dir} に定義ファイルが 1 つも無い", file=sys.stderr)
        return 1

    status = 0
    for name, body in sorted(files.items()):
        path = f"{defs_dir}/{name}"
        if body is None:  # load_dir が既に報告済み
            status = 1
            continue
        if not isinstance(body, dict):
            print(f"NG: {path} のトップレベルがオブジェクトではない", file=sys.stderr)
            status = 1
            continue

        missing = [k for k in REQUIRED if k not in body]
        if missing:
            print(f"NG: {path} に必須の鍵が無い: {', '.join(missing)}", file=sys.stderr)
            status = 1

        forbidden = sorted(DROP & set(body))
        if forbidden:
            print(
                f"NG: {path} に PUT へ渡せない鍵がある: {', '.join(forbidden)}"
                " (GET の応答をそのまま置いていないか)",
                file=sys.stderr,
            )
            status = 1

        if body.get("target") not in TARGETS:
            print(f"NG: {path} の target が不正: {body.get('target')!r}", file=sys.stderr)
            status = 1

        if body.get("enforcement") not in ENFORCEMENTS:
            print(f"NG: {path} の enforcement が不正: {body.get('enforcement')!r}", file=sys.stderr)
            status = 1

        # ファイル名と name の一致 — 照合は name で突き合わせるので、ずれていると
        # 「どのファイルが何を定義しているか」がディレクトリから読めなくなる
        if isinstance(body.get("name"), str) and name != f"{body['name']}.json":
            print(f"NG: {path} のファイル名が name ({body['name']}) と一致しない", file=sys.stderr)
            status = 1

    if status == 0:
        print(f"ok: 定義ファイル {len(files)} 本の形は妥当")
    return status


def check_diff(defs_dir, live_dir, without_bypass_actors=False):
    """定義と実設定を照合する。一致で 0、差分・欠落・過剰で 1。

    bypass_actors は ruleset への write access がある認証にしか返らない (実測 / #99)。
    読めていないまま「一致」と言うのは、ADR-0003 決定 1 が最も守っている項目を
    検査せずに緑を出すことなので、既定では赤にする。

    without_bypass_actors=True は、読めないことを承知の上で残りを照合する経路。
    緑にはするが**何を見ていないかを名乗る**。黙って通すのとは違う。読める認証で
    呼ばれたときは普通に比較する — 取りこぼさないため、フラグは「読めなかったとき
    に許す」であって「常に無視する」ではない。
    """
    defs = {}
    for name, body in load_dir(defs_dir).items():
        if body is None or not isinstance(body, dict) or "name" not in body:
            print(f"NG: {defs_dir}/{name} が読めないため照合できない", file=sys.stderr)
            return 1
        defs[body["name"]] = body

    live = {}
    for name, body in load_dir(live_dir).items():
        if body is None or not isinstance(body, dict) or "name" not in body:
            print(f"NG: 実設定 {live_dir}/{name} が読めない", file=sys.stderr)
            return 1
        live[body["name"]] = body

    status = 0

    # bypass_actors は ruleset への write access がある認証にしか返らない。public repo
    # でも匿名では見えず、Administration: Read の App でも見えない (#99 で実測)。
    # 既定では赤にする — 見えないまま「一致」と言うと、ADR-0003 決定 1 が最も守って
    # いる項目を検査せずに緑を出すことになる。
    blind = sorted(n for n, b in live.items() if "bypass_actors" not in b)
    if blind and not without_bypass_actors:
        print(
            "NG: 実設定に bypass_actors が含まれていない: "
            f"{', '.join(blind)} (認証が足りず読めていない。gh auth status を確認する)",
            file=sys.stderr,
        )
        return 1
    if blind:
        # 緑の意味を狭める。何を見ていないかが出力に無いと、この緑は
        # 「全部一致」と読まれる
        print(
            "注意: bypass_actors は検査していない — この認証では読めない "
            f"({', '.join(blind)})。読むには ruleset への write access が要る。"
            "手元で bash scripts/check-rulesets.sh を打つと厳格に照合する"
        )

    for name in sorted(set(defs) | set(live)):
        if name not in live:
            print(f"NG: 定義にある {name} が実設定に存在しない (未適用)", file=sys.stderr)
            status = 1
            continue
        if name not in defs:
            print(
                f"NG: 実設定の {name} が定義に無い"
                " (定義ファイルを足すか、GitHub 側から外す)",
                file=sys.stderr,
            )
            status = 1
            continue

        want_c, got_c = canon(defs[name]), canon(live[name])
        if "bypass_actors" not in got_c:
            # 実設定に無い項目を定義側だけ持っていると、差分の形で毎回赤くなる。
            # 見ていないことは上で名乗ってあるので、比較からも外す
            want_c.pop("bypass_actors", None)
        want, got = dumps(want_c), dumps(got_c)
        if want == got:
            print(f"ok: {name} は定義と一致")
            continue

        status = 1
        print(f"NG: {name} が定義とずれている", file=sys.stderr)
        for line in difflib.unified_diff(
            want.splitlines(), got.splitlines(), fromfile=f"定義 {name}", tofile=f"実設定 {name}", lineterm=""
        ):
            print(line, file=sys.stderr)

    return status


def main(argv):
    if len(argv) >= 3 and argv[1] == "shape":
        return check_shape(argv[2])
    if len(argv) >= 4 and argv[1] == "diff":
        flags = argv[4:]
        unknown = [f for f in flags if f != "--without-bypass-actors"]
        if unknown:
            print(f"不明なフラグ: {' '.join(unknown)}", file=sys.stderr)
            return 2
        return check_diff(argv[2], argv[3], "--without-bypass-actors" in flags)
    print(
        "使い方: rulesets_lib.py shape <定義ディレクトリ>\n"
        "        rulesets_lib.py diff  <定義ディレクトリ> <実設定ディレクトリ>"
        " [--without-bypass-actors]",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
