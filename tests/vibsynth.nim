## Test fixture: writes synthetic `.vib` signature files. The library reads this format
## and does not author it, so the writer lives with the tests. Every number is made up:
## the header's weights and calibrations, the sweep and the channels are not those of
## any controller.

import std/math
import parseSSVIB/types

const
  MadeUpHeader* = VibHeader(channelsPerFrame: 11, valveCal: 3200.0, massCal: 2560.0,
    unknown12: 0.5, unknown16: 2.0, holdDownLb: 40000.0, sensitivity1: 20.0,
    sensitivity2: 20.0, baseplateLb: 6000.0, massLb: 4000.0)
    ## made-up header values (every float is exact in `float32`)

type
  SynthVib* = object
    kindByte*: int = 11
    header*: VibHeader = MadeUpHeader
    start*: VibTime = VibTime(year: 2001, month: 2, day: 3, hour: 4, minute: 5, second: 6)
    preTrigger*: float64 = 600.37              ## the trigger as a fractional frame
    afterTrigger*: int = 6000                  ## frames after the trigger (the whole record: no taper at its end)
    startHz*: float64 = 20.0
    rateHzPerS*: float64 = 30.0                ## a made-up linear sweep
    cubicHzPerS2*: float64 = 0.0               ## a cubic term of the phase: a sweep that is not linear
    amplitude*: int = 15000
    taperFrames*: int = 400
    data*: array[VibChannel, seq[int16]]       ## empty: derived from the sweep
    cycle*: array[VibCycleValue, seq[float32]] ## empty: stepped once per cycle
    stopAt*: int = -1                          ## frames after the trigger when it ends: a stopped recording
    tailBytes*: int = 0                        ## bytes added after the last frame: a copy cut short
    intervalUs*: float64 = 500

func frameCount*(s: SynthVib): int =
  ## Frames of the record the synthesizer writes (without a `data` given).
  int(ceil(s.preTrigger)) + (if s.stopAt >= 0: s.stopAt else: s.afterTrigger)

func phaseCycles(s: SynthVib; frame: int): float64 =
  ## The sweep's phase in cycles at `frame`; 0 before the trigger.
  let t = (float64(frame) - s.preTrigger) * s.intervalUs / 1e6
  if t <= 0: 0.0 else: s.startHz * t + 0.5 * s.rateHzPerS * t * t +
    s.cubicHzPerS2 * t * t * t / 3

func envelope(s: SynthVib; frame: int): float64 =
  let tf = float64(frame) - s.preTrigger
  if tf <= 0:
    return 0.0
  result = min(1.0, tf / float64(max(1, s.taperFrames)))
  if s.stopAt < 0:
    result = min(result, max(0.0, (float64(s.afterTrigger) - tf) / float64(max(1,
      s.taperFrames))))

func clamp16(x: float64): int16 =
  int16(max(-32768.0, min(32767.0, round(x))))

func columnValue(s: SynthVib; c: VibChannel; frame: int): int16 =
  ## A made-up channel: the reference's phase, scaled, shifted and offset.
  let e = envelope(s, frame)
  let ph = phaseCycles(s, frame)
  let a = float64(s.amplitude)
  case c
  of vcReference: clamp16(a * e * sin(2 * PI * ph))
  of vcBaseplateA: clamp16(0.30 * a * e * sin(2 * PI * ph + 0.4))
  of vcMassA: clamp16(0.20 * a * e * sin(2 * PI * ph + 0.1))
  of vcBaseplateB: clamp16(1.01 * 0.30 * a * e * sin(2 * PI * ph + 0.4))
  of vcMassB: clamp16(1.01 * 0.20 * a * e * sin(2 * PI * ph + 0.1))
  of vcTorqueMotor: clamp16(0.05 * a * e * sin(2 * PI * ph + 1.0) + 120)
  of vcValve: clamp16(0.08 * a * e * sin(2 * PI * ph + 2.0) - 35)
  of vcMassStroke: clamp16(0.10 * a * e * sin(2 * PI * ph + 3.0) + 77)
  of vcDrive: (if e > 0: clamp16(0.25 * a * sin(2 * PI * ph + 0.7)) else: 0'i16)

func cycleValue(s: SynthVib; v: VibCycleValue; frame: int): float32 =
  ## Stepped once per cycle, 0 before the trigger.
  let k = floor(phaseCycles(s, frame))
  if envelope(s, frame) <= 0: 0.0'f32
  elif v == vvDriveRatio: float32(1.5 + 0.0625 * k)
  else: float32(1.0e9 + 4096.0 * k)

func synthRef*(s: SynthVib): seq[int16] =
  ## The derived reference channel alone (as `synthVib` writes it).
  result = newSeq[int16](frameCount(s))
  for i in 0 ..< result.len:
    result[i] = columnValue(s, vcReference, i)

proc put16(d: var seq[byte]; at: int; v: int) =
  d[at] = byte(v and 0xFF)
  d[at + 1] = byte((v shr 8) and 0xFF)

proc put32(d: var seq[byte]; at: int; v: uint32) =
  for i in 0 .. 3:
    d[at + i] = byte((v shr (8 * i)) and 0xFF)

proc putFloat(d: var seq[byte]; at: int; v: float32) =
  put32(d, at, cast[uint32](v))

proc synthVib*(s: SynthVib): seq[byte] =
  ## The bytes of a `.vib` file: the header from `s.header` and `s.start`, then the
  ## frames (the given `data` and `cycle` columns, or the derived ones), then
  ## `tailBytes` zero bytes.
  var n = frameCount(s)
  if s.data[vcReference].len > 0:
    n = s.data[vcReference].len
  result = newSeq[byte](47 + 26 * n + s.tailBytes)
  result[0] = byte('V')
  result[1] = byte('I')
  result[2] = byte('B')
  result[3] = byte(s.kindByte)
  let h = s.header
  for (at, v) in [(4, h.valveCal), (8, h.massCal), (12, h.unknown12), (16, h.unknown16),
      (20, h.holdDownLb), (24, h.sensitivity1), (28, h.sensitivity2),
      (32, h.baseplateLb), (36, h.massLb)]:
    putFloat(result, at, v)
  result[40] = byte(s.start.second)
  result[41] = byte(s.start.minute)
  result[42] = byte(s.start.hour)
  result[43] = byte(s.start.day)
  result[44] = byte(s.start.month)
  put16(result, 45, s.start.year)
  for i in 0 ..< n:
    let base = 47 + 26 * i
    for c in VibChannel:
      let v = if s.data[c].len > 0: s.data[c][i] else: columnValue(s, c, i)
      put16(result, base + 2 * ord(c), int(v))
    for v in VibCycleValue:
      let x = if s.cycle[v].len > 0: s.cycle[v][i] else: cycleValue(s, v, i)
      putFloat(result, base + 18 + 4 * ord(v), x)

proc synthOtherKind*(records: int): seq[byte] =
  ## A file of the other kind: `VIB` and 6, then 36-byte records.
  result = newSeq[byte](4 + 36 * records)
  result[0] = byte('V')
  result[1] = byte('I')
  result[2] = byte('B')
  result[3] = 6
  for r in 0 ..< records:
    let at = 4 + 36 * r
    put16(result, at, 0x1234)
    put32(result, at + 2, uint32(1000 + r))
    put32(result, at + 12, uint32(r * 7))
