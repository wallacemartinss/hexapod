"""People at camera speed on a slow board: detect slow, track fast.

The person detector runs on its own thread at whatever pace the board
allows (~1.5 frames/s on a Pi 3). In between, a light tracker moves each
confirmed person's box on every frame, so the robot steers on fresh
positions instead of ones up to a second old.

Tracker: MOSSE on a grey image scaled so the person is TRACK_HEIGHT px
tall, ~1 ms a frame on a Pi 3 (KCF took 39 ms, CSRT and MIL ~250 ms). It
copes poorly with size changes, but it only has to bridge the gap to the
next detection, which restarts it.
"""

import threading

import cv2

TRACK_HEIGHT = 64  # px: each person is tracked on an image scaled to make them this tall
MAX_SCALE = 0.5
# A box keeps being reported this long after its last update (by the
# detector or the fast tracker): long enough to bridge the fast tracker
# losing a person until the next detection, so the box does not blink.
HOLD_S = 1.2


def _scaled(image, scale, cache):
    """Grey image resized by scale, once per scale per frame."""
    key = round(scale, 3)
    if key not in cache:
        small = cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_LINEAR)
        cache[key] = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY) if small.ndim == 3 else small
    return cache[key]


def _tracker():
    """MOSSE (OpenCV contrib, in Debian's python3-opencv); MIL, much slower, otherwise."""
    if hasattr(cv2, "legacy") and hasattr(cv2.legacy, "TrackerMOSSE_create"):
        return cv2.legacy.TrackerMOSSE_create()
    return cv2.TrackerMIL_create()


class PeoplePipeline:
    def __init__(self, finder, tracker, interval=0.0):
        self.finder = finder
        self.tracker = tracker
        self.interval = interval  # s, at least this between detections (saves CPU)
        self._last_job = float("-inf")
        self._fast = {}  # track id -> (tracker, scale of the image it runs on)
        self._cond = threading.Condition()
        self._job = None  # frame waiting for the detector
        self._busy = False
        self._result = None  # (frame, detections)
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        while True:
            with self._cond:
                self._cond.wait_for(lambda: self._job is not None)
                image, self._job = self._job, None
            found = self.finder.detect(image)
            with self._cond:
                self._result, self._busy = (image, found), False

    def step(self, image, now):
        """Confirmed people with fresh boxes on this frame."""
        with self._cond:
            if not self._busy and now - self._last_job >= self.interval:  # the detector is free
                self._job, self._busy, self._last_job = image.copy(), True, now
                self._cond.notify()
            result, self._result = self._result, None
        if result is not None:
            seen, found = result
            confirmed = {t.id for t in self.tracker.update(seen, found, now)}
            # Restart each tracker where the detector saw the person, then let
            # it catch up with the newer frame.
            self._fast = {}
            for t in self.tracker.tracks:
                if t.id in confirmed:
                    x0, y0, x1, y1 = t.box
                    scale = min(MAX_SCALE, TRACK_HEIGHT / max(1.0, y1 - y0))
                    k = _tracker()
                    box = (int(x0 * scale), int(y0 * scale), max(1, int((x1 - x0) * scale)), max(1, int((y1 - y0) * scale)))
                    k.init(_scaled(seen, scale, {}), box)
                    self._fast[t.id] = (k, scale)
        cache = {}
        for t in self.tracker.tracks:
            entry = self._fast.get(t.id)
            if entry is None:
                continue
            k, scale = entry
            ok, (x, y, w, h) = k.update(_scaled(image, scale, cache))
            if ok:
                ih, iw = image.shape[:2]  # inside the image, however far it drifted
                x0, y0 = max(0.0, x / scale), max(0.0, y / scale)
                x1, y1 = min(float(iw), (x + w) / scale), min(float(ih), (y + h) / scale)
                if x1 - x0 > 4 and y1 - y0 > 4:
                    t.box, t.seen = (x0, y0, x1, y1), now
            else:
                del self._fast[t.id]  # lost until the next detection
        return [t for t in self.tracker.tracks if t.confirmed and now - t.seen <= HOLD_S]
