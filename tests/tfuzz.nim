## Hostile input: a file cut at every length, bytes flipped, pieces of different files
## spliced and the frames filled with random bytes never raise anything but
## `VibFormatError` (no Defect, no hang), with and without `allowIncomplete`. Fixed
## seeds: the same inputs every run. Run in a debug build (range, index and overflow
## checks on) and in `-d:danger` by `nim testRelease`.
##
## Seen to fail: with the frame count taken as `body div 25`, or the tail check taken
## out, `everyPrefix` fails (a cut file is accepted or its frames miscounted).

import std/[math, random]
import parseSSVIB/[decode, sweep, types]
import vibsynth

var reused: VibShot ## one shot decodes every input, as a caller that keeps one does

proc tryParse(d: openArray[byte]; allow: bool): bool =
  ## True when `d` decoded; false when `VibFormatError` refused it. Anything else
  ## escapes and fails the test. The reused shot and the info agree with a new decode.
  try:
    let s = parseVib(d, allow)
    for c in VibChannel:
      doAssert s.data[c].len == s.len
    for v in VibCycleValue:
      doAssert s.cycle[v].len == s.len
    doAssert s.len > 0 and s.frames == s.len and s.len <= d.len div 26
    doAssert s.complete == (s.tailBytes == 0) and (allow or s.complete)
    doAssert s.sweep.valid == (s.triggerSource == tsEstimated)
    if s.sweep.valid:
      doAssert s.triggerFrame >= 0 and s.triggerFrame <= float64(s.len) and
        s.sweep.triggerSigmaFrames >= 0 and s.sweep.startHz > -Inf and
        s.sweep.startHz < Inf and s.sweep.residualCycles <= MaxResidualCycles
    decodeInto(reused, d, allow)
    doAssert reused.data == s.data and reused.complete == s.complete and
      reused.sweep.valid == s.sweep.valid and reused.endsInSweep == s.endsInSweep
    let i = parseVibInfo(d)
    doAssert i.frames == s.frames and i.tailBytes == s.tailBytes and i.start == s.start
    result = true
  except VibFormatError as e:
    doAssert e.msg.len > 0
    result = false
  try:
    let i = parseVibInfo(d)
    doAssert i.frames >= 1 and i.complete == (i.incompleteWhy.len == 0)
  except VibFormatError as e:
    doAssert e.msg.len > 0

proc main*() =
  let base = synthVib(SynthVib(afterTrigger: 200, preTrigger: 20.5))
  doAssert base.len == 47 + 26 * 221

  block everyPrefix:
    for allow in [false, true]:
      for n in 0 .. base.len:
        let ok = tryParse(base[0 ..< n], allow)
        if n < 47 + 26:
          doAssert not ok, "prefix " & $n & " has no samples"
        elif allow or (n - 47) mod 26 == 0:
          doAssert ok, "prefix " & $n & " (allowIncomplete " & $allow & ")"
        else:
          doAssert not ok, "prefix " & $n & " ends in a frame"

  block byteFlips:
    var r = initRand(20240607)
    for i in 0 ..< 2000:
      var d = base
      let at = r.rand(d.len - 1)
      d[at] = d[at] xor byte(1 + r.rand(254))
      discard tryParse(d, false)
      discard tryParse(d, true)

  block headerFlips:
    ## Every bit of the header, one at a time.
    for at in 0 ..< 47:
      for bit in 0 .. 7:
        var d = base
        d[at] = d[at] xor byte(1 shl bit)
        discard tryParse(d, false)
        discard tryParse(d, true)

  block splices:
    var r = initRand(918273)
    let other = synthVib(SynthVib(afterTrigger: 90, preTrigger: 7.25, kindByte: 11))
    let six = synthOtherKind(30)
    let sources = [base, other, six]
    for i in 0 ..< 500:
      var d: seq[byte] = @[]
      for k in 0 ..< 1 + r.rand(6):
        let src = sources[r.rand(2)]
        let a = r.rand(src.len - 1)
        let b = min(src.len - 1, a + r.rand(400))
        d.add src[a .. b]
      if r.rand(3) == 0: # a start that is a real header
        for j in 0 ..< min(47, d.len):
          d[j] = base[j]
      discard tryParse(d, false)
      discard tryParse(d, true)

  block randomFrames:
    ## Random bytes under a valid header: any counts, any floats (NaN, Inf), and a
    ## reference that makes crossings by chance.
    var r = initRand(5551212)
    for i in 0 ..< 400:
      var d = base[0 ..< 47]
      for j in 0 ..< 26 * (1 + r.rand(600)):
        d.add byte(r.rand(255))
      discard tryParse(d, false)
      if r.rand(1) == 0:
        d.add byte(r.rand(255))
        discard tryParse(d, true)

  block hostileReference:
    ## The fit on references made to hurt it: many crossings in a tiny region, a
    ## reference that alternates, a ramp, a huge constant, one huge sample.
    var x = newSeq[int16](5000)
    for i in 0 ..< x.len:
      x[i] = if i mod 2 == 0: 32767'i16 else: -32768'i16
    discard fitSweep(x)
    for i in 0 ..< x.len:
      x[i] = int16(i * 13 mod 65536 - 32768)
    discard fitSweep(x)
    x = newSeq[int16](10000)
    for i in 4000 ..< 4300: # 300 crossings in 300 frames, then nothing
      x[i] = if i mod 2 == 0: 5 else: -5
    discard fitSweep(x)
    for i in 0 ..< 10000:
      x[i] = if i < 9990: 32767 else: -32768
    doAssert fitSweep(x).crossings == 1
    var r = initRand(4)
    for round in 0 ..< 200:
      for i in 0 ..< x.len:
        x[i] = int16(r.rand(65535) - 32768)
      let fit = fitSweep(x)
      doAssert fit.valid == (fit.triggerFrame == fit.triggerFrame)
      discard endsInSweep(x)

  block randomSizes:
    ## Sizes around the frame boundaries of a random file: never an index error.
    var r = initRand(99)
    for n in 0 ..< 400:
      var d = newSeq[byte](r.rand(2000))
      for j in 0 ..< d.len:
        d[j] = byte(r.rand(255))
      if d.len >= 47 and r.rand(1) == 0:
        d[0] = byte('V')
        d[1] = byte('I')
        d[2] = byte('B')
        d[3] = 11
        d[40] = byte(r.rand(59))
        d[41] = byte(r.rand(59))
        d[42] = byte(r.rand(23))
        d[43] = byte(1 + r.rand(27))
        d[44] = byte(1 + r.rand(11))
        d[45] = 0xD1
        d[46] = 0x07
      discard tryParse(d, false)
      discard tryParse(d, true)

when isMainModule:
  main()
