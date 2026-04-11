#!/usr/bin/env python3

from pathlib import Path
import json

from PIL import Image, ImageDraw


FRAME_SIZE = 64
SCALE = 4
CANVAS_SIZE = FRAME_SIZE * SCALE
ASSETS_ROOT = Path(__file__).resolve().parents[1] / "notchi/notchi/Assets.xcassets"

COLORS = {
    "outline": (4, 22, 25, 255),
    "body": (35, 190, 175, 255),
    "body_shadow": (18, 97, 90, 255),
    "body_highlight": (139, 255, 241, 255),
    "face_plate": (8, 19, 29, 255),
    "face_outline": (11, 44, 54, 255),
    "face_glow": (153, 255, 241, 255),
    "face_dim": (95, 214, 201, 255),
    "blush": (255, 172, 188, 255),
    "tear": (116, 214, 255, 255),
    "accent": (255, 196, 89, 255),
    "accent_soft": (255, 232, 177, 255),
    "bubble_fill": (248, 244, 235, 255),
    "bubble_outline": (85, 75, 67, 255),
    "alert": (255, 95, 95, 255),
    "sleep": (244, 246, 255, 255),
    "spark": (255, 236, 117, 255),
}

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

EMOTIONS = ["neutral", "happy", "sad", "sob"]


def new_canvas() -> Image.Image:
    return Image.new("RGBA", (CANVAS_SIZE, CANVAS_SIZE), (0, 0, 0, 0))


def downsample(image: Image.Image) -> Image.Image:
    return image.resize((FRAME_SIZE, FRAME_SIZE), Image.Resampling.BOX)


