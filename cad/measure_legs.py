#!/usr/bin/env python3
"""Measures the leg and body geometry of the hexapod from its STL files.

Joint axes are found by fitting circles to the servo horn and pin holes; the
results feed firmware/include/config.h (geometry section).

Usage (from cad/):
    python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
    .venv/bin/python measure_legs.py            # expects stl/*.stl

STL files are not versioned (designer license); see README.md.
"""

from pathlib import Path

import numpy as np
import trimesh

STL = Path(__file__).parent / "stl"


def circles(mesh, axis, value, rmin=1.0, rmax=12.0):
    """Circular loops (center_a, center_b, radius) on the plane axis=value."""
    i = "xyz".index(axis)
    normal = np.eye(3)[i]
    section = mesh.section(plane_origin=normal * value, plane_normal=normal)
    keep = [k for k in range(3) if k != i]
    found = []
    for loop in section.discrete:
        p = loop[:, keep]
        c = p.mean(0)
        r = np.linalg.norm(p - c, axis=1)
        if r.std() < 0.05 * r.mean() and rmin <= r.mean() <= rmax:
            found.append((c[0], c[1], r.mean()))
    return sorted(found, key=lambda t: -t[2])


def horn_center(mesh, axis, value):
    """Center of the servo horn pattern: the 2.6 mm hole among four 1.5 mm."""
    holes = circles(mesh, axis, value)
    center = [h for h in holes if 2.3 < h[2] < 2.9]
    assert center, f"no horn center on {axis}={value}"
    return np.array(center[0][:2])


def main():
    leg_a = trimesh.load(STL / "Leg_A.stl")
    leg_b = trimesh.load(STL / "Leg_B.stl")
    leg_c = trimesh.load(STL / "Leg_C.stl")
    body = trimesh.load(STL / "Body_eletronica.stl")

    # Leg_A (coxa): coxa horn on the lower arm (axis Z), femur servo shaft
    # through the side wall (axis X).
    coxa_axis = horn_center(leg_a, "z", -27.5)  # (x, y)
    femur_hole = circles(leg_a, "x", -16.5, 5, 8)[0]  # (y, z, r)
    coxa_mm = femur_hole[0] - coxa_axis[1]

    # Leg_B (femur): femur horn on the fork (axis X), knee pin in the box.
    femur_axis = horn_center(leg_b, "x", 28)  # (y, z)
    knee_hole = circles(leg_b, "x", -15, 5, 8)[0]
    femur_mm = femur_axis[0] - knee_hole[0]

    # Leg_C (tibia): knee horn (axis Y); the foot tip is the farthest point.
    knee_axis = horn_center(leg_c, "y", 27.5)  # (x, z)
    xz = leg_c.vertices[:, [0, 2]]
    dist = np.linalg.norm(xz - knee_axis, axis=1)
    tip = xz[dist.argmax()]
    tibia_mm = dist.max()
    # Angle between the bracket's own axis (-Z) and the knee->foot line.
    foot_deg = np.degrees(np.arctan2(-(tip[0] - knee_axis[0]), -(tip[1] - knee_axis[1])))

    # Body: one coxa axis hole per leg in the base plate.
    mounts = [h for h in circles(body, "z", 2, 4, 9)]

    print(f"coxa  (coxa axis -> femur axis): {coxa_mm:7.2f} mm")
    print(f"femur (femur axis -> knee axis): {femur_mm:7.2f} mm")
    print(f"tibia (knee axis -> foot tip):   {tibia_mm:7.2f} mm")
    print(f"foot offset from tibia bracket:  {foot_deg:7.2f} deg")
    print(f"femur axis above coxa horn face: {femur_hole[1] - (-25.0):7.2f} mm")
    print("coxa axes in the body (x, y, radius, angle):")
    for x, y, _ in sorted(mounts, key=lambda m: np.arctan2(m[1], m[0])):
        print(f"  ({x:8.2f}, {y:8.2f})  r={np.hypot(x, y):7.2f}  "
              f"angle={np.degrees(np.arctan2(y, x)):8.2f} deg")


if __name__ == "__main__":
    main()
