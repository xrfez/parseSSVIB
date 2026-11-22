## The sweep in the reference channel: where it starts and how fast it runs.
##
## The controller's reference is a sine whose frequency changes linearly in time. Its
## zero crossings follow the sweep's phase: crossing `k` (1, 2, ...) lies where the
## phase is `k / 2` cycles, and for a linear sweep the phase is a quadratic in time.
## A least-squares quadratic through the crossings gives the sweep's start frequency
## and rate, and its root, the instant the phase is 0, is the trigger: the controller
## starts the sweep's phase at the trigger. The fit needs a linear sweep whose phase
## starts at the trigger; a pulse, or a sweep that is not linear, gives no estimate
## (`VibSweep.valid` is false).
##
## Nothing here allocates: the crossings are found again in each of three passes over
## the reference. Every proc is safe to call from several threads.

import std/math
import ./types

const
  MinCrossings* = 200       ## a reference with fewer zero crossings gives no estimate
  MaxResidualCycles* = 0.05 ## a larger phase residual of any crossing gives none
  TailFrames* = 40          ## `endsInSweep` looks at this many last frames
  MinIntervalUs* = 0.01 ## a smaller interval gives no fit
  NewtonSteps = 60

template eachCrossing(x: openArray[int16]; z, body: untyped) =
  ## Runs `body` for every zero crossing of `x` with `z` the crossing's position in
  ## frames: a sign change between two frames, linearly interpolated; a zero sample
  ## counts as non-negative. The jump from the zero run before the trigger to a
  ## reference that starts negative is no crossing: a change from non-negative to
  ## negative counts only once a positive sample has been seen.
  var started = false
  for i in 1 ..< x.len:
    let a = int(x[i - 1])
    let b = int(x[i])
    if a > 0: started = true
    if (a < 0) != (b < 0) and (started or a < 0):
      let z = float64(i - 1) + float64(a) / float64(a - b)
      body

func solve3(m: array[3, array[3, float64]]; inv: var array[3, array[3, float64]]): bool =
  ## The inverse of the symmetric 3 x 3 matrix `m`; false when it is singular.
  let c00 = m[1][1] * m[2][2] - m[1][2] * m[2][1]
  let c01 = m[1][2] * m[2][0] - m[1][0] * m[2][2]
  let c02 = m[1][0] * m[2][1] - m[1][1] * m[2][0]
  let det = m[0][0] * c00 + m[0][1] * c01 + m[0][2] * c02
  result = abs(det) > 1e-12 and abs(det) < Inf
  if result:
    inv[0][0] = c00 / det
    inv[0][1] = (m[0][2] * m[2][1] - m[0][1] * m[2][2]) / det
    inv[0][2] = (m[0][1] * m[1][2] - m[0][2] * m[1][1]) / det
    inv[1][0] = c01 / det
    inv[1][1] = (m[0][0] * m[2][2] - m[0][2] * m[2][0]) / det
    inv[1][2] = (m[0][2] * m[1][0] - m[0][0] * m[1][2]) / det
    inv[2][0] = c02 / det
    inv[2][1] = (m[0][1] * m[2][0] - m[0][0] * m[2][1]) / det
    inv[2][2] = (m[0][0] * m[1][1] - m[0][1] * m[1][0]) / det

