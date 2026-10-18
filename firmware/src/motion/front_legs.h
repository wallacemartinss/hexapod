// Front legs mode (MODE_FRONT_LEGS): the robot stands on its 4 rear legs and
// the 2 front legs become "paws" driven by the sticks or by gestures.
//
// The order is what keeps it standing, so it is a phase machine and every
// phase waits until the joints actually reached their targets:
//
//   off -> shift body back -> hover paws -> raise paws -> active
//   active -> descend to hover -> lower paws -> shift body forward -> off
//
// Paws only leave the ground once the body is back over the 4 support feet,
// and the body only comes forward once both paws are down again.
#pragma once

#include "hexapod/v1/common.pb.h"
#include "motion/ik.h"
#include "motion/vec3.h"

namespace hexapod {
namespace motion {

// Normalized paw command (Command.front_legs), -1..1.
struct PawInput {
  float left_reach = 0.0f;
  float left_lift = 0.0f;
  float right_reach = 0.0f;
  float right_lift = 0.0f;
};

class FrontLegs {
 public:
  enum class Phase : uint8_t {
    kOff,
    kShift,    // all feet on the ground, body moving back
    kHover,    // paws straight up off the ground
    kRaise,    // paws to the raised rest pose
    kActive,   // paws follow the sticks / gestures
    kDescend,  // paws back above their ground spot
    kLower,    // paws down on the ground
    kUnshift,  // body moving forward again
  };

  static constexpr int kLeftPaw = 0;   // front-left leg
  static constexpr int kRightPaw = 3;  // front-right leg

  // `want`: the mode is requested and allowed. `settled`: the joints reached
  // the previous targets. Fills `feet` (body frame) unless the phase is kOff.
  // A phase ends once its feet reached their end positions and the joints
  // followed.
  void Update(bool want, const PawInput& paws, hexapod_v1_Gesture gesture,
              bool settled, float body_height_mm, float dt_s,
              Vec3 feet[kLegCount]);

  bool active() const { return phase_ != Phase::kOff; }
  Phase phase() const { return phase_; }
  bool playing() const {
    return gesture_ != hexapod_v1_Gesture_GESTURE_UNSPECIFIED;
  }

  // Paw target in its own leg frame.
  static Vec3 PawPose(float reach, float lift);

 private:
  PawInput GesturePaws(const PawInput& sticks, float dt_s);

  // Feet as commanded (body frame), moved in straight lines towards the
  // phase's end positions.
  Vec3 cmd_[kLegCount];
  bool at_end_ = false;
  Phase phase_ = Phase::kOff;
  hexapod_v1_Gesture gesture_ = hexapod_v1_Gesture_GESTURE_UNSPECIFIED;
  hexapod_v1_Gesture last_input_ = hexapod_v1_Gesture_GESTURE_UNSPECIFIED;
  float gesture_t_ = 0.0f;
};

}  // namespace motion
}  // namespace hexapod
