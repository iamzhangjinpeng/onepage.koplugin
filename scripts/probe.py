#!/usr/bin/env python3
"""Probe today's ONE v3 endpoint and print the fields the wallpaper needs.

Usage: python3 scripts/probe.py [--save]
       --save writes tests/fixtures/hp_detail.json for offline regression.
"""

import argparse
import json
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

BASE = "http://v3.wufazhuce.com:8000"
QS = "?version=3.5.0&platform=android"
ROOT = Path(__file__).resolve().parents[1]


def get(path, timeout=12):
    with urllib.request.urlopen(BASE + path + QS, timeout=timeout) as response:
        return json.loads(response.read())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--save", action="store_true", help="save today's detail as a fixture")
    args = parser.parse_args()

    ids = get("/api/hp/idlist/0").get("data") or []
    if not ids:
        raise SystemExit("idlist/0 returned no ids")
    print("idlist[0..4]:", ids[:5], " max(id):", max(int(i) for i in ids))

    beijing_today = datetime.now(timezone(timedelta(hours=8))).date().isoformat()
    today = None
    for candidate in [ids[0]] + ids[1:9]:
        data = get("/api/hp/detail/" + str(candidate)).get("data")
        if data and data.get("hp_makettime", "").startswith(beijing_today):
            today = data
            break
    if not today:
        today = get("/api/hp/detail/" + str(ids[0])).get("data")
    if not today:
        raise SystemExit("no usable hp/detail")

    fields = ["hpcontent_id", "hp_title", "hp_makettime", "hp_content", "hp_author",
              "image_authors", "text_author_name", "hp_img_url", "hp_img_original_url"]
    for key in fields:
        print(f"{key:22s} = {today.get(key)!r}")

    url = (today.get("hp_img_url") or "").split("?")[0] + "?imageMogr2/thumbnail/1080x/format/jpg"
    with urllib.request.urlopen(url, timeout=15) as response:
        data = response.read()
        print(f"image                  = HTTP {response.status}, {len(data)} bytes, "
              f"type={response.headers.get('content-type')}")

    if args.save:
        target = ROOT / "tests" / "fixtures" / "hp_detail.json"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps({"ids": ids, "detail": today}, ensure_ascii=False, indent=2))
        print("saved:", target)


if __name__ == "__main__":
    main()
