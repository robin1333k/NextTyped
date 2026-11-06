#!/usr/bin/env python3
"""Draw the app icon and the menu bar glyph, and write the asset catalog.

One vector description (the shape lists below) feeds both the SVG source and the PNG renderer, so
the two cannot drift apart. The artwork is original: a text caret followed by a ghost line that
fades out, which is what the app does (it shows the words that come next in fading grey). It
spells no name, because the product name is provisional.

Usage:  python3 scripts/make-icon.py                 # rewrites App/Resources/Assets.xcassets and docs/design/icon/
        python3 scripts/make-icon.py --out <dir>     # writes Assets.xcassets, AppIcon.svg and the previews there
Needs Pillow (pip install pillow). The checked-in PNGs are the output; the build does not run this.
"""
import argparse
import json
import os
import shutil

from PIL import Image, ImageDraw, ImageFilter

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))

# ---- App icon: a 1024 canvas, the tile inset 100 px on each side (macOS icon grid) ----
CANVAS = 1024
TILE = (100, 100, 924, 924)
TILE_RADIUS = 185
GRAD_FROM = (0x3B, 0x2F, 0xC9)   # indigo, top left
GRAD_TO = (0x0E, 0xA5, 0xA0)     # teal, bottom right
# (x0, y0, x1, y1, opacity): the caret, then three ghost words that fade out.
ICON_SHAPES = [
    (276, 330, 340, 694, 1.0),
    (400, 480, 580, 544, 0.88),
    (620, 480, 740, 544, 0.58),
    (780, 480, 840, 544, 0.30),
]

# ---- Menu bar glyph: a 36 px grid (2x of the 18 pt status item); the 1x image halves it ----
GLYPH_GRID = 36
GLYPH_SHAPES = [
    (6, 5, 10, 31, 1.0),
    (14, 16, 25, 20, 1.0),
    (27, 16, 33, 20, 0.45),
]

SLOTS = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]


def hexcolor(rgb):
    return '#%02X%02X%02X' % rgb


def icon_svg():
    r = ''.join(
        f'<rect x="{x0}" y="{y0}" width="{x1 - x0}" height="{y1 - y0}" rx="{(x1 - x0) / 2:g}" '
        f'fill="#fff" fill-opacity="{o}"/>' for x0, y0, x1, y1, o in ICON_SHAPES)
    t = TILE
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {CANVAS} {CANVAS}" width="{CANVAS}" height="{CANVAS}">'
        f'<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">'
        f'<stop offset="0" stop-color="{hexcolor(GRAD_FROM)}"/><stop offset="1" stop-color="{hexcolor(GRAD_TO)}"/></linearGradient>'
        f'<filter id="s" x="-10%" y="-10%" width="120%" height="130%">'
        f'<feDropShadow dx="0" dy="12" stdDeviation="14" flood-color="#000" flood-opacity="0.3"/></filter></defs>'
        f'<rect x="{t[0]}" y="{t[1]}" width="{t[2] - t[0]}" height="{t[3] - t[1]}" rx="{TILE_RADIUS}" fill="url(#g)" filter="url(#s)"/>'
        f'{r}</svg>\n')


