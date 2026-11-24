"""在 macOS 上用 Seven 原始图标重建柴犬头部网格与贴图。"""
import math
import struct
import subprocess
import tempfile
from collections import Counter, deque
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SIZE = 512


def build(directory):
    def run(*args):
        subprocess.run(args, cwd=directory, check=True, stdout=subprocess.DEVNULL)

    run("sips", "-z", str(SIZE), str(SIZE), "-s", "format", "bmp",
        str(ROOT / "Resources/Seven.png"), "--out", "fur.bmp")
    bitmap = bytearray((directory / "fur.bmp").read_bytes())
    offset = struct.unpack_from("<I", bitmap, 10)[0]
    assert struct.unpack_from("<ii", bitmap, 18) == (SIZE, -SIZE)
    assert struct.unpack_from("<H", bitmap, 28)[0] == 24

    def pixel(x, y):
        return offset + (y * SIZE + x) * 3

    # Remove the painted eyes. The scene supplies sclera, iris and corneal highlights.
    for cx in (111, 210):
        for py in range(SIZE):
            y = (py + 0.5) * 320 / SIZE
            for px in range(int((cx-21)*SIZE/320), int((cx+21)*SIZE/320)):
                x = (px + 0.5) * 320 / SIZE
                radius = math.hypot((x-cx)/20, (y-152)/18)
                if radius >= 1:
                    continue
                weight = min(1, (1-radius)/0.13)
                t = (x-cx+21)/42
                left = pixel(int((cx-21)*SIZE/320), py)
                right = pixel(int((cx+21)*SIZE/320), py)
                index = pixel(px, py)
                for c in range(3):
                    fur = (1-t)*bitmap[left+c] + t*bitmap[right+c]
                    bitmap[index+c] = round(bitmap[index+c]*(1-weight) + fur*weight)

    # Sample the silhouette in icon coordinates. Flood only from outside so highlights
    # and pale patches of fur cannot punch holes in the mesh.
    size = 128
    grid = range(size)
    outside = set()
    queue = deque([(0, 0)])
    while queue:
        x, y = queue.popleft()
        if not (0 <= x < size and 0 <= y < size) or (x, y) in outside:
            continue
        i = pixel(int(x*SIZE/size), int(y*SIZE/size))
        b, g, r = bitmap[i:i+3]
        if r-b > 17:
            continue
        outside.add((x, y))
        queue.extend(((x-1,y), (x+1,y), (x,y-1), (x,y+1)))

    # Distance to the silhouette supplies the rounded rim of the skull and ears.
    distance = {(x,y): 0 if (x,y) in outside else size for y in grid for x in grid}
    for step in (1, -1):
        seq = grid if step == 1 else reversed(grid)
        for y in seq:
            for x in (grid if step == 1 else reversed(grid)):
                distance[x,y] = min(distance[x,y], distance.get((x-step,y),0)+1,
                                    distance.get((x,y-step),0)+1,
                                    distance.get((x-step,y-step),0)+math.sqrt(2),
                                    distance.get((x+step,y-step),0)+math.sqrt(2))
    # Extend the original fur over the front rim. The rear projection inherits
    # that rim color and fades to orange on the side of the head.
    rear_stops = [(255, 190, 80), (252, 162, 37), (225, 122, 20)]
    atlas_width = SIZE * 2
    atlas = bytearray(bitmap[:offset])
    struct.pack_into("<I", atlas, 2, offset + atlas_width * SIZE * 3)
    struct.pack_into("<i", atlas, 18, atlas_width)
    struct.pack_into("<I", atlas, 34, atlas_width * SIZE * 3)
    for py in range(SIZE):
        t = min(1, max(0, (py / SIZE - 0.12) / 0.76)) * 2
        stop = min(1, int(t))
        orange = tuple(round(rear_stops[stop][c] * (1-t+stop) + rear_stops[stop+1][c] * (t-stop))
                       for c in (2, 1, 0))
        front_row, rear_row = bytearray(), bytearray()
        for px in range(SIZE):
            gx, gy = px * size / SIZE, py * size / SIZE
            ix, iy = int(gx), int(gy)
            fx, fy = gx - ix, gy - iy
            d = sum(distance.get((ix+dx, iy+dy), 0) * wx * wy
                    for dx, wx in ((0, 1-fx), (1, fx))
                    for dy, wy in ((0, 1-fy), (1, fy)))
            source = bitmap[pixel(px, py):pixel(px, py)+3]
            if d < 2.5:
                # Search inward along the distance gradient to keep the rim
                # free of the white background and retain the cream chin.
                dx = distance.get((ix+2,iy), 0) - distance.get((ix-2,iy), 0)
                dy = distance.get((ix,iy+2), 0) - distance.get((ix,iy-2), 0)
                length = math.hypot(dx, dy)
                if length:
                    step = (2.5 - d) * SIZE / size / length
                    sx = max(0, min(SIZE-1, round(px + dx * step)))
                    sy = max(0, min(SIZE-1, round(py + dy * step)))
                    index = pixel(sx, sy)
                    source = bitmap[index:index+3]
                if source[2] - source[0] <= 17:
                    source = orange
            front_row.extend(source)
            blend = min(1, max(0, (d - 0.65) / 4.8))
            blend *= blend * (3 - 2 * blend)
            rear_row.extend(round(a * (1-blend) + b * blend) for a, b in zip(source, orange))
        atlas.extend(front_row)
        atlas.extend(rear_row)
    (directory / "fur.bmp").write_bytes(atlas)
    run("sips", "-s", "format", "png", "fur.bmp", "--out", "fur.png")

    positions, texcoords, triangles = [], [], []
    front, back = {}, {}
    for (gx, gy), dist in distance.items():
        if not dist:
            continue
        x, y = gx*320/size, gy*320/size
        def bulge(cx, cy, rx, ry):
            return math.exp(-((x-cx)/rx)**2-((y-cy)/ry)**2)
        depth = math.sqrt(max(0, 1-((x-160)/127)**2-((y-173)/111)**2))
        edge = math.sqrt(1 - max(0, 1-(dist-1)*320/size/39)**2)
        muzzle = 25*bulge(160,195,55,44) + 11*bulge(160,175,24,17)
        sockets = 10*(bulge(111,152,20,18)+bulge(210,152,20,18))
        ear_cups = 12*(bulge(70,83,17,35)+bulge(250,83,17,35))
        rear_depth = math.sqrt(max(0, 1-((x-160)/132)**2-((y-169)/121)**2))
        ear_setback = 24 * (bulge(68,74,46,55) + bulge(251,74,46,55))
        for table, z, tile in ((front,(18+62*depth+muzzle-sockets-ear_cups)*edge-ear_setback,0),
                               (back,-(20+96*rear_depth)*edge-ear_setback,1)):
            table[gx,gy] = len(positions)
            positions.append((x-160,160-y,z))
            texcoords.append(((tile*SIZE + 0.5 + gx/size*(SIZE-1))/(2*SIZE), 1-gy/size))
    edges = Counter()
    for x,y in front:
        a,b,c,d = (x,y),(x+1,y),(x,y+1),(x+1,y+1)
        for tri in ((a,c,b),(b,c,d)):
            if all(p in front for p in tri):
                triangles.append(tuple(front[p] for p in tri))
                triangles.append(tuple(back[p] for p in reversed(tri)))
                for i,j in zip(tri,tri[1:]+tri[:1]):
                    edges[i,j] += 1
    rim = {}
    for a,b in edges:
        if (b,a) not in edges:
            rim.setdefault(a, []).append(b)
            rim.setdefault(b, []).append(a)

    # Smooth the rim in three dimensions. Alternating contraction and
    # expansion suppress the grid steps while retaining the ear tips.
    outline = {
        p: (*positions[front[p]][:2], (positions[front[p]][2] + positions[back[p]][2]) / 2)
        for p in rim
    }
    for _ in range(20):
        for weight in (0.60, -0.48):
            outline = {
                point: tuple(value + weight * (
                    sum(outline[n][axis] for n in rim[point]) / len(rim[point]) - value
                ) for axis, value in enumerate(xyz))
                for point, xyz in outline.items()
            }
    for point, (x, y, z) in outline.items():
        positions[front[point]] = (x, y, z + 0.25)
        positions[back[point]] = (x, y, z - 0.25)

    # Smooth sampled depth, keeping the traced outline pinned. This avoids visible
    # lighting bands at the ear roots and on the round cheeks when the head turns.
    for table in (front, back):
        for _ in range(10):
            depths = {}
            for (x,y),i in table.items():
                if (x,y) in rim:
                    continue
                neighbors = [table.get(n,i) for n in ((x-1,y),(x+1,y),(x,y-1),(x,y+1))]
                depths[i] = positions[i][2]*0.35 + sum(positions[n][2] for n in neighbors)*0.65/4
            for i,z in depths.items():
                positions[i] = (*positions[i][:2],z)

    normals = [[0.0]*3 for _ in positions]
    for a,b,c in triangles:
        u = [q-p for p,q in zip(positions[a],positions[b])]
        v = [q-p for p,q in zip(positions[a],positions[c])]
        normal = [u[1]*v[2]-u[2]*v[1], u[2]*v[0]-u[0]*v[2], u[0]*v[1]-u[1]*v[0]]
        for i in (a,b,c):
            for k in range(3):
                normals[i][k] += normal[k]
    for point in rim:
        f, b = front[point], back[point]
        shared = [a + b for a, b in zip(normals[f], normals[b])]
        normals[f] = normals[b] = shared
    normals = [tuple(c/(math.hypot(*n) or 1) for c in n) for n in normals]

    # The narrow seam uses the edge of the front projection on both sides.
    seam = {}
    for point in rim:
        f, b = front[point], back[point]
        seam[point] = len(positions)
        positions.append(positions[b])
        normals.append(normals[b])
        texcoords.append(texcoords[f])
    for a,b in edges:
        if (b,a) not in edges:
            triangles.extend(((front[b],front[a],seam[a]),(front[b],seam[a],seam[b])))

    def vectors(values):
        return ",".join("("+",".join(f"{c:.5f}" for c in v)+")" for v in values)
    asset = '''#usda 1.0
(
    defaultPrim = "Portrait"
    upAxis = "Y"
    metersPerUnit = 0.001
)
def Xform "Portrait" {
    def Mesh "skull" {
        uniform token subdivisionScheme = "none"
        point3f[] points = [POINTS]
        normal3f[] normals = [NORMALS] (interpolation = "vertex")
        int[] faceVertexCounts = [COUNTS]
        int[] faceVertexIndices = [INDICES]
        texCoord2f[] primvars:st = [TEXCOORDS] (interpolation = "vertex")
        rel material:binding = </Portrait/Fur>
    }
    def Material "Fur" {
        token outputs:surface.connect = </Portrait/Fur/Surface.outputs:surface>
        def Shader "Surface" {
            uniform token info:id = "UsdPreviewSurface"
            color3f inputs:diffuseColor.connect = </Portrait/Fur/Color.outputs:rgb>
            float inputs:roughness = 0.84
            token outputs:surface
        }
        def Shader "Color" {
            uniform token info:id = "UsdUVTexture"
            asset inputs:file = @fur.png@
            token inputs:sourceColorSpace = "sRGB"
            float2 inputs:st.connect = </Portrait/Fur/Coords.outputs:result>
            float3 outputs:rgb
        }
        def Shader "Coords" {
            uniform token info:id = "UsdPrimvarReader_float2"
            token inputs:varname = "st"
            float2 outputs:result
        }
    }
}
'''
    asset = asset.replace("POINTS",vectors(positions)).replace("TEXCOORDS",vectors(texcoords))
    asset = asset.replace("NORMALS",vectors(normals))
    asset = asset.replace("COUNTS",",".join(["3"]*len(triangles)))
    asset = asset.replace("INDICES",",".join(str(i) for tri in triangles for i in tri))
    (directory / "portrait.usda").write_text(asset)
    run("usdcat", "portrait.usda", "-o", "portrait.usdc")
    run("usdzip", "Shiba.usdz", "portrait.usdc", "fur.png")
    (ROOT / "Sources/Seven/Art/Shiba.usdz").write_bytes((directory / "Shiba.usdz").read_bytes())


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as scratch:
        build(Path(scratch))
