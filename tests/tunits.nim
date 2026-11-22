## Counts to physical values: the factor of each channel from the header and made-up
## constants, the refusals for a missing constant or a zero weight, and the computed
## ground force.
##
## Seen to fail: with the valve and mass calibrations swapped in `scaleOf`,
## `factors` fails; with the baseplate weight used for the reaction mass,
## `factors` and `groundForce` fail; with `need` accepting zero, `refusals` fails;
## with the sign of the ground force flipped, `groundForce` and `polarity` fail; with
## set A's sensitivity read for set B, `sensitivities` fails; with `physical`
## rounding to float32 before the multiplication, `physical` fails.

import std/[math, strutils]
import parseSSVIB/[decode, types, units]
import vibsynth

const k = VibScale(accMvPerCount: 0.5, torquePctPerCount: 0.125, lvdtFactor: 8000.0,
  drivePerCount: 0.0625) ## made-up constants (exact in binary)

proc shot(h = MadeUpHeader): VibShot =
  var syn = SynthVib(header: h, afterTrigger: 30, preTrigger: 10.5)
  for c in VibChannel:
    for i in 0 ..< 40:
      syn.data[c].add int16((i * 997 + ord(c) * 131) mod 4001 - 2000)
  parseVib(synthVib(syn))

proc main*() =
  var h = MadeUpHeader
  h.valveCal = 3200.0
  h.massCal = 2560.0
  h.holdDownLb = 40000.0
  h.sensitivity1 = 20.0
  h.sensitivity2 = 25.0
  h.baseplateLb = 6000.0
  h.massLb = 4000.0
  let s = shot(h)

  block factors:
    doAssert scaleOf(s, vcReference, k) == 40000.0 / 32767.0
    doAssert scaleOf(s, vcReference, VibScale()) == 40000.0 / 32767.0 # no constant needed
    doAssert scaleOf(s, vcBaseplateA, k) == 6000.0 * (0.5 / 20.0)
    doAssert scaleOf(s, vcMassA, k) == 4000.0 * (0.5 / 20.0)
    doAssert scaleOf(s, vcBaseplateB, k) == 6000.0 * (0.5 / 25.0)
    doAssert scaleOf(s, vcMassB, k) == 4000.0 * (0.5 / 25.0)
    doAssert scaleOf(s, vcBaseplateA, k, force = false) == 0.5 / 20.0
    doAssert scaleOf(s, vcMassB, k, force = false) == 0.5 / 25.0
    doAssert scaleOf(s, vcTorqueMotor, k) == 0.125
    doAssert scaleOf(s, vcValve, k) == 8000.0 / 3200.0
    doAssert scaleOf(s, vcMassStroke, k) == 8000.0 / 2560.0
    doAssert scaleOf(s, vcDrive, k) == 0.0625
    # the info alone is enough
    doAssert scaleOf(parseVibInfo(synthVib(SynthVib(header: h, afterTrigger: 3))),
      vcValve, k) == 2.5

  block sensitivities:
    ## Set A reads the header's first sensitivity, set B the second.
    doAssert scaleOf(s, vcBaseplateA, k, false) != scaleOf(s, vcBaseplateB, k, false)

  block refusals:
    ## A constant not given, a weight that is zero, NaN or negative: `ValueError`.
    for c in [vcBaseplateA, vcMassA, vcBaseplateB, vcMassB]:
      doAssertRaises(ValueError):
        discard scaleOf(s, c, VibScale())
    doAssertRaises(ValueError):
      discard scaleOf(s, vcTorqueMotor, VibScale(accMvPerCount: 1))
    doAssertRaises(ValueError):
      discard scaleOf(s, vcValve, VibScale(torquePctPerCount: 1))
    doAssertRaises(ValueError):
      discard scaleOf(s, vcMassStroke, VibScale())
    doAssertRaises(ValueError):
      discard scaleOf(s, vcDrive, VibScale(lvdtFactor: 1))
    for bad in [0.0, -1.0, NaN, Inf, -Inf]:
      doAssertRaises(ValueError):
        discard scaleOf(s, vcBaseplateA, VibScale(accMvPerCount: bad))
      doAssertRaises(ValueError):
        discard scaleOf(s, vcDrive, VibScale(drivePerCount: bad))
    for (name, bad) in [("hold-down", 0.0), ("hold-down", NaN), ("hold-down", -5.0)]:
      var hh = h
      hh.holdDownLb = float32(bad)
      try:
        discard scaleOf(shot(hh), vcReference, k)
        doAssert false
      except ValueError as e:
        doAssert name in e.msg and "not finite and above 0" in e.msg, e.msg
    var zero = h
    zero.massLb = 0
    doAssertRaises(ValueError):
      discard scaleOf(shot(zero), vcMassA, k)
    discard scaleOf(shot(zero), vcMassA, k, force = false) # g needs no weight
    discard scaleOf(shot(zero), vcBaseplateA, k) # the baseplate's weight is not zero
    doAssertRaises(ValueError):
      discard groundForce(shot(zero))
    var nosens = h
    nosens.sensitivity2 = 0
    doAssertRaises(ValueError):
      discard scaleOf(shot(nosens), vcBaseplateB, k)
    discard scaleOf(shot(nosens), vcBaseplateA, k) # set A uses the other number
    var nocal = h
    nocal.valveCal = NaN.float32
    doAssertRaises(ValueError):
      discard scaleOf(shot(nocal), vcValve, k)
    discard scaleOf(shot(nocal), vcMassStroke, k)

  block physical:
    for c in VibChannel:
      let p = physical(s, c, k)
      doAssert p.len == s.len
      let f = scaleOf(s, c, k)
      for i in 0 ..< s.len:
        doAssert p[i] == float32(f * float64(s.data[c][i])), $(c, i)
    let g = physical(s, vcMassB, k, force = false)
    doAssert g[5] == float32((0.5 / 25.0) * float64(s.data[vcMassB][5]))
    doAssertRaises(ValueError):
      discard physical(s, vcDrive, VibScale())

  block groundForce:
    ## Wbp * baseplate + Wrm * reaction mass, of each set.
    for (which, bp, rm) in [(vsA, vcBaseplateA, vcMassA), (vsB, vcBaseplateB, vcMassB)]:
      let g = groundForce(s, which)
      doAssert g.len == s.len
      for i in 0 ..< s.len:
        doAssert g[i] == float32(6000.0 * float64(s.data[bp][i]) +
          4000.0 * float64(s.data[rm][i])), $(which, i)
    doAssert groundForce(s) == groundForce(s, vsB) # B is the default
    doAssert groundForce(s, vsA) != groundForce(s, vsB)
    # with the constant: pounds-force
    let lbf = groundForce(s, vsA, k)
    for i in 0 ..< s.len:
      let fb = scaleOf(s, vcBaseplateA, k)
      let fm = scaleOf(s, vcMassA, k)
      doAssert lbf[i] == float32(fb * float64(s.data[vcBaseplateA][i]) +
        fm * float64(s.data[vcMassA][i]))
    doAssert lbf[3] != groundForce(s, vsA)[3]
    # a constant that is not finite: refused, not NaN output
    doAssertRaises(ValueError):
      discard groundForce(s, vsA, VibScale(accMvPerCount: 0))
    # channels of different lengths (a shot not from the decoder)
    var broken = s
    broken.data[vcMassB].setLen(3)
    doAssertRaises(ValueError):
      discard groundForce(broken)

  block polarity:
    ## No sign is changed: a negative count stays negative in every output.
    var neg = s
    for c in VibChannel:
      for i in 0 ..< neg.len:
        neg.data[c][i] = -abs(neg.data[c][i]) - 1
    for c in VibChannel:
      for v in physical(neg, c, k):
        doAssert v < 0, $c
    for which in VibSet:
      for v in groundForce(neg, which):
        doAssert v < 0
      for v in groundForce(neg, which, k):
        doAssert v < 0

when isMainModule:
  main()
