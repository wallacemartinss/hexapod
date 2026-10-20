"""Between two slow detections, the box keeps up with a moving person."""

import threading
import time
import unittest

import cv2
import numpy as np

from hexvision.pipeline import PeoplePipeline
from hexvision.tracker import MIN_HITS, PeopleTracker

H, W = 480, 640
rng = np.random.default_rng(1)
# Blotchy like clothes (pixel noise would alias when the tracker scales it down).
PERSON = cv2.resize(rng.integers(0, 255, (10, 4, 3), dtype=np.uint8), (80, 200), interpolation=cv2.INTER_CUBIC)
BACKGROUND = np.full((H, W, 3), 128, np.uint8)


def frame(x):
    img = BACKGROUND.copy()
    img[150:350, x : x + 80] = PERSON
    return img


class SlowFinder:
    """Detector stand-in: exact boxes, but it answers only when released."""

    def __init__(self):
        self.go = threading.Semaphore(0)

    def detect(self, image):
        self.go.acquire()
        # Where the textured block is in that image.
        cols = np.where((image[250] != 128).any(axis=1))[0]
        return [(float(cols[0]), 150.0, float(cols[-1] + 1), 350.0, 0.9)]


class PipelineTest(unittest.TestCase):
    def test_box_follows_between_detections(self):
        finder = SlowFinder()
        p = PeoplePipeline(finder, PeopleTracker())
        x, now = 100, 0.0
        for _ in range(MIN_HITS):  # a few quick detections confirm the person
            p.step(frame(x), now)
            finder.go.release()
            time.sleep(0.05)
            now += 0.1
        got = p.step(frame(x), now)
        self.assertEqual(len(got), 1)
        # Now the detector stalls while the person walks right.
        for _ in range(15):
            x += 6
            now += 0.066
            got = p.step(frame(x), now)
        self.assertEqual(len(got), 1, "lost the person between detections")
        self.assertAlmostEqual(got[0].box[0], x, delta=12)

    def test_box_stays_inside_and_holds_when_the_fast_tracker_loses(self):
        finder = SlowFinder()
        p = PeoplePipeline(finder, PeopleTracker())
        now = 0.0
        for _ in range(MIN_HITS):
            p.step(frame(100), now)
            finder.go.release()
            time.sleep(0.05)
            now += 0.1
        self.assertEqual(len(p.step(frame(100), now)), 1)
        # The person vanishes (the fast tracker has nothing to follow) while
        # the detector is stalled: the box holds for a while, then goes.
        got = p.step(BACKGROUND.copy(), now + 0.5)
        self.assertEqual(len(got), 1)
        x0, y0, x1, y1 = got[0].box
        self.assertTrue(0 <= x0 < x1 <= W and 0 <= y0 < y1 <= H)
        self.assertEqual(p.step(BACKGROUND.copy(), now + 2.0), [])


if __name__ == "__main__":
    unittest.main()
