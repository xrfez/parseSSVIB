## Counts to physical values, from the header's weights, calibrations and the
## caller's constants.
##
## The file holds raw counts. The header holds the hold-down weight, the two mass
## weights, the accelerometer sensitivity and the two LVDT calibrations; the library
## holds no constant that turns a count into a physical value (`VibScale` is the
## caller's). With them:
##
## | channel | per count |
## |---|---|
## | reference | pounds-force: hold-down weight / 32767 (needs no constant) |
## | accelerations | g: `accMvPerCount / sensitivity`; as a force, pounds-force: times the weight of the baseplate or the reaction mass |
## | torque-motor current | percent: `torquePctPerCount` |
## | valve displacement | percent: `lvdtFactor / valveCal` |
## | mass displacement | percent: `lvdtFactor / massCal` |
## | drive output | `drivePerCount`, unit unknown |
##
## `groundForce` adds the baseplate and reaction-mass forces of one accelerometer set,
## each weighted by its mass: a computed value, not a measured one, and not a
## reading of the ground. Nothing here changes a sign.

import std/math
import ./types

func positive(v: float64): bool =
  v > 0 and v < Inf

func need(v: float64; what: string) =
  ## Raises `ValueError` unless `v` is finite and above 0.
  if not positive(v):
    raise newException(ValueError, what & " is " & $v & ", not finite and above 0")

func sensitivityOf(h: VibHeader; c: VibChannel): float64 =
  ## The header's sensitivity of the set of `c`: the first for set A, the second for
  ## set B (they are equal in every file seen, and which sensor each is is unknown).
  if c in {vcBaseplateA, vcMassA}: float64(h.sensitivity1) else: float64(h.sensitivity2)

func scaleOf*(s: VibInfo; c: VibChannel; k: VibScale; force = true): float64 =
  ## The factor that turns the counts of `c` into physical values, from the header of
  ## `s` and the constants `k`: see the module's table. `force` chooses pounds-force
  ## over g for the accelerations. Raises `ValueError` when a header value or a
  ## constant it needs is not finite and above 0.
  case c
  of vcReference:
    need(float64(s.header.holdDownLb), "the header's hold-down weight")
    result = float64(s.header.holdDownLb) / 32767.0
  of vcBaseplateA, vcMassA, vcBaseplateB, vcMassB:
    need(k.accMvPerCount, "the accelerometer constant")
    need(sensitivityOf(s.header, c), "the header's accelerometer sensitivity")
    result = k.accMvPerCount / sensitivityOf(s.header, c)
    if force:
      let w = if c in {vcBaseplateA, vcBaseplateB}: float64(s.header.baseplateLb)
        else: float64(s.header.massLb)
      need(w, "the header's " & (if c in {vcBaseplateA, vcBaseplateB}: "baseplate" else:
        "reaction-mass") & " weight")
      result = w * result
  of vcTorqueMotor:
    need(k.torquePctPerCount, "the torque-motor constant")
    result = k.torquePctPerCount
  of vcValve:
    need(k.lvdtFactor, "the LVDT constant")
    need(float64(s.header.valveCal), "the header's valve calibration")
    result = k.lvdtFactor / float64(s.header.valveCal)
  of vcMassStroke:
    need(k.lvdtFactor, "the LVDT constant")
    need(float64(s.header.massCal), "the header's mass calibration")
    result = k.lvdtFactor / float64(s.header.massCal)
  of vcDrive:
    need(k.drivePerCount, "the drive constant")
    result = k.drivePerCount

func physical*(s: VibShot; c: VibChannel; k: VibScale; force = true): seq[float32] =
  ## Channel `c` in physical values: `float32(scaleOf(...) * count)`, the sign as
  ## recorded. Raises `ValueError` as `scaleOf` does.
  let f = scaleOf(s, c, k, force)
  result = newSeq[float32](s.data[c].len)
  for i, v in s.data[c]:
    result[i] = float32(f * float64(v))

func groundForce*(s: VibShot; which = vsB; k = VibScale()): seq[float32] =
  ## The ground force of accelerometer set `which`, computed as the baseplate weight
  ## times the baseplate acceleration plus the reaction-mass weight times the
  ## reaction-mass acceleration, per frame, in `float64` and then `float32`. With
  ## `k.accMvPerCount` given the counts are scaled to pounds-force (an estimate, as
  ## good as the constant); without it the values are in pound-counts: the same shape,
  ## proportional to pounds-force. The sign is as recorded. Raises `ValueError` for a
  ## weight, or a given constant or the sensitivity, that is not finite and above 0,
  ## and for two channels of different lengths (a shot that was not decoded).
  let (bp, rm) = if which == vsA: (vcBaseplateA, vcMassA) else: (vcBaseplateB, vcMassB)
  need(float64(s.header.baseplateLb), "the header's baseplate weight")
  need(float64(s.header.massLb), "the header's reaction-mass weight")
  var wb = float64(s.header.baseplateLb)
  var wm = float64(s.header.massLb)
  if not k.accMvPerCount.isNaN:
    wb = scaleOf(s, bp, k, true)
    wm = scaleOf(s, rm, k, true)
  if s.data[bp].len != s.data[rm].len:
    raise newException(ValueError, "the baseplate and reaction-mass channels have " &
      $s.data[bp].len & " and " & $s.data[rm].len & " samples")
  result = newSeq[float32](s.data[bp].len)
  for i in 0 ..< result.len:
    result[i] = float32(wb * float64(s.data[bp][i]) + wm * float64(s.data[rm][i]))
