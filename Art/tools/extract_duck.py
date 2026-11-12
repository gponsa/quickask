"""Cuts the duck frames out of Art/duck-mockup.png (checkerboard baked in) into
transparent PNGs in Resources/Duck/, one same-sized cell per frame.

Run: python3 Art/tools/extract_duck.py
"""
from collections import deque
from PIL import Image

SRC = "Art/duck-mockup.png"
OUT = "Resources/Duck"
NAMES = ["idle", "run", "jump", "fall"]          # rows, top to bottom
PAD = 6                                           # transparent margin in each cell

im = Image.open(SRC).convert("RGB")
W, H = im.size
px = im.load()

def is_bg(p):
    r, g, b = p
    sat = max(p) - min(p)
    lum = (r + g + b) / 3
    return sat < 32 and lum > 95                  # light/mid greys of the checkerboard

# 1. Flood-fill the background from the image border. The black outline of each
#    duck stops the fill, so nothing inside a duck is ever removed.
bg = [[False] * H for _ in range(W)]
q = deque()
for x in range(W):
    for y in (0, H - 1):
        q.append((x, y))
for y in range(H):
    for x in (0, W - 1):
        q.append((x, y))
while q:
    x, y = q.popleft()
    if bg[x][y] or not is_bg(px[x, y]):
        continue
    bg[x][y] = True
    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        nx, ny = x + dx, y + dy
        if 0 <= nx < W and 0 <= ny < H and not bg[nx][ny]:
            q.append((nx, ny))

# 2. Connected blobs of non-background pixels.
seen = [[False] * H for _ in range(W)]
blobs = []
for sx in range(W):
    for sy in range(H):
        if bg[sx][sy] or seen[sx][sy]:
            continue
        pts, yellow = [], 0
        q = deque([(sx, sy)]); seen[sx][sy] = True
        while q:
            x, y = q.popleft()
            pts.append((x, y))
            r, g, b = px[x, y]
            if r > 180 and g > 140 and b < 120:
                yellow += 1
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < W and 0 <= ny < H and not bg[nx][ny] and not seen[nx][ny]:
                        seen[nx][ny] = True
                        q.append((nx, ny))
        xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
        blobs.append(dict(pts=pts, yellow=yellow, box=(min(xs), min(ys), max(xs), max(ys))))

ducks = [b for b in blobs if b["yellow"] > 150]
# Small stray bits (e.g. a detached foot) join the duck whose box they touch.
for b in blobs:
    if b in ducks or len(b["pts"]) < 15:
        continue
    x0, y0, x1, y1 = b["box"]
    for d in ducks:
        X0, Y0, X1, Y1 = d["box"]
        if x0 >= X0 - 8 and x1 <= X1 + 8 and y0 >= Y0 - 8 and y1 <= Y1 + 8:
            d["pts"] += b["pts"]
            break

# 3. Group into rows (animations) by vertical position.
ducks.sort(key=lambda d: (d["box"][1] + d["box"][3]) / 2)
rows, current = [], [ducks[0]]
for d in ducks[1:]:
    prev = current[-1]
    if (d["box"][1] + d["box"][3]) / 2 - (prev["box"][1] + prev["box"][3]) / 2 > 60:
        rows.append(current); current = [d]
    else:
        current.append(d)
rows.append(current)
assert len(rows) == 4, f"expected 4 rows, found {len(rows)}: {[len(r) for r in rows]}"

# 4. Same-sized cells. Each row keeps its ducks' height above that row's "ground"
#    (lowest foot), so a jump frame stays higher than a standing one.
for r in rows:
    r.sort(key=lambda d: d["box"][0])
    ground = max(d["box"][3] for d in r)
    for d in r:
        d["ground"] = ground
cell_w = max(d["box"][2] - d["box"][0] + 1 for r in rows for d in r) + 2 * PAD
cell_h = max(d["ground"] - min(e["box"][1] for e in r) + 1 for r in rows for d in r) + 2 * PAD

import os
os.makedirs(OUT, exist_ok=True)
for f in os.listdir(OUT):
    if f.endswith(".png"):
        os.remove(os.path.join(OUT, f))
for name, r in zip(NAMES, rows):
    for i, d in enumerate(r):
        x0, y0, x1, y1 = d["box"]
        cell = Image.new("RGBA", (cell_w, cell_h), (0, 0, 0, 0))
        cp = cell.load()
        ox = (cell_w - (x1 - x0 + 1)) // 2 - x0       # centre horizontally
        oy = (cell_h - PAD - 1) - d["ground"]          # ground line at the cell's bottom
        for (x, y) in d["pts"]:
            r_, g_, b_ = px[x, y]
            cp[x + ox, y + oy] = (r_, g_, b_, 255)
        cell.save(f"{OUT}/{name}_{i}.png")
    print(name, len(r), "frames")
print("cell size:", cell_w, "x", cell_h)
