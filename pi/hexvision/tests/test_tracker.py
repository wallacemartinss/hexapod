"""Ids stay with their target; one-frame flukes never get through."""

import unittest

import numpy as np

from hexvision.detect import Found
from hexvision.tracker import MIN_HITS, PERSON_IDS, MarkerConfirm, PeopleTracker

BLANK = np.zeros((480, 640, 3), np.uint8)


def shirt(colour):
    """Image with one person-shaped box whose torso has this BGR colour."""
    img = BLANK.copy()
    img[100:400, 100:200] = colour
    return img


def marker(mid):
    return Found(mid + 1, mid, 0.4, 0.4, 0.1, 0.1, 0, 0, 1, 1)


class TrackerTest(unittest.TestCase):
    def test_needs_a_few_frames_then_keeps_the_id_while_moving(self):
        tr = PeopleTracker()
        out = []
        for i in range(6):
            out.append(tr.update(BLANK, [(100 + 5 * i, 100, 200 + 5 * i, 400, 0.9)], i * 0.1))
        self.assertEqual(out[MIN_HITS - 2], [])  # not yet
        self.assertEqual({t.id for t in out[-1]}, {PERSON_IDS})
        self.assertEqual(out[MIN_HITS - 1][0].id, out[-1][0].id)

    def test_two_people_keep_their_own_ids(self):
        tr = PeopleTracker()
        for i in range(4):
            got = tr.update(BLANK, [(50, 100, 150, 400, 0.9), (400, 100, 500, 400, 0.8)], i * 0.1)
        left = next(t.id for t in got if t.box[0] < 300)
        for i in range(4, 8):  # they walk towards each other a little
            got = tr.update(BLANK, [(400 - 10 * i, 100, 500 - 10 * i, 400, 0.8), (50 + 10 * i, 100, 150 + 10 * i, 400, 0.9)], i * 0.1)
        self.assertEqual(next(t.id for t in got if t.box[0] < 300), left)

    def test_back_after_an_occlusion_by_the_clothes(self):
        tr = PeopleTracker()
        red = shirt((0, 0, 255))
        for i in range(4):
            tr.update(red, [(100, 100, 200, 400, 0.9)], i * 0.1)
        first = tr.tracks[0].id
        tr.update(BLANK, [], 0.5)  # hidden for a moment
        moved = BLANK.copy()
        moved[100:400, 400:500] = (0, 0, 255)  # same shirt, elsewhere: no overlap
        got = tr.update(moved, [(400, 100, 500, 400, 0.9)], 1.2)
        self.assertEqual([t.id for t in got], [first])

    def test_slow_detections_still_confirm(self):
        # A Pi 3 detects people ~0.6 s apart.
        tr = PeopleTracker()
        got = []
        for i in range(MIN_HITS):
            got = tr.update(BLANK, [(100, 100, 200, 400, 0.9)], i * 0.7)
        self.assertEqual(len(got), 1)

    def test_forgets_after_max_age(self):
        tr = PeopleTracker()
        for i in range(4):
            tr.update(BLANK, [(100, 100, 200, 400, 0.9)], i * 0.1)
        tr.update(BLANK, [], 5.0)
        self.assertEqual(tr.tracks, [])

    def test_marker_flukes_are_dropped(self):
        c = MarkerConfirm()
        self.assertEqual(c.update([marker(17)], 0.0), [])  # a texture, once
        self.assertEqual(c.update([], 0.1), [])
        got = []
        for i in range(MIN_HITS):
            got = c.update([marker(0)], 0.2 + i * 0.07)
        self.assertEqual([m.marker_id for m in got], [0])


if __name__ == "__main__":
    unittest.main()
