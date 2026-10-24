"""Follow me on demand: hexd says so every second while an app has it on
(a FollowMode envelope back to hexvision's socket). Without that, hexvision
closes the camera and idles: looking for people costs most of a Pi's CPU."""

# hexd wakes every second: three missed in a row and follow me is off.
IDLE_AFTER = 3.0
# While idle, an empty Targets this often tells hexd where to wake us.
HEARTBEAT_EVERY = 1.0


class Wake:
    def __init__(self):
        self._heard = None

    def heard(self, now):
        self._heard = now

    def awake(self, now):
        return self._heard is not None and now - self._heard < IDLE_AFTER
