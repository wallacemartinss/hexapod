import unittest

from hexvision.wake import IDLE_AFTER, Wake


class WakeTest(unittest.TestCase):
    def test_idle_until_hexd_says_follow_me_is_on(self):
        w = Wake()
        self.assertFalse(w.awake(100.0))
        w.heard(100.0)
        self.assertTrue(w.awake(100.5))

    def test_idle_again_when_the_wake_ups_stop(self):
        w = Wake()
        w.heard(100.0)
        w.heard(101.0)
        self.assertTrue(w.awake(101.0 + IDLE_AFTER - 0.1))
        self.assertFalse(w.awake(101.0 + IDLE_AFTER))


if __name__ == "__main__":
    unittest.main()
