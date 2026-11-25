#!/usr/bin/env python3
"""Build app/Resources/T2S.json — the Traditional-to-Simplified table the app
uses to show a readable Simplified name when the official catalogue only has
a Traditional one.

Sources:
  * OpenCC data/dictionary/TSCharacters.txt  (single-character map, Apache-2.0)
  * OpenCC data/dictionary/TSPhrases.txt     (multi-character map, Apache-2.0)
  * A small hand-written list of Nintendo franchises whose mainland-official
    name is not a character-for-character conversion (瑪利歐 -> 马力欧, and
    瑪利歐賽車 -> 马力欧卡丁车 rather than 马力欧赛车).

Usage: python3 scripts/build-t2s.py <TSCharacters.txt> <TSPhrases.txt>
"""

import json
import os
import sys

# Longest match wins, so order does not matter, but keep the specific
# franchise names ahead of generic ones for readability.
NINTENDO_OVERRIDES = {
    "瑪利歐賽車": "马力欧卡丁车",
    "瑪莉歐賽車": "马力欧卡丁车",
    "瑪利歐派對": "马力欧派对",
    "瑪莉歐派對": "马力欧派对",
    "瑪利歐": "马力欧",
    "瑪莉歐": "马力欧",
    "薩爾達無雙": "塞尔达无双",
    "薩爾達": "塞尔达",
    "動物森友會": "动物森友会",
    "寶可夢": "宝可梦",
    "神奇寶貝": "宝可梦",
    "聖火降魔錄": "火焰纹章",
    "漆彈大作戰": "斯普拉遁",
    "森喜剛": "咚奇刚",
    "咚奇剛": "咚奇刚",
}


def load_tsv(path):
    pairs = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) != 2:
                continue
            key, values = parts
            first = values.split(" ")[0]
            if first:
                pairs[key] = first
    return pairs


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    chars = load_tsv(sys.argv[1])
    phrases = load_tsv(sys.argv[2])

    # Single characters only; everything longer belongs in phrases.
    char_map = {k: v for k, v in chars.items() if len(k) == 1}
    phrase_map = {k: v for k, v in phrases.items() if len(k) >= 2}
    phrase_map.update(NINTENDO_OVERRIDES)

    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "app", "Resources", "T2S.json")
    out = os.path.normpath(out)
    payload = {
        "version": 1,
        "license": "OpenCC data dictionaries, Apache License 2.0",
        # Longest key first: the Swift side walks the list in order and takes
        # the first match, which keeps JSON object ordering out of the picture.
        "phrases": [[k, v] for k, v in sorted(phrase_map.items(), key=lambda kv: -len(kv[0]))],
        "chars": dict(sorted(char_map.items())),
    }
    with open(out, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, separators=(",", ":"))
    print("wrote", out,
          "phrases", len(phrase_map),
          "chars", len(char_map),
          "%.1f KB" % (os.path.getsize(out) / 1024.0))


if __name__ == "__main__":
    main()
