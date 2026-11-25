#!/usr/bin/env python3
"""Build the SwitchMTP Batch app icon.

Artwork is authored here as layered SVG, the Liquid Glass material is rendered
by `liquid-composer` (the WebGL recreation of Apple's Icon Composer), and the
rasterised result is mounted on the macOS 824/1024 icon grid by
`generate-app-icon.swift`.

Usage:
    python3 scripts/build-app-icon.py --recipe-only     # write the recipe
    python3 scripts/build-app-icon.py --render          # write + render

The render needs `liquid-composer` and a Chromium-based browser. Without a
Google Chrome install, point LC_CHANNEL at another Playwright channel, e.g.
    npm i liquid-composer
    LC_CHANNEL=msedge node node_modules/liquid-composer/scripts/agent/cli.mjs \
        render <recipe> --size 2048 --out <dir>
"""

import argparse
import json
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RECIPE = ROOT / "app/Resources/AppIcon.recipe.json"
RENDER = ROOT / "build/icon-render"

# ── geometry on the 1024 pt canvas (origin top-left) ───────────────────────
DEVICE = (92, 272, 840, 480, 70)           # x, y, w, h, r
POD_W = 140
LEFT_POD = (92, 272, POD_W, 480)
RIGHT_POD = (932 - POD_W, 272, POD_W, 480)
SCREEN = (252, 292, 520, 440, 22)
BARS = [(104, 358), (136, 380), (168, 402)]
ARROW = "M490,428 H534 V558 H580 L512,660 L444,558 H490 Z"

RED = ("#FF6B72", "#F0243C", "#9E0016")
BLUE = ("#6BE4FF", "#12A0EA", "#0639B5")
GLASS_DARK = "#101724"
GLASS_SCREEN = ("#0F3A5E", "#08243C", "#04101A")


def svg(body: str) -> str:
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
            f'viewBox="0 0 1024 1024">{body}</svg>')


def vgrad(gid: str, stops, y0: float, y1: float) -> str:
    parts = "".join(
        f'<stop offset="{o}" stop-color="{c}"/>' for o, c in stops
    )
    return (f'<linearGradient id="{gid}" x1="0" y1="{y0}" x2="0" y2="{y1}" '
            f'gradientUnits="userSpaceOnUse">{parts}</linearGradient>')


