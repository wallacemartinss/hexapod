"""Keeps the same id on the same target from frame to frame, and only
reports a target once it was seen in a few frames in a row: a texture that
looks like a marker for one frame never reaches the app.

People are matched by overlap (IoU) and, after a short occlusion, by the
colours of their clothes. The clothes also guard the overlap: when two
people cross, a box that overlaps a confirmed person but wears other
clothes is not given their id. Losing the target is safer than following
a stranger. Markers carry their own id; they are only confirmed.
"""

from dataclasses import dataclass, field

import cv2
import numpy as np

MIN_HITS = 3  # frames in a row before a target is reported
MAX_AGE_S = 2.0  # a target not seen for this long is forgotten
# Detections this close count as "in a row": people are detected slowly on a
# Pi 3 (~0.6 s apart), markers on every frame.
PERSON_GAP_S = 1.5
MARKER_GAP_S = 0.5
PERSON_IDS = 1000  # people get ids from here (markers: marker id + 1)
ANIMAL_IDS = 1_000_000  # dogs and cats from here
MIN_IOU = 0.3  # overlap that can carry an id over
# Torso histogram correlation (-1..1): below SAME_MIN an overlapping box is
# someone else; above BACK_MIN a box with no overlap is a lost person back.
SAME_MIN = 0.2
BACK_MIN = 0.7


def iou(a, b):
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union > 0 else 0.0


def appearance(image, box):
    """Hue/saturation histogram of the torso (middle of the box)."""
    x0, y0, x1, y1 = (int(v) for v in box[:4])
    h = y1 - y0
    roi = image[y0 + h // 5 : y0 + h * 3 // 5, x0 + (x1 - x0) // 6 : x1 - (x1 - x0) // 6]
    if roi.size == 0 or image.ndim != 3:
        return None
    hist = cv2.calcHist([cv2.cvtColor(roi, cv2.COLOR_BGR2HSV)], [0, 1], None, [16, 8], [0, 180, 0, 256])
    return cv2.normalize(hist, hist).flatten()


def similar(a, b):
    if a is None or b is None:
        return 0.0
    return float(cv2.compareHist(a.astype(np.float32), b.astype(np.float32), cv2.HISTCMP_CORREL))


def _kind(d):
    return d[5] if len(d) > 5 else "person"


@dataclass
class Track:
    id: int
    box: tuple
    seen: float
    hits: int = 1
    confidence: float = 0.0
    kind: str = "person"  # or "animal"
    look: np.ndarray = field(default=None, repr=False)

    @property
    def confirmed(self):
        return self.hits >= MIN_HITS


class PeopleTracker:
    def __init__(self):
        self.tracks = []
        self.next_id = {"person": PERSON_IDS, "animal": ANIMAL_IDS}

    def update(self, image, detections, now):
        """detections: [(x0, y0, x1, y1, conf[, kind])] -> confirmed tracks
        seen now. A person never takes an animal's id, nor the reverse."""
        self.tracks = [t for t in self.tracks if now - t.seen <= MAX_AGE_S]
        free = list(self.tracks)
        current = []
        looks = [appearance(image, d) for d in detections]
        # Best overlaps first, so two people side by side keep their ids; at
        # equal overlap, the more alike.
        pairs = []
        for i, d in enumerate(detections):
            for t in free:
                if t.kind != _kind(d):
                    continue
                overlap = iou(d, t.box)
                if overlap < MIN_IOU:
                    continue
                alike = similar(looks[i], t.look)
                if t.confirmed and looks[i] is not None and t.look is not None and alike < SAME_MIN:
                    continue  # someone else crossing in front
                pairs.append((overlap + 0.3 * alike, i, t))
        pairs.sort(key=lambda p: -p[0])
        taken = set()
        for _, i, t in pairs:
            if i in taken or t not in free:
                continue
            taken.add(i)
            free.remove(t)
            self._hit(t, looks[i], detections[i], now)
            current.append(t)
        for i, d in enumerate(detections):
            if i in taken:
                continue
            look = looks[i]
            # Back after an occlusion? The most alike recently lost person.
            best = max((t for t in free if t.kind == _kind(d)), key=lambda t: similar(look, t.look), default=None)
            if best is not None and best.confirmed and similar(look, best.look) > BACK_MIN:
                free.remove(best)
                self._hit(best, look, d, now)
                current.append(best)
                continue
            kind = _kind(d)
            t = Track(id=self.next_id[kind], box=tuple(d[:4]), seen=now, confidence=d[4], look=look, kind=kind)
            self.next_id[kind] += 1
            self.tracks.append(t)
            current.append(t)
        return [t for t in current if t.confirmed]

    def _hit(self, t, look, d, now):
        # A confirmed target stays confirmed when it comes back (within MAX_AGE_S).
        t.hits = t.hits + 1 if now - t.seen < PERSON_GAP_S or t.confirmed else 1
        t.box, t.seen, t.confidence = tuple(d[:4]), now, d[4]
        if look is not None:  # follows slow changes of light
            t.look = look if t.look is None else 0.8 * t.look + 0.2 * look


class MarkerConfirm:
    """Markers already carry an id: only ask for a few frames in a row."""

    def __init__(self):
        self.hits = {}  # marker id -> (hits, last seen)

    def update(self, markers, now):
        seen = {}
        for m in markers:
            hits, last = self.hits.get(m.marker_id, (0, 0.0))
            seen[m.marker_id] = (hits + 1 if now - last < MARKER_GAP_S else 1, now)
        self.hits = {k: v for k, v in {**self.hits, **seen}.items() if now - v[1] <= MAX_AGE_S}
        return [m for m in markers if self.hits[m.marker_id][0] >= MIN_HITS]
