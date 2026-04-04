#!/usr/bin/env python3

from pathlib import Path
import json

from PIL import Image, ImageDraw


FRAME_SIZE = 64
COLORS = {
    "outline": (12, 54, 62, 255),
    "body": (42, 196, 177, 255),
    "shadow": (24, 132, 124, 255),
    "screen": (12, 23, 36, 255),
    "screen_glow": (152, 255, 244, 255),
    "tear": (103, 202, 255, 255),
    "bubble_fill": (250, 247, 240, 255),
    "bubble_outline": (68, 62, 58, 255),
    "alert": (255, 85, 85, 255),
    "sleep": (244, 245, 255, 255),
}

ASSETS_ROOT = Path(__file__).resolve().parents[1] / "notchi/notchi/Assets.xcassets"

CONTENTS_JSON = {
    "images": [
        {
            "filename": "sprite_sheet.png",
            "idiom": "universal",
        }
    ],
    "info": {
        "author": "xcode",
        "version": 1,
    },
    "properties": {
        "preserves-vector-representation": False,
    },
}


def draw_cut_rect(draw: ImageDraw.ImageDraw, x: int, y: int, w: int, h: int, fill, outline):
    draw.rectangle((x + 1, y, x + w - 2, y + h - 1), fill=fill)
    draw.rectangle((x, y + 1, x + w - 1, y + h - 2), fill=fill)
    draw.line((x + 1, y, x + w - 2, y), fill=outline)
    draw.line((x + 1, y + h - 1, x + w - 2, y + h - 1), fill=outline)
    draw.line((x, y + 1, x, y + h - 2), fill=outline)
    draw.line((x + w - 1, y + 1, x + w - 1, y + h - 2), fill=outline)


def draw_face(draw, x, y, emotion, blink=False):
    eye = COLORS["screen_glow"]
    mouth = COLORS["screen_glow"]
    tear = COLORS["tear"]

    if blink:
        draw.line((x + 5, y + 4, x + 8, y + 4), fill=eye)
        draw.line((x + 15, y + 4, x + 18, y + 4), fill=eye)
    elif emotion == "happy":
        draw.line((x + 5, y + 4, x + 8, y + 3), fill=eye)
        draw.line((x + 15, y + 3, x + 18, y + 4), fill=eye)
        draw.rectangle((x + 2, y + 1, x + 3, y + 2), fill=eye)
        draw.rectangle((x + 20, y + 1, x + 21, y + 2), fill=eye)
    elif emotion == "sad":
        draw.line((x + 5, y + 3, x + 8, y + 5), fill=eye)
        draw.line((x + 15, y + 5, x + 18, y + 3), fill=eye)
        draw.rectangle((x + 3, y + 6, x + 4, y + 9), fill=tear)
        draw.rectangle((x + 19, y + 6, x + 20, y + 9), fill=tear)
    elif emotion == "sob":
        draw.line((x + 5, y + 3, x + 8, y + 5), fill=eye)
        draw.line((x + 15, y + 5, x + 18, y + 3), fill=eye)
        draw.rectangle((x + 3, y + 6, x + 5, y + 13), fill=tear)
        draw.rectangle((x + 19, y + 6, x + 21, y + 13), fill=tear)
    else:
        draw.rectangle((x + 6, y + 3, x + 7, y + 5), fill=eye)
        draw.rectangle((x + 16, y + 3, x + 17, y + 5), fill=eye)

    if emotion == "happy":
        draw.line((x + 8, y + 12, x + 10, y + 14), fill=mouth)
        draw.line((x + 10, y + 14, x + 14, y + 14), fill=mouth)
        draw.line((x + 14, y + 14, x + 16, y + 12), fill=mouth)
        draw.rectangle((x + 11, y + 13, x + 13, y + 14), fill=mouth)
    elif emotion == "sad":
        draw.line((x + 8, y + 15, x + 10, y + 13), fill=mouth)
        draw.line((x + 10, y + 13, x + 14, y + 13), fill=mouth)
        draw.line((x + 14, y + 13, x + 16, y + 15), fill=mouth)
    elif emotion == "sob":
        draw.line((x + 10, y + 14, x + 14, y + 14), fill=mouth)
        draw.rectangle((x + 11, y + 15, x + 12, y + 16), fill=mouth)
    else:
        draw.line((x + 10, y + 14, x + 14, y + 14), fill=mouth)