def draw_sparkle(draw: ImageDraw.ImageDraw, x: int, y: int, color, size: int = 2):
    draw.line((x, y + size, x + size * 2, y + size), fill=color, width=max(1, size // 2))
    draw.line((x + size, y, x + size, y + size * 2), fill=color, width=max(1, size // 2))


def draw_hex(draw: ImageDraw.ImageDraw, cx: int, cy: int, rx: int, ry: int, fill, outline, width: int):
    points = [
        (cx, cy - ry),
        (cx + rx, cy - ry // 2),
        (cx + rx, cy + ry // 2),
        (cx, cy + ry),
        (cx - rx, cy + ry // 2),
        (cx - rx, cy - ry // 2),
    ]
    draw.polygon(points, fill=fill)
    draw.line(points + [points[0]], fill=outline, width=width, joint="curve")


def draw_segment(base: Image.Image, cx: int, cy: int, orbit: int, angle_deg: float, band_w: int, band_h: int):
    segment = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(segment)

    x0 = cx - band_w // 2
    y0 = cy - orbit - band_h // 2
    x1 = x0 + band_w
    y1 = y0 + band_h
    radius = band_w // 2

    draw.rounded_rectangle(
        (x0, y0, x1, y1),
        radius=radius,
        fill=COLORS["body"],
        outline=COLORS["outline"],
        width=5,
    )
    draw.rounded_rectangle(
        (x0 + 4, y0 + 4, x1 - 4, y0 + band_h // 3),
        radius=max(8, radius - 6),
        fill=COLORS["body_highlight"],
    )
    draw.rounded_rectangle(
        (x0 + 8, y0 + band_h // 3, x1 - 8, y1 - 8),
        radius=max(6, radius - 10),
        fill=COLORS["body"],
    )
    draw.line((cx, y0 + 8, cx, y1 - 10), fill=COLORS["body_shadow"], width=3)

    rotated = segment.rotate(angle_deg, resample=Image.Resampling.BICUBIC, center=(cx, cy))
    base.alpha_composite(rotated)


def draw_feet(draw: ImageDraw.ImageDraw, cx: int, cy: int, size: float, frame: int):
    offsets = [-8, 8]
    lift = [0, 1, 0, -1, 0, 1][frame % 6]
    foot_w = max(10, int(10 * SCALE * size / 4))
    foot_h = max(6, int(6 * SCALE * size / 4))
    y = cy + max(26, int(26 * SCALE * size / 4))

    for index, offset in enumerate(offsets):
        foot_x = cx + int(offset * SCALE / 2) - foot_w // 2
        step = lift if index == frame % 2 else -lift // 2
        draw.rounded_rectangle(
            (foot_x, y + step, foot_x + foot_w, y + foot_h + step),
            radius=foot_h // 2,
            fill=COLORS["body"],
            outline=COLORS["outline"],
            width=4,
        )


def draw_face(draw: ImageDraw.ImageDraw, cx: int, cy: int, emotion: str, frame: int, size: float, blink: bool = False):
    face_w = max(72, int(72 * SCALE * size / 4))
    face_h = max(58, int(58 * SCALE * size / 4))
    x0 = cx - face_w // 2
    y0 = cy - face_h // 2
    x1 = cx + face_w // 2
    y1 = cy + face_h // 2

    draw.rounded_rectangle((x0, y0, x1, y1), radius=16, fill=COLORS["face_plate"], outline=COLORS["face_outline"], width=4)
    draw.rounded_rectangle((x0 + 4, y0 + 4, x1 - 4, y0 + 16), radius=12, fill=COLORS["face_outline"])
    draw.line((x0 + 10, y0 + 11, x0 + 22, y0 + 11), fill=COLORS["face_dim"], width=3)
    draw.line((x1 - 22, y0 + 11, x1 - 12, y0 + 11), fill=COLORS["accent"], width=3)

    eye = COLORS["face_glow"]
    dim = COLORS["face_dim"]
    blush = COLORS["blush"]
    tear = COLORS["tear"]

    left_eye = cx - 16
    right_eye = cx + 16
    eye_y = cy - 7

    if blink:
        draw.line((left_eye - 7, eye_y, left_eye + 7, eye_y), fill=eye, width=4)
        draw.line((right_eye - 7, eye_y, right_eye + 7, eye_y), fill=eye, width=4)
    elif emotion == "happy":
        draw.arc((left_eye - 8, eye_y - 5, left_eye + 8, eye_y + 7), 200, 340, fill=eye, width=4)
        draw.arc((right_eye - 8, eye_y - 5, right_eye + 8, eye_y + 7), 200, 340, fill=eye, width=4)
        draw.ellipse((cx - 28, cy + 4, cx - 20, cy + 12), fill=blush)
        draw.ellipse((cx + 20, cy + 4, cx + 28, cy + 12), fill=blush)
    elif emotion == "sad":
        draw.line((left_eye - 7, eye_y - 3, left_eye + 7, eye_y + 5), fill=eye, width=4)
        draw.line((right_eye - 7, eye_y + 5, right_eye + 7, eye_y - 3), fill=eye, width=4)
        tear_len = 11 + (frame % 2) * 2
        draw.rounded_rectangle((left_eye - 12, eye_y + 7, left_eye - 5, eye_y + 7 + tear_len), radius=3, fill=tear)
    elif emotion == "sob":
        draw.line((left_eye - 7, eye_y - 3, left_eye + 7, eye_y + 5), fill=eye, width=4)
        draw.line((right_eye - 7, eye_y + 5, right_eye + 7, eye_y - 3), fill=eye, width=4)
        tear_len = 15 + (frame % 2) * 2
        draw.rounded_rectangle((left_eye - 12, eye_y + 7, left_eye - 4, eye_y + 7 + tear_len), radius=3, fill=tear)
        draw.rounded_rectangle((right_eye + 4, eye_y + 7, right_eye + 12, eye_y + 7 + tear_len), radius=3, fill=tear)
    else:
        draw.ellipse((left_eye - 5, eye_y - 5, left_eye + 5, eye_y + 5), fill=eye)
        draw.ellipse((right_eye - 5, eye_y - 5, right_eye + 5, eye_y + 5), fill=eye)

    mouth_y = cy + 14
    if emotion == "happy":
        draw.arc((cx - 18, mouth_y - 6, cx + 18, mouth_y + 12), 10, 170, fill=eye, width=4)
    elif emotion == "sad":
        draw.arc((cx - 16, mouth_y - 5, cx + 16, mouth_y + 8), 200, 340, fill=eye, width=4)
    elif emotion == "sob":
        draw.ellipse((cx - 10, mouth_y - 3, cx + 10, mouth_y + 13), outline=eye, width=4)
        draw.ellipse((cx - 5, mouth_y + 2, cx + 5, mouth_y + 11), fill=dim)
    else:
        draw.arc((cx - 14, mouth_y - 4, cx + 14, mouth_y + 8), 20, 160, fill=eye, width=4)


def draw_shadow(draw: ImageDraw.ImageDraw, cx: int, cy: int, width: int, height: int, alpha: int = 110):
    draw.ellipse(
        (cx - width // 2, cy - height // 2, cx + width // 2, cy + height // 2),
        fill=(4, 22, 25, alpha),
    )


def draw_knot_creature(
    canvas: Image.Image,
    emotion: str,
    frame: int,
    *,
    cx: int,
    cy: int,
    size: float = 1.0,
    rotation: float = 0.0,
    squash_x: float = 1.0,
    squash_y: float = 1.0,
    with_feet: bool = True,
    add_sparkle: bool = False,
):
    draw = ImageDraw.Draw(canvas)
    draw_shadow(draw, cx, cy + int(34 * size), int(74 * size * squash_x), int(16 * size), alpha=90)

    band_w = max(18, int(18 * size * squash_x))
    band_h = max(42, int(42 * size * squash_y))
    orbit = max(38, int(38 * size))

    for angle in [0, 60, 120, 180, 240, 300]:
        draw_segment(canvas, cx, cy, orbit, angle + rotation, band_w, band_h)

    face_cy = cy + int(2 * size)
    blink = emotion in {"neutral", "happy"} and frame == 4
    draw_face(draw, cx, face_cy, emotion, frame, size, blink=blink)

    if with_feet:
        draw_feet(draw, cx, cy, size, frame)

    if add_sparkle or emotion == "happy":
        draw_sparkle(draw, cx + int(28 * size), cy - int(28 * size), COLORS["spark"], size=3)
    if emotion == "sob":
        draw.rounded_rectangle(
            (cx + int(29 * size), cy + int(8 * size), cx + int(34 * size), cy + int(22 * size)),
            radius=3,
            fill=COLORS["tear"],
        )


def draw_typing_bubble(draw: ImageDraw.ImageDraw, x: int, y: int, frame: int, emotion: str):
    draw.rounded_rectangle((x, y, x + 76, y + 52), radius=10, fill=COLORS["bubble_fill"], outline=COLORS["bubble_outline"], width=4)
    draw.polygon([(x + 14, y + 52), (x + 26, y + 52), (x + 18, y + 64)], fill=COLORS["bubble_fill"], outline=COLORS["bubble_outline"])

    if emotion == "happy":
        glyphs = [">", "*", ">"]
        color = COLORS["accent"]
    elif emotion in {"sad", "sob"}:
        glyphs = ["...", "...", "..."]
        color = COLORS["face_dim"]
    else:
        glyphs = [">", "_", ">"]
        color = COLORS["bubble_outline"]

    active = (frame % 3) + 1
    for index in range(active):
        gx = x + 16 + index * 18
        gy = y + 22
        glyph = glyphs[index]
        if glyph == "...":
            draw.ellipse((gx, gy, gx + 6, gy + 6), fill=color)
        elif glyph == "*":
            draw_sparkle(draw, gx, gy - 2, color, size=3)
        elif glyph == "_":
            draw.line((gx, gy + 5, gx + 10, gy + 5), fill=color, width=4)
        else:
            draw.line((gx, gy, gx + 10, gy + 5), fill=color, width=4)
            draw.line((gx, gy + 10, gx + 10, gy + 5), fill=color, width=4)


def draw_waiting_bubble(draw: ImageDraw.ImageDraw, x: int, y: int, frame: int, emotion: str):
    draw.rounded_rectangle((x, y, x + 58, y + 60), radius=12, fill=COLORS["bubble_fill"], outline=COLORS["bubble_outline"], width=4)
    draw.polygon([(x + 16, y + 60), (x + 28, y + 60), (x + 20, y + 70)], fill=COLORS["bubble_fill"], outline=COLORS["bubble_outline"])

    if emotion == "happy":
        color = COLORS["accent"]
        draw.line((x + 22, y + 18, x + 22, y + 34), fill=color, width=4)
        draw.line((x + 34, y + 18, x + 34, y + 34), fill=color, width=4)
        draw.arc((x + 20, y + 30, x + 36, y + 46), 20, 160, fill=color, width=4)
    elif emotion == "sad":
        color = COLORS["face_dim"]
        draw.ellipse((x + 18, y + 24, x + 24, y + 30), fill=color)
        draw.ellipse((x + 27, y + 24 + (frame % 2) * 2, x + 33, y + 30 + (frame % 2) * 2), fill=color)
        draw.ellipse((x + 36, y + 24, x + 42, y + 30), fill=color)
    elif emotion == "sob":
        color = COLORS["alert"]
        shake = (frame % 2) * 2
        draw.line((x + 28 + shake, y + 15, x + 28 + shake, y + 37), fill=color, width=5)
        draw.ellipse((x + 25 + shake, y + 42, x + 31 + shake, y + 48), fill=color)
    else:
        color = COLORS["bubble_outline"]
        for index in range(3):
            dot_x = x + 18 + index * 12
            dot_y = y + 27 + (2 if index == frame % 3 else 0)
            draw.ellipse((dot_x, dot_y, dot_x + 6, dot_y + 6), fill=color)


def draw_sleep_zs(draw: ImageDraw.ImageDraw, frame: int):
    z_sets = [
        [(154, 34)],
        [(154, 34), (176, 24)],
        [(154, 34), (176, 24)],
        [(154, 34), (176, 24), (195, 16)],
        [(176, 24), (195, 16)],
        [(176, 24)],
    ][frame]
    for index, (x, y) in enumerate(z_sets):
        size = 14 - index * 2
        draw.line((x, y, x + size, y), fill=COLORS["sleep"], width=3)
        draw.line((x + size, y, x, y + size), fill=COLORS["sleep"], width=3)
        draw.line((x, y + size, x + size, y + size), fill=COLORS["sleep"], width=3)


def render_idle_frame(emotion: str, frame: int) -> Image.Image:
    canvas = new_canvas()
    bounce = [0, -3, 0, 2, 0, -2][frame]
    tilt = [0, 4, 0, -4, 0, 3][frame]
    draw_knot_creature(canvas, emotion, frame, cx=128, cy=148 + bounce, rotation=tilt, size=1.92)
    return downsample(canvas)


def render_working_frame(emotion: str, frame: int) -> Image.Image:
    canvas = new_canvas()
    bounce = [0, -2, 0, -2, 0, 1][frame]
    tilt = [0, 6, 3, -2, -4, 1][frame]
    draw_knot_creature(canvas, emotion, frame, cx=100, cy=150 + bounce, rotation=tilt, size=1.68)
    draw = ImageDraw.Draw(canvas)
    draw_typing_bubble(draw, 156, 18 + (frame % 2) * 2, frame, emotion)
    return downsample(canvas)


def render_waiting_frame(emotion: str, frame: int) -> Image.Image:
    canvas = new_canvas()
    tilt = [0, 2, 0, -2, 0, 2][frame]
    draw_knot_creature(canvas, emotion, frame, cx=100, cy=150, rotation=tilt, size=1.68)
    draw = ImageDraw.Draw(canvas)
    draw_waiting_bubble(draw, 164 + (frame % 2) * 2, 16, frame, emotion)
    return downsample(canvas)


def render_sleeping_frame(emotion: str, frame: int) -> Image.Image:
    canvas = new_canvas()
    draw_knot_creature(
        canvas,
        emotion,
        frame,
        cx=110,
        cy=176,
        rotation=90,
        size=1.46,
        squash_x=1.18,
        squash_y=0.72,
        with_feet=False,
    )
    draw = ImageDraw.Draw(canvas)
    draw_sleep_zs(draw, frame)
    return downsample(canvas)


def render_compacting_frame(emotion: str, frame: int) -> Image.Image:
    canvas = new_canvas()
    phases = [
        (1.92, 0, 148, True),
        (1.45, 10, 158, True),
        (1.02, 18, 166, False),
        (0.66, 30, 174, False),
        (0.36, 42, 182, False),
    ]
    size, rotation, cy, feet = phases[frame]
    draw_knot_creature(
        canvas,
        emotion,
        frame,
        cx=128,
        cy=cy,
        rotation=rotation,
        size=size,
        squash_x=1.0,
        squash_y=max(0.65, size),
        with_feet=feet,
        add_sparkle=frame >= 3,
    )
    if frame >= 2:
        draw = ImageDraw.Draw(canvas)
        draw_sparkle(draw, 72, 154 - frame * 6, COLORS["accent_soft"], size=3)
        draw_sparkle(draw, 184, 148 - frame * 4, COLORS["spark"], size=2)
    return downsample(canvas)


SPRITE_VARIANTS = {
    "idle": {"frames": 6, "renderer": render_idle_frame},
    "working": {"frames": 6, "renderer": render_working_frame},
    "waiting": {"frames": 6, "renderer": render_waiting_frame},
    "sleeping": {"frames": 6, "renderer": render_sleeping_frame},
    "compacting": {"frames": 5, "renderer": render_compacting_frame},
}


def write_imageset(name: str, image: Image.Image):
    imageset_dir = ASSETS_ROOT / f"{name}.imageset"
    imageset_dir.mkdir(parents=True, exist_ok=True)
    image.save(imageset_dir / "sprite_sheet.png")
    (imageset_dir / "Contents.json").write_text(json.dumps(CONTENTS_JSON, indent=2) + "\n")


def build_sheet(frames: int, renderer, emotion: str) -> Image.Image:
    sheet = Image.new("RGBA", (FRAME_SIZE * frames, FRAME_SIZE), (0, 0, 0, 0))
    for frame in range(frames):
        sheet.alpha_composite(renderer(emotion, frame), dest=(frame * FRAME_SIZE, 0))
    return sheet


def main():
    for task, config in SPRITE_VARIANTS.items():
        for emotion in EMOTIONS:
            name = f"codex_{task}_{emotion}"
            write_imageset(name, build_sheet(config["frames"], config["renderer"], emotion))


if __name__ == "__main__":
    main()
