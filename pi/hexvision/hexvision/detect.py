"""ArUco marker detection: image -> targets (box, angles, distance).

Works with OpenCV 4.6 (Raspberry Pi OS Bookworm, cv2.aruco.detectMarkers)
and 4.7+ (cv2.aruco.ArucoDetector).
"""

import math
from dataclasses import dataclass

import cv2
import numpy as np

DICTIONARY = cv2.aruco.DICT_4X4_50  # big cells: readable small and blurred


@dataclass
class Found:
    track_id: int
    marker_id: int  # 0 for people
    x: float  # box, normalized 0..1
    y: float
    w: float
    h: float
    bearing_deg: float
    elevation_deg: float
    distance_m: float  # 0 = unknown
    confidence: float
    person: bool = False


class MarkerFinder:
    def __init__(self, camera, marker_size_m):
        self.camera = camera
        self.marker_size_m = marker_size_m
        dictionary = cv2.aruco.getPredefinedDictionary(DICTIONARY)
        if hasattr(cv2.aruco, "ArucoDetector"):
            params = cv2.aruco.DetectorParameters()
        else:
            params = cv2.aruco.DetectorParameters_create()
        # A marker on a phone screen is small: accept down to ~7 px a side
        # at 960 px wide (the default 0.03 needs twice that).
        params.minMarkerPerimeterRate = 0.02
        params.cornerRefinementMethod = cv2.aruco.CORNER_REFINE_SUBPIX
        if hasattr(cv2.aruco, "ArucoDetector"):
            detector = cv2.aruco.ArucoDetector(dictionary, params)
            self._detect = detector.detectMarkers
        else:
            self._detect = lambda img: cv2.aruco.detectMarkers(img, dictionary, parameters=params)
        s = marker_size_m / 2  # corners in the marker's own frame, as ArUco orders them
        self._object = np.array([[-s, s, 0], [s, s, 0], [s, -s, 0], [-s, -s, 0]], dtype=np.float64)

    def find(self, image):
        """Markers in a BGR or grey image the size of self.camera."""
        grey = image if image.ndim == 2 else cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
        corners, ids, _ = self._detect(grey)
        out = []
        if ids is None:
            return out
        cam = self.camera
        for c, marker_id in zip(corners, ids.flatten()):
            pts = c.reshape(4, 2).astype(np.float64)
            x0, y0 = pts.min(axis=0)
            x1, y1 = pts.max(axis=0)
            centre = pts.mean(axis=0)
            bearing, elevation = cam.angles(*centre)
            distance = 0.0
            ok, _, tvec = cv2.solvePnP(self._object, pts, cam.matrix, cam.dist, flags=cv2.SOLVEPNP_IPPE_SQUARE)
            if ok:
                distance = float(np.linalg.norm(tvec))
            # Fewer pixels, less sure: full confidence from 40 px a side.
            side = math.sqrt(max(cv2.contourArea(pts.astype(np.float32)), 0))
            out.append(
                Found(
                    track_id=int(marker_id) + 1,  # 0 means "none" in the contract
                    marker_id=int(marker_id),
                    x=float(x0 / cam.width),
                    y=float(y0 / cam.height),
                    w=float((x1 - x0) / cam.width),
                    h=float((y1 - y0) / cam.height),
                    bearing_deg=float(bearing),
                    elevation_deg=float(elevation),
                    distance_m=distance,
                    confidence=float(min(1.0, side / 40)),
                )
            )
        return out
