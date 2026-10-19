"""hexvision: camera -> follow-me targets -> hexd (UDP, one Envelope per frame).

    python3 -m hexvision                       # on the robot (systemd)
    python3 -m hexvision --source 0 --show     # on a PC, with its webcam
"""

import argparse
import logging
import os
import socket
import sys
import threading
import time

import cv2

from hexvision.camera import Camera
from hexvision.detect import MarkerFinder

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "gen"))
from hexapod.v1 import envelope_pb2, vision_pb2  # noqa: E402

MAX_TARGETS = 8
log = logging.getLogger("hexvision")


class LatestFrame:
    """Reads the source on its own thread and keeps only the newest frame:
    processing slower than the camera must not build up a delay."""

    def __init__(self, source):
        self.source = source
        self._cond = threading.Condition()
        self._frame = None
        self._count = 0
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        warned = False
        while True:
            cap = cv2.VideoCapture(self.source)
            if not cap.isOpened():
                if not warned:
                    log.warning("camera %s unavailable, retrying every 5 s", self.source)
                    warned = True
                time.sleep(5)
                continue
            log.info("camera %s open", self.source)
            warned = False
            while True:
                ok, frame = cap.read()
                if not ok:
                    log.warning("camera %s stopped", self.source)
                    break
                with self._cond:
                    self._frame = frame
                    self._count += 1
                    self._cond.notify_all()
            cap.release()
            time.sleep(1)

    def next(self, after, timeout=1.0):
        """The first frame newer than number `after`, or (after, None)."""
        with self._cond:
            self._cond.wait_for(lambda: self._count > after, timeout)
            if self._count <= after:
                return after, None
            return self._count, self._frame


def build_targets(seq, width, height, found, fps, calibrated):
    msg = vision_pb2.Targets(
        seq=seq,
        timestamp_ms=int(time.monotonic() * 1000),
        frame_width=width,
        frame_height=height,
        fps=fps,
        calibrated=calibrated,
    )
    for f in sorted(found, key=lambda f: -f.confidence)[:MAX_TARGETS]:
        msg.targets.add(
            track_id=f.track_id,
            kind=vision_pb2.TARGET_KIND_MARKER,
            marker_id=f.marker_id,
            x=f.x,
            y=f.y,
            w=f.w,
            h=f.h,
            bearing_deg=f.bearing_deg,
            elevation_deg=f.elevation_deg,
            distance_m=f.distance_m,
            confidence=f.confidence,
        )
    return msg


def draw(image, found, fps):
    h, w = image.shape[:2]
    for f in found:
        p0 = (int(f.x * w), int(f.y * h))
        p1 = (int((f.x + f.w) * w), int((f.y + f.h) * h))
        cv2.rectangle(image, p0, p1, (255, 220, 0), 2)
        label = f"#{f.marker_id} {f.bearing_deg:+.0f}deg {f.distance_m:.2f}m"
        cv2.putText(image, label, (p0[0], p0[1] - 6), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 220, 0), 1)
    cv2.putText(image, f"{fps:.1f} fps", (8, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 1)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", default="rtsp://127.0.0.1:8554/cam", help="camera URL, or a webcam index")
    ap.add_argument("--hexd", default="127.0.0.1:47300", help="hexd's UDP address for the targets")
    ap.add_argument("--width", type=int, default=960, help="processing width, px (the image is scaled down)")
    ap.add_argument("--fps", type=float, default=15, help="at most this many frames per second")
    ap.add_argument("--hfov", type=float, default=100, help="horizontal field of view without calibration, deg")
    ap.add_argument("--calibration", default="/opt/hexapod/shared/config/camera_calibration.json")
    ap.add_argument("--marker-size", type=float, default=0.05, help="marker side (black square), m")
    ap.add_argument("--show", action="store_true", help="window with what is seen (PC only)")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")

    source = int(args.source) if args.source.isdigit() else args.source
    frames = LatestFrame(source)
    host, port = args.hexd.rsplit(":", 1)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    camera = finder = None
    seq, count, fps = 0, 0, 0.0
    window_start, window_frames = time.monotonic(), 0
    period = 1 / args.fps
    while True:
        start = time.monotonic()
        count, frame = frames.next(count)
        if frame is None:
            continue
        h, w = frame.shape[:2]
        size = (args.width, round(h * args.width / w))
        if camera is None or (camera.width, camera.height) != size:
            try:
                camera = Camera.from_file(args.calibration, *size)
                log.info("lens calibration %s loaded", args.calibration)
            except (OSError, ValueError, KeyError) as e:
                camera = Camera.pinhole(*size, args.hfov)
                if not isinstance(e, FileNotFoundError):
                    log.warning("calibration not used: %s", e)
            finder = MarkerFinder(camera, args.marker_size)
        small = cv2.resize(frame, size, interpolation=cv2.INTER_AREA) if size[0] != w else frame
        found = finder.find(small)

        window_frames += 1
        if time.monotonic() - window_start >= 1:
            fps = window_frames / (time.monotonic() - window_start)
            window_start, window_frames = time.monotonic(), 0
        seq += 1
        msg = envelope_pb2.Envelope(targets=build_targets(seq, *size, found, fps, camera.calibrated))
        try:
            sock.sendto(msg.SerializeToString(), (host, int(port)))
        except OSError:
            pass  # hexd not up: the next frame tries again
        if args.show:
            draw(small, found, fps)
            cv2.imshow("hexvision", small)
            if cv2.waitKey(1) == 27:
                return
        time.sleep(max(0, period - (time.monotonic() - start)))


if __name__ == "__main__":
    main()
