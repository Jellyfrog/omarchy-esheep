#!/usr/bin/env python3
"""Convert a desktopPet `animations.xml` into the assets this plugin loads.

Upstream (https://github.com/Adrianotiger/desktopPet) ships every pet as a
single XML file with the sprite sheet and the icon base64'd inside it. QML can
neither decode that nor color-key magenta at runtime without a shader, so the
conversion happens here, once, and the plugin ships the result:

    assets/<pet>/pet.json     animations, spawns, childs, sprite metadata
    assets/<pet>/sprites.png  sprite sheet, transparency applied
    assets/<pet>/icon.png     pet icon (when the source has one)

Usage:
    tools/build-pets.py PETS_DIR [--only esheep64,neko] [--out assets]

where PETS_DIR is a checkout of desktopPet's `Pets/` directory, or any
directory holding `<pet>/animations.xml` files.

Requires Pillow. Nothing at runtime requires this script -- generated assets
are committed -- so it is only needed to add or refresh a pet.
"""

import argparse
import base64
import io
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

NS = "{https://esheep.petrucci.ch/}"

# Upstream names transparency by color name; these are the ones the pets in the
# database actually use. Anything else is left to the PNG's own alpha channel.
COLOR_KEYS = {
    "magenta": (255, 0, 255),
    "fuchsia": (255, 0, 255),
    "white": (255, 255, 255),
    "black": (0, 0, 0),
}

# Animations the engine reaches for by name rather than by id.
SPECIAL_NAMES = ("fall", "drag", "kill", "sync")


def text(node, tag, default=None):
    child = node.find(NS + tag) if node is not None else None
    if child is None or child.text is None:
        return default
    return child.text.strip()


def parse_nexts(node):
    """<next probability="20" only="window">11</next> -> list of dicts."""
    out = []
    if node is None:
        return out
    for n in node.findall(NS + "next"):
        target = (n.text or "").strip()
        if not target:
            continue
        entry = {"id": int(target), "probability": int(n.get("probability") or 100)}
        only = (n.get("only") or "").strip().lower()
        if only and only != "none":
            entry["only"] = only
        out.append(entry)
    return out


def parse_step(node, fallback=None):
    """A <start>/<end> block. Values stay strings: they are expressions."""
    if node is None:
        return dict(fallback) if fallback else {"x": "0", "y": "0", "interval": "1000",
                                               "offsetY": "0", "opacity": "1.0"}
    return {
        "x": text(node, "x", "0"),
        "y": text(node, "y", "0"),
        "interval": text(node, "interval", "1000"),
        "offsetY": text(node, "offsety", "0"),
        "opacity": text(node, "opacity", "1.0"),
    }


def parse_animation(node):
    seq_node = node.find(NS + "sequence")
    frames = [int(f.text) for f in seq_node.findall(NS + "frame")] if seq_node is not None else []
    action = text(seq_node, "action", "") if seq_node is not None else ""

    start = parse_step(node.find(NS + "start"))
    animation = {
        "id": int(node.get("id")),
        "name": text(node, "name", ""),
        "start": start,
        # A missing <end> means "hold the start values" rather than "decay to
        # zero" -- the C# reader copies start into end for exactly this case.
        "end": parse_step(node.find(NS + "end"), start),
        "sequence": {
            "repeat": (seq_node.get("repeat") if seq_node is not None else "0") or "0",
            "repeatFrom": int((seq_node.get("repeatfrom") if seq_node is not None else 0) or 0),
            "frames": frames,
            "action": action,
            "next": parse_nexts(seq_node),
        },
    }
    border = parse_nexts(node.find(NS + "border"))
    if border:
        animation["border"] = border
    gravity = parse_nexts(node.find(NS + "gravity"))
    if gravity:
        animation["gravity"] = gravity
    return animation


def parse_spawns(root):
    out = []
    spawns = root.find(NS + "spawns")
    if spawns is None:
        return out
    for s in spawns.findall(NS + "spawn"):
        nexts = parse_nexts(s)
        out.append({
            "id": int(s.get("id") or len(out) + 1),
            "probability": int(s.get("probability") or 1),
            "x": text(s, "x", "0"),
            "y": text(s, "y", "0"),
            "next": nexts,
        })
    return out


def parse_childs(root):
    out = []
    childs = root.find(NS + "childs")
    if childs is None:
        return out
    for c in childs.findall(NS + "child"):
        nexts = parse_nexts(c)
        if not nexts:
            continue
        out.append({
            "animationId": int(c.get("animationid")),
            "x": text(c, "x", "0"),
            "y": text(c, "y", "0"),
            "next": nexts[0]["id"],
        })
    return out


