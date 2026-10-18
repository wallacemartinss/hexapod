#pragma once

#include <math.h>

namespace hexapod {
namespace motion {

struct Vec3 {
  float x = 0.0f;
  float y = 0.0f;
  float z = 0.0f;
};

inline Vec3 operator+(const Vec3& a, const Vec3& b) {
  return {a.x + b.x, a.y + b.y, a.z + b.z};
}
inline Vec3 operator-(const Vec3& a, const Vec3& b) {
  return {a.x - b.x, a.y - b.y, a.z - b.z};
}
inline Vec3 operator*(const Vec3& a, float k) {
  return {a.x * k, a.y * k, a.z * k};
}
inline float Norm(const Vec3& a) {
  return sqrtf(a.x * a.x + a.y * a.y + a.z * a.z);
}
inline float NormXY(const Vec3& a) { return sqrtf(a.x * a.x + a.y * a.y); }

constexpr float kDegToRad = 0.017453292519943295f;
constexpr float kRadToDeg = 57.29577951308232f;

}  // namespace motion
}  // namespace hexapod
