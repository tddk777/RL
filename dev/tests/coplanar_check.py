"""Lists visible faces of a generated level that share a plane with another
face facing the same way (z-fighting: they flicker as the camera moves).

    godot --headless --path . res://dev/tests/coplanar_check.tscn -- out.txt [seed]
    python3 dev/tests/coplanar_check.py out.txt

A coplanar overlap only shows when the space in front of it is open, so each
overlap is tested against every recorded solid (boxes and prisms; kit props
merged into the chunks are not solids, so faces inside a prop - a locker's
vents behind its door - can show up here). Pairs of the same material shade
identically and are counted separately. Exit code 1 when visible overlaps
between different materials remain.
"""
import collections
import sys

import numpy as np

MIN_AREA = 1e-3  # m^2 (10 cm^2; smaller slivers do not read)


def load(path):
    mats = {}
    for line in open(path + ".mats"):
        i, n = line.split()
        mats[int(i)] = n
    data = np.loadtxt(path, ndmin=2)
    boxes, prisms = [], []
    for line in open(path + ".solids"):
        f = line.split()
        if f[0] == "B":
            v = list(map(float, f[1:]))
            c = np.array(v[0:3])
            size = np.array(v[3:6])
            basis = np.array([v[6:9], v[9:12], v[12:15]]).T  # columns are the axes
            boxes.append((c, size * 0.5, np.linalg.inv(basis)))
        else:
            y0, y1 = float(f[1]), float(f[2])
            pts = np.array(list(map(float, f[3:]))).reshape(-1, 2)
            prisms.append((y0, y1, pts))
    return mats, data, boxes, prisms


class Solids:
    def __init__(self, boxes, prisms):
        self.boxes = boxes
        self.prisms = prisms
        self.grid = collections.defaultdict(list)
        for i, (c, half, inv) in enumerate(boxes):
            ext = np.abs(np.linalg.inv(inv)) @ half  # world half extents
            self._add(("b", i), c[0] - ext[0], c[2] - ext[2], c[0] + ext[0], c[2] + ext[2])
        for i, (y0, y1, pts) in enumerate(prisms):
            self._add(("p", i), pts[:, 0].min(), pts[:, 1].min(), pts[:, 0].max(), pts[:, 1].max())

    def _add(self, key, x0, z0, x1, z1):
        for gx in range(int(np.floor(x0 / 2)), int(np.floor(x1 / 2)) + 1):
            for gz in range(int(np.floor(z0 / 2)), int(np.floor(z1 / 2)) + 1):
                self.grid[(gx, gz)].append(key)

    def inside(self, q, eps=1e-4):
        for kind, i in self.grid.get((int(np.floor(q[0] / 2)), int(np.floor(q[2] / 2))), ()):
            if kind == "b":
                c, half, inv = self.boxes[i]
                local = inv @ (q - c)
                if np.all(np.abs(local) < half - eps):
                    return True
            else:
                y0, y1, pts = self.prisms[i]
                if not (y0 + eps < q[1] < y1 - eps):
                    continue
                inside, sign = True, 0
                for k in range(len(pts)):
                    a, b = pts[k], pts[(k + 1) % len(pts)]
                    cr = (b[0] - a[0]) * (q[2] - a[1]) - (b[1] - a[1]) * (q[0] - a[0])
                    if abs(cr) < 1e-9:
                        inside = False
                        break
                    s = 1 if cr > 0 else -1
                    if sign == 0:
                        sign = s
                    elif s != sign:
                        inside = False
                        break
                if inside:
                    return True
        return False


def clip(poly, a, b):
    out = []
    for i in range(len(poly)):
        p, q = poly[i], poly[(i + 1) % len(poly)]
        cp = (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])
        cq = (b[0] - a[0]) * (q[1] - a[1]) - (b[1] - a[1]) * (q[0] - a[0])
        if cp >= 0:
            out.append(p)
        if (cp > 0 > cq) or (cp < 0 < cq):
            t = cp / (cp - cq)
            out.append((p[0] + t * (q[0] - p[0]), p[1] + t * (q[1] - p[1])))
    return out


def area(poly):
    s = 0.0
    for i in range(len(poly)):
        s += poly[i][0] * poly[(i + 1) % len(poly)][1] - poly[(i + 1) % len(poly)][0] * poly[i][1]
    return s / 2


