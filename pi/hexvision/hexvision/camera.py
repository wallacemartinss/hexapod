"""Camera model: pixels -> angles, and the camera matrix for pose estimates.

Without a calibration file the lens is taken as a pinhole with the given
horizontal field of view: fine near the centre, a few degrees off at the
edges of the 120-degree lens. With one (made by the calibration tool, F0)
the distortion is removed first and the angles and distances are measured.
"""

import json
import math
from dataclasses import dataclass

import numpy as np


@dataclass
class Camera:
    width: int
    height: int
    matrix: np.ndarray  # 3x3 intrinsics for this image size
    dist: np.ndarray  # distortion coefficients (zeros: pinhole)
    calibrated: bool

    @classmethod
    def pinhole(cls, width, height, hfov_deg):
        f = (width / 2) / math.tan(math.radians(hfov_deg) / 2)
        m = np.array([[f, 0, width / 2], [0, f, height / 2], [0, 0, 1]], dtype=np.float64)
        return cls(width, height, m, np.zeros(5), False)

    @classmethod
    def from_file(cls, path, width, height):
        """A calibration JSON ({width, height, matrix, dist}), scaled to width x height."""
        with open(path) as f:
            c = json.load(f)
        s = width / c["width"]
        if abs(height / c["height"] - s) > 0.01:
            raise ValueError("calibration made for another aspect ratio")
        m = np.array(c["matrix"], dtype=np.float64)
        m[:2] *= s
        return cls(width, height, m, np.array(c["dist"], dtype=np.float64), True)

    def angles(self, u, v):
        """(bearing, elevation) in degrees of pixel (u, v).

        bearing + = to the robot's left (image left), elevation + = up.
        """
        import cv2

        p = np.array([[[u, v]]], dtype=np.float64)
        xn, yn = cv2.undistortPoints(p, self.matrix, self.dist)[0, 0]
        return -math.degrees(math.atan(xn)), -math.degrees(math.atan(yn))