def decode_image(root, out_dir):
    from PIL import Image

    image_node = root.find(NS + "image")
    tiles_x = int(text(image_node, "tilesx", "1"))
    tiles_y = int(text(image_node, "tilesy", "1"))
    raw = base64.b64decode(text(image_node, "png", ""))
    sheet = Image.open(io.BytesIO(raw)).convert("RGBA")

    key = COLOR_KEYS.get((text(image_node, "transparency", "") or "").lower())
    keyed = 0
    if key:
        pixels = sheet.load()
        width, height = sheet.size
        for y in range(height):
            for x in range(width):
                r, g, b, a = pixels[x, y]
                if a and (r, g, b) == key:
                    pixels[x, y] = (r, g, b, 0)
                    keyed += 1

    sheet.save(os.path.join(out_dir, "sprites.png"), optimize=True)
    width, height = sheet.size
    if width % tiles_x or height % tiles_y:
        print(f"  warning: {width}x{height} does not divide evenly into "
              f"{tiles_x}x{tiles_y} tiles", file=sys.stderr)
    return {
        "file": "sprites.png",
        "tilesX": tiles_x,
        "tilesY": tiles_y,
        "width": width,
        "height": height,
        "frameWidth": width // tiles_x,
        "frameHeight": height // tiles_y,
    }, keyed


def decode_icon(root, out_dir):
    """The header icon is a base64 .ico; store it as PNG when Pillow can read it."""
    from PIL import Image

    raw_text = text(root.find(NS + "header"), "icon", "")
    if not raw_text:
        return False
    try:
        icon = Image.open(io.BytesIO(base64.b64decode(raw_text))).convert("RGBA")
    except Exception:
        return False
    icon.save(os.path.join(out_dir, "icon.png"), optimize=True)
    return True


def slugify(name):
    slug = re.sub(r"[^a-z0-9-]+", "-", name.lower()).strip("-")
    return slug or "pet"


def convert(xml_path, out_root, pet_id=None):
    root = ET.parse(xml_path).getroot()
    header = root.find(NS + "header")
    pet_id = pet_id or slugify(os.path.basename(os.path.dirname(xml_path)))
    out_dir = os.path.join(out_root, pet_id)
    os.makedirs(out_dir, exist_ok=True)

    image, keyed = decode_image(root, out_dir)
    has_icon = decode_icon(root, out_dir)

    animations = {}
    for node in root.find(NS + "animations").findall(NS + "animation"):
        animation = parse_animation(node)
        animations[str(animation["id"])] = animation

    special = {}
    for name in SPECIAL_NAMES:
        for animation in animations.values():
            if (animation["name"] or "").strip().lower() == name:
                special[name] = animation["id"]
                break

    pet = {
        "id": pet_id,
        "name": text(header, "petname", pet_id) or pet_id,
        "title": text(header, "title", ""),
        "author": text(header, "author", ""),
        "version": text(header, "version", ""),
        "info": text(header, "info", ""),
        "icon": "icon.png" if has_icon else "",
        "image": image,
        "spawns": parse_spawns(root),
        "animations": animations,
        "childs": parse_childs(root),
        "special": special,
    }

    with open(os.path.join(out_dir, "pet.json"), "w", encoding="utf-8") as handle:
        json.dump(pet, handle, indent=1, sort_keys=True)
        handle.write("\n")

    print(f"{pet_id}: {len(animations)} animations, {len(pet['spawns'])} spawns, "
          f"{len(pet['childs'])} childs, {image['tilesX']}x{image['tilesY']} tiles of "
          f"{image['frameWidth']}x{image['frameHeight']}px"
          + (f", {keyed} px color-keyed" if keyed else ""))
    return pet


def write_index(out_root):
    """The picker in the bar widget reads this: QML cannot list a directory."""
    pets = []
    for name in sorted(os.listdir(out_root)):
        manifest = os.path.join(out_root, name, "pet.json")
        if not os.path.isfile(manifest):
            continue
        with open(manifest, encoding="utf-8") as handle:
            pet = json.load(handle)
        pets.append({
            "id": pet.get("id", name),
            "name": pet.get("name", name),
            "title": pet.get("title", ""),
            "author": pet.get("author", ""),
            "version": pet.get("version", ""),
            "icon": pet.get("icon", ""),
            "frameWidth": pet.get("image", {}).get("frameWidth", 0),
            "frameHeight": pet.get("image", {}).get("frameHeight", 0),
            "animations": len(pet.get("animations", {})),
        })

    with open(os.path.join(out_root, "pets.json"), "w", encoding="utf-8") as handle:
        json.dump({"pets": pets}, handle, indent=1)
        handle.write("\n")
    print(f"index: {len(pets)} pets")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("pets_dir", help="directory holding <pet>/animations.xml")
    parser.add_argument("--out", default="assets", help="output directory (default: assets)")
    parser.add_argument("--only", default="", help="comma-separated pet folders to convert")
    parser.add_argument("--rename", default="",
                        help="comma-separated from=to pairs, e.g. esheep64=esheep")
    args = parser.parse_args()

    renames = dict(pair.split("=", 1) for pair in args.rename.split(",") if "=" in pair)
    wanted = [name for name in args.only.split(",") if name]

    folders = wanted or sorted(
        name for name in os.listdir(args.pets_dir)
        if os.path.isfile(os.path.join(args.pets_dir, name, "animations.xml"))
    )
    if not folders:
        parser.error(f"no pets found under {args.pets_dir}")

    for folder in folders:
        xml_path = os.path.join(args.pets_dir, folder, "animations.xml")
        if not os.path.isfile(xml_path):
            print(f"skipping {folder}: no animations.xml", file=sys.stderr)
            continue
        convert(xml_path, args.out, renames.get(folder, slugify(folder)))

    write_index(args.out)


if __name__ == "__main__":
    main()