def main(path):
    mats, data, boxes, prisms = load(path)
    solids = Solids(boxes, prisms)
    mat = data[:, 0].astype(int)
    P = data[:, 1:10].reshape(-1, 3, 3)
    N = data[:, 10:13]
    g = np.cross(P[:, 1] - P[:, 0], P[:, 2] - P[:, 0])
    tri_area = np.linalg.norm(g, axis=1) * 0.5
    ok = tri_area > 1e-5
    gn = np.zeros_like(g)
    gn[ok] = g[ok] / (2 * tri_area[ok])[:, None]
    gn[(gn * N).sum(1) < 0] *= -1
    flat = ok & ((gn * N).sum(1) > 0.999)  # flat-shaded faces (boxes, slabs)
    d = (gn * P[:, 0]).sum(1)
    groups = collections.defaultdict(list)
    kn = np.round(gn * 1000).astype(int)
    kd = np.round(d * 500).astype(int)
    for i in np.nonzero(flat)[0]:
        groups[(kn[i, 0], kn[i, 1], kn[i, 2], kd[i])].append(i)
    visible = collections.Counter()
    same = collections.Counter()
    examples = collections.defaultdict(list)
    for key, idx in groups.items():
        if len(idx) < 2:
            continue
        n = np.array(key[:3], float)
        n /= np.linalg.norm(n)
        a0 = np.array([1.0, 0, 0]) if abs(n[0]) < 0.9 else np.array([0, 1.0, 0])
        u = np.cross(n, a0)
        u /= np.linalg.norm(u)
        v = np.cross(n, u)
        plane_d = key[3] / 500.0
        tris = []
        for i in idx:
            t = [(float(P[i, k] @ u), float(P[i, k] @ v)) for k in range(3)]
            tris.append(t if area(t) > 0 else t[::-1])
        bb = [(min(p[0] for p in t), min(p[1] for p in t), max(p[0] for p in t), max(p[1] for p in t)) for t in tris]
        buckets = collections.defaultdict(list)
        for j, b in enumerate(bb):
            for bx in range(int(np.floor(b[0])), int(np.floor(b[2])) + 1):
                for by in range(int(np.floor(b[1])), int(np.floor(b[3])) + 1):
                    buckets[(bx, by)].append(j)
        seen = set()
        for lst in buckets.values():
            for ia in range(len(lst)):
                for ib in range(ia + 1, len(lst)):
                    A, B = lst[ia], lst[ib]
                    if (A, B) in seen:
                        continue
                    seen.add((A, B))
                    ba, bb2 = bb[A], bb[B]
                    if ba[2] <= bb2[0] + 1e-3 or bb2[2] <= ba[0] + 1e-3 or ba[3] <= bb2[1] + 1e-3 or bb2[3] <= ba[1] + 1e-3:
                        continue
                    poly = tris[A]
                    for k in range(3):
                        poly = clip(poly, tris[B][k], tris[B][(k + 1) % 3])
                        if not poly:
                            break
                    if not poly or area(poly) < MIN_AREA:
                        continue
                    cx = sum(p[0] for p in poly) / len(poly)
                    cy = sum(p[1] for p in poly) / len(poly)
                    q = n * plane_d + u * cx + v * cy
                    if solids.inside(q + n * 0.004) or (q + n * 0.004)[1] < -0.06 or (n[1] < -0.9 and q[1] < 0.07):
                        continue  # covered, underground, or under something sitting on the ground
                    ma, mb = mats[mat[idx[A]]], mats[mat[idx[B]]]
                    pair = tuple(sorted((ma, mb)))
                    target = same if ma == mb else visible
                    target[pair] += 1
                    if len(examples[pair]) < 4:
                        examples[pair].append((np.round(q, 2).tolist(), np.round(n, 2).tolist(), round(area(poly), 4)))
    print("visible coplanar overlaps, different materials: %d" % sum(visible.values()))
    for pair, c in visible.most_common(30):
        print("  %5d %s e.g. %s" % (c, pair, examples[pair][:3]))
    print("visible coplanar overlaps, same material (shade alike): %d" % sum(same.values()))
    for pair, c in same.most_common(10):
        print("  %5d %s e.g. %s" % (c, pair, examples[pair][:2]))
    return 1 if visible else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
