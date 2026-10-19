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


class PersonFinder:
    def __init__(self, camera, model_dir, min_confidence=0.5):
        self.camera = camera
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
        """(bearing, elevation, distance_m) of a box: the angles of its centre;
        the distance from its height, only when the whole body fits (the box
        does not touch the top or bottom of the image), else 0 = unknown."""
        x0, y0, x1, y1 = box[:4]
        cam = self.camera
        bearing, elevation = cam.angles((x0 + x1) / 2, (y0 + y1) / 2)
        distance = 0.0
        margin = cam.height * 0.02
        if y0 > margin and y1 < cam.height - margin:
            # Angle the body spans, from the top and bottom edges' elevations.
            top = math.radians(cam.angles((x0 + x1) / 2, y0)[1])
            bottom = math.radians(cam.angles((x0 + x1) / 2, y1)[1])
            span = math.tan(top) - math.tan(bottom)
            if span > 0:
                distance = PERSON_HEIGHT_M / span
        return bearing, elevation, distance