def draw_terminal_creature(draw, x, y, emotion, blink=False, body_height=20, feet_phase=0):
    body_width = 34
    draw_cut_rect(draw, x, y, body_width, body_height, COLORS["body"], COLORS["outline"])
    draw.rectangle((x + 2, y + body_height - 4, x + body_width - 3, y + body_height - 2), fill=COLORS["shadow"])
    draw_cut_rect(draw, x + 6, y + 4, 22, 14, COLORS["screen"], COLORS["outline"])
    draw.rectangle((x + 8, y + 6, x + 25, y + 7), fill=COLORS["screen_glow"])
    draw.rectangle((x + 28, y + 2, x + 29, y + 4), fill=COLORS["screen_glow"])
    draw.rectangle((x + 30, y + 4, x + 31, y + 5), fill=COLORS["screen_glow"])

    draw.rectangle((x - 3, y + 8, x - 1, y + 11), fill=COLORS["outline"])
    draw.rectangle((x + body_width, y + 8, x + body_width + 2, y + 11), fill=COLORS["outline"])
    draw.rectangle((x - 2, y + 9, x, y + 10), fill=COLORS["body"])
    draw.rectangle((x + body_width - 1, y + 9, x + body_width + 1, y + 10), fill=COLORS["body"])

    feet = [
        (x + 7, y + body_height, 2 + (feet_phase % 2)),
        (x + 15, y + body_height, 3 - (feet_phase % 2)),
        (x + 23, y + body_height, 2 + ((feet_phase + 1) % 2)),
    ]
    for foot_x, foot_y, foot_h in feet:
        draw.rectangle((foot_x, foot_y, foot_x + 2, foot_y + foot_h), fill=COLORS["outline"])
        draw.rectangle((foot_x + 1, foot_y, foot_x + 1, foot_y + foot_h), fill=COLORS["body"])

    draw_face(draw, x + 6, y + 4, emotion, blink=blink)


def draw_speech_bubble(draw, x, y, dots):
    draw_cut_rect(draw, x, y, 18, 13, COLORS["bubble_fill"], COLORS["bubble_outline"])
    draw.polygon([(x + 4, y + 13), (x + 7, y + 13), (x + 5, y + 16)], fill=COLORS["bubble_fill"], outline=COLORS["bubble_outline"])
    for index in range(dots):
        dot_x = x + 4 + index * 4
        draw.rectangle((dot_x, y + 5, dot_x + 1, y + 6), fill=COLORS["bubble_outline"])


def draw_waiting_bubble(draw, x, y):
    draw_cut_rect(draw, x, y, 14, 15, COLORS["bubble_fill"], COLORS["bubble_outline"])
    draw.polygon([(x + 4, y + 15), (x + 6, y + 15), (x + 5, y + 17)], fill=COLORS["bubble_fill"], outline=COLORS["bubble_outline"])
    draw.rectangle((x + 6, y + 4, x + 7, y + 9), fill=COLORS["alert"])
    draw.rectangle((x + 6, y + 11, x + 7, y + 12), fill=COLORS["alert"])


def draw_sleep_bubbles(draw, frame):
    z_positions = [
        [(36, 11)],
        [(36, 11)],
        [(36, 11), (43, 6)],
        [(36, 11), (43, 6)],
        [(36, 11), (43, 6), (49, 2)],
        [(36, 11), (43, 6), (49, 2)],
    ][frame]
    for index, (x, y) in enumerate(z_positions):
        size = 6 - index
        draw.line((x, y, x + size, y), fill=COLORS["sleep"])
        draw.line((x + size, y, x, y + size), fill=COLORS["sleep"])
        draw.line((x, y + size, x + size, y + size), fill=COLORS["sleep"])


def draw_sleeping_creature(draw, emotion, frame):
    x = 14
    y = 35
    draw_cut_rect(draw, x, y, 34, 15, COLORS["body"], COLORS["outline"])
    draw.rectangle((x + 2, y + 11, x + 31, y + 12), fill=COLORS["shadow"])
    draw_cut_rect(draw, x + 6, y + 3, 18, 9, COLORS["screen"], COLORS["outline"])
    draw.line((x + 12, y + 6, x + 15, y + 6), fill=COLORS["screen_glow"])
    draw.line((x + 21, y + 6, x + 24, y + 6), fill=COLORS["screen_glow"])
    if emotion == "happy":
        draw.line((x + 15, y + 10, x + 20, y + 10), fill=COLORS["screen_glow"])

    draw.rectangle((x + 6, y + 15, x + 9, y + 17), fill=COLORS["outline"])
    draw_rectangle = ImageDraw.ImageDraw.rectangle
    draw_rectangle(draw, (x + 7, y + 15, x + 8, y + 17), fill=COLORS["body"])
    draw_sleep_bubbles(draw, frame)