def layers() -> list:
    x, y, w, h, r = DEVICE
    ambient = svg(
        '<defs>'
        '<radialGradient id="cy" cx="250" cy="215" r="530" gradientUnits="userSpaceOnUse">'
        '<stop offset="0" stop-color="#66D8FF" stop-opacity="0.55"/>'
        '<stop offset="0.55" stop-color="#66D8FF" stop-opacity="0.12"/>'
        '<stop offset="1" stop-color="#66D8FF" stop-opacity="0"/></radialGradient>'
        '<radialGradient id="rd" cx="835" cy="835" r="500" gradientUnits="userSpaceOnUse">'
        '<stop offset="0" stop-color="#FF4050" stop-opacity="0.52"/>'
        '<stop offset="0.55" stop-color="#FF4050" stop-opacity="0.12"/>'
        '<stop offset="1" stop-color="#FF4050" stop-opacity="0"/></radialGradient>'
        '<radialGradient id="wh" cx="512" cy="500" r="380" gradientUnits="userSpaceOnUse">'
        '<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.14"/>'
        '<stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient>'
        '</defs>'
        '<rect width="1024" height="1024" fill="url(#cy)"/>'
        '<rect width="1024" height="1024" fill="url(#rd)"/>'
        '<rect width="1024" height="1024" fill="url(#wh)"/>')

    console = svg(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" '
                  f'fill="{GLASS_DARK}"/>')

    left = svg(
        f'<defs>{vgrad("lr", [(0, RED[0]), (0.45, RED[1]), (1, RED[2])], y, y + h)}</defs>'
        f'<path d="M{LEFT_POD[0] + POD_W},{y} H{LEFT_POD[0] + POD_W / 2} '
        f'A{POD_W / 2},{POD_W / 2} 0 0 0 {LEFT_POD[0]},{y + POD_W / 2} '
        f'V{y + h - POD_W / 2} A{POD_W / 2},{POD_W / 2} 0 0 0 {LEFT_POD[0] + POD_W / 2},{y + h} '
        f'H{LEFT_POD[0] + POD_W} Z" fill="url(#lr)"/>')

    right = svg(
        f'<defs>{vgrad("br", [(0, BLUE[0]), (0.45, BLUE[1]), (1, BLUE[2])], y, y + h)}</defs>'
        f'<path d="M{RIGHT_POD[0]},{y} H{RIGHT_POD[0] + POD_W / 2} '
        f'A{POD_W / 2},{POD_W / 2} 0 0 1 {RIGHT_POD[0] + POD_W},{y + POD_W / 2} '
        f'V{y + h - POD_W / 2} A{POD_W / 2},{POD_W / 2} 0 0 1 {RIGHT_POD[0] + POD_W / 2},{y + h} '
        f'H{RIGHT_POD[0]} Z" fill="url(#br)"/>')

    sx, sy, sw, sh, sr = SCREEN
    screen = svg(
        f'<defs>{vgrad("sc", [(0, GLASS_SCREEN[0]), (0.5, GLASS_SCREEN[1]), (1, GLASS_SCREEN[2])], sy, sy + sh)}</defs>'
        f'<rect x="{sx}" y="{sy}" width="{sw}" height="{sh}" rx="{sr}" fill="url(#sc)"/>')

    bar_svg = "".join(
        f'<rect x="{512 - bw / 2}" y="{by}" width="{bw}" height="7" rx="3.5" '
        f'opacity="{0.45 + i * 0.27:.2f}"/>'
        for i, (bw, by) in enumerate(BARS)
    )

    tex = {
        "enabled": True, "specular": "inside", "specularIntensity": 100,
        "refraction": {"enabled": True},
        "translucency": {"enabled": True, "value": 30},
        "shadow": {"enabled": True, "value": 16},
        "effects": {"refraction": 26, "bevel": 1.8, "rimIntensity": 72,
                    "innerGlow": 32, "keyHighlight": 128, "bottomHighlight": 58,
                    "ambientRim": 42, "innerRimWidth": 2.1, "aoDarken": 62},
    }

    return [
        {"name": "arrow", "src": svg(f'<path d="{ARROW}" fill="#FFFFFF"/>'),
         "liquidGlass": {"enabled": True, "specular": "inside", "specularIntensity": 100,
                         "translucency": {"enabled": True, "value": 3},
                         "shadow": {"enabled": True, "value": 18},
                         "effects": {"bevel": 1.0, "rimIntensity": 46,
                                     "innerGlow": 18, "keyHighlight": 130}}},
        {"name": "batchStack", "src": svg(f'<g fill="#EAF6FF">{bar_svg}</g>'),
         "liquidGlass": {"enabled": False}},
        {"name": "screen", "src": screen,
         "liquidGlass": {"enabled": True, "specular": "inside", "specularIntensity": 100,
                         "blur": {"enabled": True, "value": 28},
                         "refraction": {"enabled": True},
                         "translucency": {"enabled": True, "value": 16},
                         "shadow": {"enabled": False},
                         "effects": {"refraction": 12, "bevel": 1.4,
                                     "rimIntensity": 58, "innerGlow": 28,
                                     "keyHighlight": 105, "bottomHighlight": 50,
                                     "innerRimWidth": 1.9}}},
        {"name": "rightJoyCon", "src": right, "liquidGlass": dict(tex)},
        {"name": "leftJoyCon", "src": left, "liquidGlass": dict(tex)},
        {"name": "console", "src": console,
         "liquidGlass": dict(tex, specularIntensity=80)},
        {"name": "ambient", "src": ambient, "blendMode": "plus-lighter", "opacity": 62,
         "liquidGlass": {"enabled": False}},
    ]


def recipe() -> dict:
    return {
        "name": "SwitchMTP Batch",
        "appearance": "default",
        # Indigo glass plate: enough colour for refraction to read, dark enough
        # for the neon Joy-Con accents to stay the loudest thing in the icon.
        "background": {"colors": ["#3E4E90", "#131A33"]},
        "layers": layers(),
        "outputs": [{"format": "png", "sizes": [2048], "modes": ["default"]}],
    }


def find_cli() -> pathlib.Path | None:
    for base in (ROOT, pathlib.Path("/tmp/lc")):
        candidate = base / "node_modules/liquid-composer/scripts/agent/cli.mjs"
        if candidate.exists():
            return candidate
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--recipe-only", action="store_true")
    ap.add_argument("--render", action="store_true")
    ap.add_argument("--size", default="2048")
    args = ap.parse_args()

    RECIPE.parent.mkdir(parents=True, exist_ok=True)
    RECIPE.write_text(json.dumps(recipe(), indent=1, ensure_ascii=False) + "\n")
    print(f"==> recipe   {RECIPE.relative_to(ROOT)}")

    if args.recipe_only:
        return 0

    cli = find_cli()
    if not cli:
        print("error: liquid-composer not installed — run `npm i liquid-composer` "
              "in the project root", file=sys.stderr)
        return 1

    RENDER.mkdir(parents=True, exist_ok=True)
    cmd = [shutil.which("node") or "node", str(cli), "render", str(RECIPE),
           "--size", args.size, "--out", str(RENDER)]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        print(proc.stdout[-800:] or proc.stderr[-800:], file=sys.stderr)
        return proc.returncode
    print(f"==> rendered {RENDER}/icon-{args.size}.png")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