def render_icon(ss=2):
    """The 1024 master as RGBA, drawn at `ss` times the size and reduced."""
    n = CANVAS * ss
    grad_x = Image.linear_gradient('L').rotate(90).resize((n, n))  # dark to light, left to right
    grad_y = Image.linear_gradient('L').resize((n, n))
    t = Image.blend(grad_x.transpose(Image.FLIP_LEFT_RIGHT), grad_y, 0.5)
    fill = Image.composite(Image.new('RGB', (n, n), GRAD_TO), Image.new('RGB', (n, n), GRAD_FROM), t)
    mask = Image.new('L', (n, n), 0)
    ImageDraw.Draw(mask).rounded_rectangle([v * ss for v in TILE], radius=TILE_RADIUS * ss, fill=255)
    tile = fill.convert('RGBA')
    tile.putalpha(mask)
    shadow = Image.new('RGBA', (n, n), (0, 0, 0, 0))
    shadow_mask = Image.new('L', (n, n), 0)
    off = 12 * ss
    ImageDraw.Draw(shadow_mask).rounded_rectangle(
        [TILE[0] * ss, TILE[1] * ss + off, TILE[2] * ss, TILE[3] * ss + off], radius=TILE_RADIUS * ss, fill=77)
    shadow.putalpha(shadow_mask.filter(ImageFilter.GaussianBlur(14 * ss)))
    out = Image.alpha_composite(shadow, tile)
    for x0, y0, x1, y1, o in ICON_SHAPES:
        layer = Image.new('RGBA', (n, n), (0, 0, 0, 0))
        ImageDraw.Draw(layer).rounded_rectangle(
            [x0 * ss, y0 * ss, x1 * ss, y1 * ss], radius=(x1 - x0) * ss // 2, fill=(255, 255, 255, round(255 * o)))
        out = Image.alpha_composite(out, layer)
    return out.resize((CANVAS, CANVAS), Image.LANCZOS)


def render_glyph(px, ss=16):
    """Black template glyph at px x px; alpha carries the shape."""
    n = px * ss
    k = n / GLYPH_GRID
    out = Image.new('RGBA', (n, n), (0, 0, 0, 0))
    for x0, y0, x1, y1, o in GLYPH_SHAPES:
        layer = Image.new('RGBA', (n, n), (0, 0, 0, 0))
        ImageDraw.Draw(layer).rounded_rectangle(
            [x0 * k, y0 * k, x1 * k, y1 * k], radius=(x1 - x0 if x1 - x0 < y1 - y0 else y1 - y0) * k / 2,
            fill=(0, 0, 0, round(255 * o)))
        out = Image.alpha_composite(out, layer)
    return out.resize((px, px), Image.LANCZOS)


def write_json(path, obj):
    with open(path, 'w') as f:
        json.dump(obj, f, indent=2)
        f.write('\n')


def write_catalog(cat, master):
    shutil.rmtree(cat, ignore_errors=True)
    info = {'info': {'author': 'xcode', 'version': 1}}
    os.makedirs(cat)
    write_json(os.path.join(cat, 'Contents.json'), info)
    d = os.path.join(cat, 'AppIcon.appiconset')
    os.makedirs(d)
    images = []
    for pt, scale in SLOTS:
        name = f'icon_{pt}x{pt}@{scale}x.png'
        master.resize((pt * scale, pt * scale), Image.LANCZOS).save(os.path.join(d, name))
        images.append({'idiom': 'mac', 'size': f'{pt}x{pt}', 'scale': f'{scale}x', 'filename': name})
    write_json(os.path.join(d, 'Contents.json'), {'images': images, **info})
    g = os.path.join(cat, 'MenuBarGlyph.imageset')
    os.makedirs(g)
    render_glyph(18).save(os.path.join(g, 'glyph@1x.png'))
    render_glyph(36).save(os.path.join(g, 'glyph@2x.png'))
    write_json(os.path.join(g, 'Contents.json'), {
        'images': [{'idiom': 'universal', 'scale': '1x', 'filename': 'glyph@1x.png'},
                   {'idiom': 'universal', 'scale': '2x', 'filename': 'glyph@2x.png'}],
        'properties': {'template-rendering-intent': 'template'}, **info})


def write_previews(out, master):
    sheet = Image.new('RGBA', (860, 560), (236, 236, 238, 255))
    x = 24
    for size in (512, 192, 64, 32):
        sheet.alpha_composite(master.resize((size, size), Image.LANCZOS), (x, 24 if size == 512 else 24 + (512 - size)))
        x += size + 24
    sheet.save(os.path.join(out, 'app-icon-preview.png'))
    glyph = render_glyph(36)
    big = render_glyph(144)
    w, h = 330, 170
    prev = Image.new('RGBA', (w * 2, h), (0, 0, 0, 255))
    for i, (bg, fg) in enumerate((((236, 236, 238), 0), ((40, 40, 44), 255))):
        pane = Image.new('RGBA', (w, h), bg + (255,))
        for im, pos in ((glyph, (30, 67)), (big, (150, 13))):
            ink = Image.new('RGBA', im.size, (fg, fg, fg, 255))
            ink.putalpha(im.getchannel('A'))
            pane.alpha_composite(ink, pos)
        prev.paste(pane, (i * w, 0))
    prev.save(os.path.join(out, 'menu-bar-glyph-preview.png'))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', help='write everything here instead of the repo')
    out = ap.parse_args().out
    master = render_icon()
    if out:
        os.makedirs(out, exist_ok=True)
        write_catalog(os.path.join(out, 'Assets.xcassets'), master)
        docs = out
    else:
        write_catalog(os.path.join(REPO, 'App/Resources/Assets.xcassets'), master)
        docs = os.path.join(REPO, 'docs/design/icon')
        os.makedirs(docs, exist_ok=True)
    with open(os.path.join(docs, 'AppIcon.svg'), 'w') as f:
        f.write(icon_svg())
    write_previews(docs, master)


if __name__ == '__main__':
    main()