def draw_mini_creature(draw, x, y, emotion):
    draw_cut_rect(draw, x, y, 14, 10, COLORS["body"], COLORS["outline"])
    draw.rectangle((x + 1, y + 7, x + 12, y + 8), fill=COLORS["shadow"])
    draw.rectangle((x + 4, y + 3, x + 5, y + 4), fill=COLORS["screen_glow"])
    draw.rectangle((x + 8, y + 3, x + 9, y + 4), fill=COLORS["screen_glow"])
    if emotion == "happy":
        draw.line((x + 4, y + 6, x + 9, y + 6), fill=COLORS["screen_glow"])
    else:
        draw.rectangle((x + 5, y + 6, x + 8, y + 6), fill=COLORS["screen_glow"])


def render_idle_frame(emotion, frame):
    image = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    y_offsets = [0, -1, 0, -1, 0, 1]
    draw_terminal_creature(draw, 15, 28 + y_offsets[frame], emotion, blink=(frame == 4), feet_phase=frame)
    return image


def render_working_frame(emotion, frame):
    image = render_idle_frame(emotion, frame)
    draw = ImageDraw.Draw(image)
    draw_speech_bubble(draw, 39, 8 + (frame % 2), min(3, frame // 2 + 1))
    return image


def render_waiting_frame(emotion, frame):
    image = render_idle_frame(emotion, frame)
    draw = ImageDraw.Draw(image)
    x_offsets = [0, 1, 0, 1, 0, 1]
    draw_waiting_bubble(draw, 40 + x_offsets[frame], 7)
    return image


def render_sleeping_frame(emotion, frame):
    image = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw_sleeping_creature(draw, emotion, frame)
    return image


def render_compacting_frame(emotion, frame):
    image = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    if frame == 0:
        draw_terminal_creature(draw, 15, 29, emotion, feet_phase=0)
    elif frame == 1:
        draw_terminal_creature(draw, 16, 31, emotion, body_height=14, feet_phase=1)
    elif frame == 2:
        draw_mini_creature(draw, 25, 38, emotion)
    elif frame == 3:
        draw.rectangle((30, 42, 33, 45), fill=COLORS["body"])
        draw.rectangle((31, 41, 32, 46), fill=COLORS["screen_glow"])
    else:
        draw_terminal_creature(draw, 15, 29, emotion if emotion == "happy" else "neutral", feet_phase=0)

    return image


SPRITE_VARIANTS = {
    "idle": {
        "emotions": ["neutral", "happy", "sad", "sob"],
        "frames": 6,
        "renderer": render_idle_frame,
    },
    "working": {
        "emotions": ["neutral", "happy", "sad", "sob"],
        "frames": 6,
        "renderer": render_working_frame,
    },
    "waiting": {
        "emotions": ["neutral", "happy", "sad", "sob"],
        "frames": 6,
        "renderer": render_waiting_frame,
    },
    "sleeping": {
        "emotions": ["neutral", "happy"],
        "frames": 6,
        "renderer": render_sleeping_frame,
    },
    "compacting": {
        "emotions": ["neutral", "happy"],
        "frames": 5,
        "renderer": render_compacting_frame,
    },
}


def write_imageset(name: str, image: Image.Image):
    imageset_dir = ASSETS_ROOT / f"{name}.imageset"
    imageset_dir.mkdir(parents=True, exist_ok=True)
    image.save(imageset_dir / "sprite_sheet.png")
    (imageset_dir / "Contents.json").write_text(json.dumps(CONTENTS_JSON, indent=2) + "\n")


def build_sheet(frames: int, renderer, emotion: str):
    sheet = Image.new("RGBA", (FRAME_SIZE * frames, FRAME_SIZE), (0, 0, 0, 0))
    for frame in range(frames):
        sheet.alpha_composite(renderer(emotion, frame), dest=(frame * FRAME_SIZE, 0))
    return sheet


def main():
    for task, config in SPRITE_VARIANTS.items():
        for emotion in config["emotions"]:
            name = f"codex_{task}_{emotion}"
            write_imageset(name, build_sheet(config["frames"], config["renderer"], emotion))


if __name__ == "__main__":
    main()
