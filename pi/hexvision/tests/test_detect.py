"""Synthetic images: a marker of known size placed by a known camera."""

import math
import unittest

import cv2
import numpy as np

from hexvision.camera import Camera
from hexvision.detect import DICTIONARY, MarkerFinder

W, H = 960, 540
SIZE = 0.05  # m


def scene(marker_id, distance_m, bearing_deg, camera):
    """White image with the marker facing the camera at that distance and bearing."""
    img = np.full((H, W), 255, np.uint8)
    f = camera.matrix[0, 0]
    side = f * SIZE / distance_m  # px of the black square
    marker = cv2.aruco.generateImageMarker(cv2.aruco.getPredefinedDictionary(DICTIONARY), marker_id, 120)
    # 4x4 + border = 6 cells: the black square is the whole generated image.
    px = max(6, int(round(side)))
    m = cv2.resize(marker, (px, px), interpolation=cv2.INTER_NEAREST)
    cx = W / 2 - f * math.tan(math.radians(bearing_deg))  # + bearing = image left
    x0, y0 = int(round(cx - px / 2)), int(round(H / 2 - px / 2))
    img[y0 : y0 + px, x0 : x0 + px] = m
    return img


class DetectTest(unittest.TestCase):
    def setUp(self):
        self.camera = Camera.pinhole(W, H, 100)
        self.finder = MarkerFinder(self.camera, SIZE)

    def test_centred_marker(self):
        found = self.finder.find(scene(7, 1.0, 0, self.camera))
        self.assertEqual(len(found), 1)
        t = found[0]
        self.assertEqual(t.marker_id, 7)
        self.assertEqual(t.track_id, 8)
        self.assertAlmostEqual(t.bearing_deg, 0, delta=1)
        self.assertAlmostEqual(t.distance_m, 1.0, delta=0.08)
        self.assertTrue(0 < t.x < 0.5 < t.x + t.w < 1)

    def test_bearing_sign_is_left_positive(self):
        left = self.finder.find(scene(3, 1.0, 20, self.camera))[0]
        right = self.finder.find(scene(3, 1.0, -20, self.camera))[0]
        self.assertAlmostEqual(left.bearing_deg, 20, delta=1.5)
        self.assertAlmostEqual(right.bearing_deg, -20, delta=1.5)
        self.assertLess(left.x, 0.5)

    def test_distance_follows_size(self):
        near = self.finder.find(scene(1, 0.6, 0, self.camera))[0]
        far = self.finder.find(scene(1, 1.6, 0, self.camera))[0]
        self.assertAlmostEqual(near.distance_m, 0.6, delta=0.05)
        self.assertAlmostEqual(far.distance_m, 1.6, delta=0.2)
        self.assertGreater(near.confidence, far.confidence)

    def test_phone_marker_seen_at_two_metres(self):
        # ~5 cm on a phone screen, 2 m away, 960 px wide: about 12 px a side.
        self.assertEqual(len(self.finder.find(scene(0, 2.0, 0, self.camera))), 1)

    def test_nothing_in_an_empty_image(self):
        self.assertEqual(self.finder.find(np.full((H, W), 255, np.uint8)), [])

    def test_calibration_scales_with_the_image(self):
        import json
        import tempfile

        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({"width": 1920, "height": 1080, "matrix": [[1000, 0, 960], [0, 1000, 540], [0, 0, 1]], "dist": [0, 0, 0, 0, 0]}, f)
        cam = Camera.from_file(f.name, 960, 540)
        self.assertTrue(cam.calibrated)
        self.assertAlmostEqual(cam.matrix[0, 0], 500)
        self.assertAlmostEqual(cam.angles(480, 270)[0], 0, places=5)
        with self.assertRaises(ValueError):
            Camera.from_file(f.name, 640, 480)  # 4:3 from a 16:9 calibration


if __name__ == "__main__":
    unittest.main()
