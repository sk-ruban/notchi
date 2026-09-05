#!/usr/bin/env python3
"""Extract seamless terrain tiles and the supplied water animation (requires Pillow)."""
import json
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "scripts/assets/backgrounds"


def save_asset(name, tile):
    directory = ROOT / f"notchi/notchi/Assets.xcassets/{name}.imageset"
    directory.mkdir(parents=True, exist_ok=True)
    tile.save(directory / "background.png")
    (directory / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "background.png", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")


if __name__ == "__main__":
    water = Image.open(SOURCES / "tileset1.png").convert("RGBA")
    # Eight consecutive 16px animation frames, separated by one-pixel gutters.
    for frame in range(8):
        left = 4 + frame * 17
        save_asset(f"IslandWater{frame}", water.crop((left, 3, left + 16, 19)))

    outdoor = Image.open(SOURCES / "tileset2.png").convert("RGBA")
    def outdoor_tile(x, y):
        left, top = 1 + x * 17, 1 + y * 17
        return outdoor.crop((left, top, left + 16, top + 16))

    save_asset("IslandGround", outdoor_tile(21, 37))
    crater = Image.new("RGBA", (32, 32))
    for y in range(2):
        for x in range(2):
            crater.paste(outdoor_tile(22 + x, 32 + y), (x * 16, y * 16))
    save_asset("IslandCrater", crater)
