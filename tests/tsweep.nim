## The sweep fit and the stopped-recording test, on synthetic references with made-up
## sweeps.
##
## Seen to fail: with `MinCrossings` at 20, `invalid` accepts the short sweep; with
## `MaxResidualCycles` at 1e6, `invalid` accepts the slightly curved sweep; with a zero
## sample counted as negative, `zeroSamples` fails; with `TailFrames` at 4000,
## `endsInSweep` fails; with the sigma set to 0, `uncertainty` fails; with the rate taken
## from the wrong coefficient, `fractions` fails.

import std/[math, random]
import parseSSVIB/[sweep, types]
import vibsynth

proc main*() =

  block fractions:
    ## The trigger within 0.02 frames of the true one at several fractions of a frame,
    ## and the sweep's start and rate within 0.001.
    for (pre, f0, rate) in [(520.03, 20.0, 30.0), (600.5, 20.0, 30.0), (700.94, 20.0, 30.0),
        (823.4, 8.0, 12.0), (520.5, 6.0, 8.0), (650.25, 31.25, 5.5)]:
      let syn = SynthVib(preTrigger: pre, startHz: f0, rateHzPerS: rate,
        afterTrigger: (if f0 < 10: 12000 else: 6000))
      let fit = fitSweep(synthRef(syn))
      doAssert fit.valid, $(pre, f0, rate)
      doAssert abs(fit.triggerFrame - pre) < 0.02, $(pre, fit.triggerFrame)
      doAssert abs(fit.startHz - f0) < 0.001, $(f0, fit.startHz)
      doAssert abs(fit.rateHzPerS - rate) < 0.001, $(rate, fit.rateHzPerS)
      doAssert fit.residualCycles < 0.01 and fit.rmsCycles <= fit.residualCycles
      doAssert fit.crossings >= 200

  block intervals:
    ## The same sweep at another interval: the frequencies follow the interval.
    let syn = SynthVib(preTrigger: 400.25, intervalUs: 1000, startHz: 5.0,
      rateHzPerS: 6.0, afterTrigger: 12000)
    let fit = fitSweep(synthRef(syn), 1000.0)
    doAssert fit.valid and abs(fit.triggerFrame - 400.25) < 0.02
    doAssert abs(fit.startHz - 5.0) < 0.001 and abs(fit.rateHzPerS - 6.0) < 0.001
    # the wrong interval gives the wrong frequencies, not a wrong trigger
    let half = fitSweep(synthRef(syn), 500.0)
    doAssert abs(half.triggerFrame - fit.triggerFrame) < 1e-9
    doAssert abs(half.startHz - 10.0) < 0.002

  block uncertainty:
    ## The formal one-sigma: finite, positive, small, and the error is within a few of it.
    for pre in [520.03, 600.5, 700.94, 640.77]:
      let fit = fitSweep(synthRef(SynthVib(preTrigger: pre)))
      doAssert fit.triggerSigmaFrames > 0 and fit.triggerSigmaFrames < 0.02, $fit
      doAssert abs(fit.triggerFrame - pre) <= 6 * fit.triggerSigmaFrames, $(pre, fit)
    # noise makes it larger, never absurd, and the fit still holds
    var r = initRand(777)
    var quiet = synthRef(SynthVib(preTrigger: 611.25))
    var noisy = quiet
    for i in 0 ..< noisy.len:
      if abs(int(noisy[i])) > 60: # no sign flips: a noise that makes crossings is no sweep
        noisy[i] = int16(int(noisy[i]) + r.rand(-40 .. 40))
    let a = fitSweep(quiet)
    let b = fitSweep(noisy)
    doAssert b.valid and abs(b.triggerFrame - 611.25) < 0.1, $b
    doAssert b.triggerSigmaFrames > a.triggerSigmaFrames and b.triggerSigmaFrames < 0.1

  block invalid:
    ## A pulse, a constant, a reference of zeros, a non-linear sweep and a sweep that is
    ## too short are no estimate; the fit never raises.
    proc isNone(fit: VibSweep) =
      doAssert not fit.valid and fit.triggerFrame.isNaN and fit.startHz.isNaN and
        fit.rateHzPerS.isNaN and fit.triggerSigmaFrames.isNaN
    var pulse = newSeq[int16](3000)
    for i in 100 .. 130:
      pulse[i] = int16(20000 - 300 * (i - 100))
    isNone fitSweep(pulse)
    isNone fitSweep(newSeq[int16](3000))
    isNone fitSweep(newSeq[int16](0))
    isNone fitSweep(@[int16 5])
    var constant = newSeq[int16](3000)
    for x in constant.mitems: x = 100
    isNone fitSweep(constant)
    let cubic = fitSweep(synthRef(SynthVib(cubicHzPerS2: 40)))
    isNone cubic
    doAssert cubic.crossings >= 200 and cubic.residualCycles > 0.05
    # a slightly curved frequency law: only the residual limit refuses it
    let mild = fitSweep(synthRef(SynthVib(cubicHzPerS2: 0.5)))
    isNone mild
    doAssert mild.residualCycles > 0.05 and mild.residualCycles < 1.0
    let tiny = fitSweep(synthRef(SynthVib(afterTrigger: 1500))) # about 40 cycles
    isNone tiny
    doAssert tiny.crossings < 200 and tiny.crossings > 20
    # a sweep just long enough has 200 crossings or more and is valid
    let enough = fitSweep(synthRef(SynthVib(afterTrigger: 4500)))
    doAssert enough.crossings >= 200 and enough.valid
    # white noise has crossings and no phase
    var r = initRand(31)
    var noise = newSeq[int16](20000)
    for x in noise.mitems: x = int16(r.rand(-3000 .. 3000))
    let wn = fitSweep(noise)
    doAssert wn.crossings > 200 and not wn.valid
    # intervals that are not positive and finite: invalid, not an exception
    for bad in [0.0, -500.0, NaN, Inf]:
      isNone fitSweep(synthRef(SynthVib()), bad)

  block zeroSamples:
    ## Crossings: a sign change between two frames; a zero counts as non-negative.
    doAssert fitSweep(@[int16 -1, 0, 0, -1]).crossings == 2
    doAssert fitSweep(@[int16 1, 0, 0, 1]).crossings == 0
    doAssert fitSweep(@[int16 1, -1, 1, -1, 1]).crossings == 4
    doAssert fitSweep(@[int16 -32768, 32767, -32768]).crossings == 2
    doAssert fitSweep(@[int16 0, 0, 0, 0]).crossings == 0
    # a long alternation has a crossing between every two frames
    var alt = newSeq[int16](400)
    for i in 0 ..< alt.len:
      alt[i] = if i mod 2 == 0: 1 else: -1
    doAssert fitSweep(alt).crossings == 399

  block taperStart:
    ## A reference that is zero before the trigger and tapers in: the first half-cycle
    ## is crossing 1 (the zero run is not a crossing).
    let syn = SynthVib(preTrigger: 555.5, taperFrames: 900)
    let fit = fitSweep(synthRef(syn))
    doAssert fit.valid and abs(fit.triggerFrame - 555.5) < 0.02

  block endsInSweep:
    ## True only when the record stops inside the sweep.
    doAssert not endsInSweep(synthRef(SynthVib()))
    doAssert not endsInSweep(synthRef(SynthVib(afterTrigger: 300, taperFrames: 300)))
    doAssert endsInSweep(synthRef(SynthVib(stopAt: 5000)))
    doAssert not endsInSweep(newSeq[int16](1000))
    doAssert not endsInSweep(newSeq[int16](0))
    doAssert endsInSweep(@[int16 100])
    # the limit is a quarter of the peak, in the last 40 frames only
    var x = newSeq[int16](200)
    x[10] = 1000
    x[159] = 250 # the 41st from the end
    doAssert not endsInSweep(x)
    x[160] = 250
    doAssert not endsInSweep(x) # 250 is a quarter: not above it
    x[199] = 251
    doAssert endsInSweep(x)
    x[199] = 0
    x[199] = -251 # the sign does not matter
    doAssert endsInSweep(x)
    x[199] = -32768 # the largest magnitude of 16 bits
    doAssert endsInSweep(x)

when isMainModule:
  main()
