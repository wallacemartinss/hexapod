"""Distance to a person from a box: the feet on the floor, or the body's height."""

import math
import unittest

from hexvision.camera import Camera
from hexvision.people import PERSON_HEIGHT_M, measure

W, H = 960, 720
CAM_H = 0.15  # m above the floor


def box(camera, distance_m, top_m, bottom_m=0.0, pitch_deg=0.0, half_width_px=40):
    """Image box of a person at distance_m in front of the camera, from
    bottom_m to top_m above the floor (cut to the image)."""
    f, cy = camera.matrix[1, 1], camera.matrix[1, 2]
    p = math.radians(pitch_deg)

    def v(z):
        angle = math.atan2(z - CAM_H, distance_m) - p  # elevation seen by the tilted camera
        return cy - f * math.tan(angle)

    y0, y1 = max(0.0, v(top_m)), min(float(H), v(bottom_m))
    return (W / 2 - half_width_px, y0, W / 2 + half_width_px, y1)


class MeasureTest(unittest.TestCase):
    def setUp(self):
        self.camera = Camera.pinhole(W, H, 100)

    def test_close_up_the_head_is_cut_but_the_feet_give_the_distance(self):
        b = box(self.camera, 1.2, PERSON_HEIGHT_M)
        self.assertEqual(b[1], 0.0, "the test should cut the head")
        bearing, _, d = measure(self.camera, b, CAM_H)
        self.assertAlmostEqual(bearing, 0, delta=0.5)
        self.assertAlmostEqual(d, 1.2, delta=0.05)

    def test_a_tilted_camera_is_corrected(self):
        b = box(self.camera, 1.5, PERSON_HEIGHT_M, pitch_deg=10)
        self.assertAlmostEqual(measure(self.camera, b, CAM_H, 10)[2], 1.5, delta=0.05)
        # Ignoring the tilt would be well off.
        self.assertGreater(abs(measure(self.camera, b, CAM_H, 0)[2] - 1.5), 0.3)

    def test_far_away_the_whole_body_gives_it(self):
        # 4 m: the feet are too close to the horizon, the body fits.
        b = box(self.camera, 4.0, PERSON_HEIGHT_M)
        self.assertGreater(b[1], 0)
        self.assertAlmostEqual(measure(self.camera, b, CAM_H)[2], 4.0, delta=0.3)

    def test_feet_cut_is_unknown(self):
        b = box(self.camera, 0.12, 1.0)  # legs only, feet below the bottom edge
        self.assertEqual(b[3], H)
        self.assertEqual(measure(self.camera, b, CAM_H)[2], 0.0)

    def test_off_centre_is_measured_along_the_floor(self):
        f = self.camera.matrix[0, 0]
        b = list(box(self.camera, 1.0, PERSON_HEIGHT_M))
        shift = f * math.tan(math.radians(30))  # 30 deg to the left, 1 m ahead
        b[0] -= shift
        b[2] -= shift
        bearing, _, d = measure(self.camera, b, CAM_H)
        self.assertAlmostEqual(bearing, 30, delta=0.5)
        self.assertAlmostEqual(d, 1.0 / math.cos(math.radians(30)), delta=0.05)


if __name__ == "__main__":
    unittest.main()