func fitSweep*(reference: openArray[int16]; intervalUs = 500.0): VibSweep =
  ## Fits a linear sweep to the zero crossings of `reference` (any 16-bit channel
  ## that holds the sweep; the interval of its frames is `intervalUs`). With `K`
  ## crossings the phase of crossing `k` is set to `k / 2` cycles and a quadratic in
  ## the crossing's position is fitted by least squares; its root nearest the first
  ## crossing is `triggerFrame`, the slope there `startHz` and twice the curvature
  ## `rateHzPerS`.
  ##
  ## `valid` needs at least `MinCrossings` crossings, a largest phase residual of at
  ## most `MaxResidualCycles`, an increasing phase and a root between frame 0 and
  ## the first crossing; otherwise `valid` is false and the numbers are NaN (`crossings`
  ## and the residuals are kept when they were found). A reference that starts with
  ## a negative half-cycle is fitted like one that starts positive.
  ##
  ## Assumptions: a clean reference at full scale (the controllers seen have a few
  ## counts of noise at most, and a reference with more noise near zero makes extra
  ## crossings that break the count, so the fit is then refused or wrong), and a
  ## sweep that is long enough: a short logarithmic sweep can pass the residual limit
  ## and still put the trigger a few frames off. `triggerSigmaFrames` is the fit's
  ## formal error. It does not include a constant offset of up to about 0.02 frames
  ## that a controller's reference can have against the trigger, so the actual scatter
  ## is wider than the stated sigma. Never raises: an interval that is not finite,
  ## below 0.01 us or not positive gives an invalid fit.
  result = VibSweep()
  var count = 0
  var first = 0.0
  var last = 0.0
  eachCrossing(reference, z):
    if count == 0: first = z
    last = z
    inc count
  result.crossings = count
  if count < MinCrossings or not (intervalUs >= MinIntervalUs and intervalUs < Inf):
    return
  let mid = (first + last) / 2
  let half = max((last - first) / 2, 1.0)
  let yMid = float64(count + 1) / 4 # centres the phase: only c0 sees it
  var s: array[5, float64] # sums of u^0 .. u^4
  var t: array[3, float64] # sums of y u^0 .. y u^2
  var k = 0
  eachCrossing(reference, z):
    inc k
    let u = (z - mid) / half
    let y = float64(k) / 2 - yMid
    var p = 1.0
    for j in 0 .. 4:
      s[j] += p
      if j <= 2: t[j] += y * p
      p *= u
  let m = [[s[0], s[1], s[2]], [s[1], s[2], s[3]], [s[2], s[3], s[4]]]
  var inv: array[3, array[3, float64]]
  if not solve3(m, inv):
    return
  var c: array[3, float64]
  for i in 0 .. 2:
    c[i] = inv[i][0] * t[0] + inv[i][1] * t[1] + inv[i][2] * t[2]
  var worst = 0.0
  var sum2 = 0.0
  k = 0
  eachCrossing(reference, z):
    inc k
    let u = (z - mid) / half
    let r = float64(k) / 2 - yMid - (c[0] + u * (c[1] + u * c[2]))
    worst = max(worst, abs(r))
    sum2 += r * r
  result.residualCycles = worst
  result.rmsCycles = sqrt(sum2 / float64(count))
  if not (worst <= MaxResidualCycles):
    return
  # the root of yMid + c0 + c1 u + c2 u^2 nearest the first crossing (u = -1), by Newton
  var u = -1.0
  var slope = c[1] + 2 * c[2] * u
  if not (slope > 0):
    return
  for step in 1 .. NewtonSteps:
    let g = yMid + c[0] + u * (c[1] + u * c[2])
    slope = c[1] + 2 * c[2] * u
    if not (slope > 0):
      return
    let du = g / slope
    u -= du
    if abs(du) < 1e-13:
      break
  slope = c[1] + 2 * c[2] * u
  let trigger = mid + u * half
  if not (slope > 0 and u < -1 and trigger >= 0):
    return
  let hz = 1e6 / intervalUs # frames per second
  result.valid = true
  result.triggerFrame = trigger
  result.startHz = slope / half * hz
  result.rateHzPerS = 2 * c[2] / (half * half) * hz * hz
  # the formal uncertainty of the root: sigma^2 b' M^-1 b / slope^2, b = (1, u, u^2)
  let b = [1.0, u, u * u]
  var q = 0.0
  for i in 0 .. 2:
    for j in 0 .. 2:
      q += b[i] * inv[i][j] * b[j]
  let sigma2 = sum2 / float64(count - 3)
  result.triggerSigmaFrames = sqrt(max(sigma2 * q, 0.0)) / slope * half

func endsInSweep*(reference: openArray[int16]): bool =
  ## True when the record stops inside the sweep: the largest magnitude in the last
  ## `TailFrames` frames is above a quarter of the largest in the whole reference
  ## (0.999 of it in the one stopped recording seen, at most 0.05 in the others). A
  ## reference that is all zeros does not end in a sweep. A file cut at a frame
  ## boundary looks the same as a stopped recording.
  var peak = 0
  var tail = 0
  let from0 = max(0, reference.len - TailFrames)
  for i in 0 ..< reference.len:
    let a = abs(int(reference[i]))
    peak = max(peak, a)
    if i >= from0: tail = max(tail, a)
  result = peak > 0 and 4 * tail > peak
