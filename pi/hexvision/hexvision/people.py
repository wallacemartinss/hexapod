"""People: MobileNet-SSD (Caffe, PASCAL VOC classes, MIT licence) through
OpenCV's dnn module, so nothing beyond python3-opencv is needed.

Model: github.com/chuanqi305/MobileNet-SSD at a fixed commit, downloaded
by Ansible (or get_models.sh on a PC) and checked by its SHA-256.
"""

import math
import os

import cv2
import numpy as np

MODEL_FILES = ("deploy.prototxt", "mobilenet_iter_73000.caffemodel")
PERSON = 15  # VOC class index
INPUT = 300  # px, the network's square input
PERSON_HEIGHT_M = 1.7  # for a rough distance when the whole body is in view
# Camera above the floor (m) and its tilt (deg, + = up), standing at the
# default body height. TODO: measure on the assembled robot.
CAMERA_HEIGHT_M = 0.15
CAMERA_PITCH_DEG = 0.0


class PersonFinder:
    def __init__(self, camera, model_dir, min_confidence=0.5, height_m=CAMERA_HEIGHT_M, pitch_deg=CAMERA_PITCH_DEG):
        self.camera = camera
        self.height_m, self.pitch_deg = height_m, pitch_deg
        self.min_confidence = min_confidence
        proto, weights = (os.path.join(model_dir, f) for f in MODEL_FILES)
        self.net = cv2.dnn.readNetFromCaffe(proto, weights)

    def detect(self, image):
        """[(x0, y0, x1, y1, confidence)] in pixels of image."""
        h, w = image.shape[:2]
        blob = cv2.dnn.blobFromImage(cv2.resize(image, (INPUT, INPUT)), 0.007843, (INPUT, INPUT), 127.5)
        self.net.setInput(blob)
        out = self.net.forward()[0, 0]  # rows: [_, class, conf, x0, y0, x1, y1] (0..1)
        found = []
        for row in out:
            if int(row[1]) != PERSON or row[2] < self.min_confidence:
                continue
            x0, y0, x1, y1 = (np.clip(row[3:7], 0, 1) * [w, h, w, h]).tolist()
            if x1 - x0 > 4 and y1 - y0 > 4:
                found.append((x0, y0, x1, y1, float(row[2])))
        return found

    def measure(self, box):
        return measure(self.camera, box, self.height_m, self.pitch_deg)


def measure(camera, box, height_m=CAMERA_HEIGHT_M, pitch_deg=CAMERA_PITCH_DEG):
    """(bearing, elevation, distance_m) of a box: the angles of its centre,
    and the distance (0 = unknown):

    - from the feet, where the bottom of the box meets the floor: the
      camera sits low, so up close the feet are in view and the head
      is not;
    - else from its height, when the whole body fits (a rough guess:
      people are not all 1.7 m tall).

    An edge of the box on the edge of the image is cut, not measured.
    """
    x0, y0, x1, y1 = box[:4]
    cam = camera
    u = (x0 + x1) / 2
    bearing, elevation = cam.angles(u, (y0 + y1) / 2)
    margin = cam.height * 0.02
    feet, head = y1 < cam.height - margin, y0 > margin
    distance = 0.0
    if feet:
        distance = cam.ground(u, y1, height_m, pitch_deg)
    if distance == 0 and feet and head:
        # Angle the body spans, from the top and bottom edges' elevations.
        top = math.radians(cam.angles(u, y0)[1])
        bottom = math.radians(cam.angles(u, y1)[1])
        span = math.tan(top) - math.tan(bottom)
        if span > 0:
            distance = PERSON_HEIGHT_M / span
    return bearing, elevation, distance
