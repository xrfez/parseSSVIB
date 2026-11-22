## A decoded shot written through parseSEG's SEG-Y and SEG-D writers and read back with
## parseSEG: samples bit for bit, trace codes, the time axis, times and text.
##
## Seen to fail: with `segyTraceCode` ignoring `primary` for set A, `mapping` fails; with
## the status of every trace tsDead, `codes` fails; with `t0Ms` positive in
## `toTraceKeys`, `codes` and `timeAxis` fail; with the `ext1.nanoseconds` override left
## out, `exactNanoseconds` fails; with the mean not removed, `scaleAndMean` fails; with
## the Rev 2 refusal of the converter left out, `externalRefusals` fails; with
## `CardWidth` at 80, `cards` fails; with the claim of the file name left out,
## `folderForms` fails; with the SEG-D baseplate type swapped for the mass type, `segd`
## fails; with the cycle values' codes at 256 + 8, `cycleValues` fails; with the ground
## force summing one channel twice, `codes` fails; with the record axis taking the
## trigger's time, `timeAxis` fails; with a sign flipped on the way out,
## `polarityAsRecorded` fails.
## Also seen to fail: with the card writer's `at <= 2` back at `at <= 0`, `cardLoop` never
## returns; with Rev 0 given the Rev 1 status, `revisionZero` fails; with the clock's
## `round` taken out, `roundedClock` fails; with the interval, record or trigger bounds
## taken out, `intervalBound`, `recordBound` and `cardLoop` fail.

import std/[atomics, math, os, sequtils, strutils]
import parseSEG
import parseSSVIB
import vibsynth

proc tmpDir(): string =
  result = getTempDir() / ("ssvib-tseg-" & $getCurrentProcessId())
  createDir(result)

proc readBack(f: SeismicFile; n: int): seq[seq[float32]] =
  var log: DiagLog
  let x = f.readTraces(0 ..< n, log)
  doAssert log.len == 0
  for i in 0 ..< n:
    result.add newSeq[float32](x.shape[1])
    for j in 0 ..< x.shape[1]:
      result[i][j] = x[i, j]

proc headerValue(f: SeismicFile; trace: int; header, field: string): string =
  for r in f.traceHeaders(trace):
    if r.blockName == header and r.field == field:
      return $r.value
  doAssert false, "no " & header & "." & field

proc flat(text: string): string =
  ## The text with the card numbers ("C 5 ") dropped and every run of white space as
  ## one space, so a line continued on the next card reads as one.
  var parts: seq[string] = @[]
  for line in text.splitLines:
    if line.len >= 4 and line[0] == 'C': parts.add line[4 .. ^1] else: parts.add line
  parts.join(" ").splitWhitespace.join(" ")

proc bitsEqual(a, b: seq[float32]): bool =
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    if cast[uint32](a[i]) != cast[uint32](b[i]): return false
  true

proc meanOf(v: seq[int16]): float64 =
  var sum = 0.0
  for x in v:
    sum += float64(x)
  sum / float64(v.len)

proc refusal(s: VibShot; words: openArray[string]; segd = false;
    vib = VibWriteOptions(); segy = SegyOutputOptions()) =
  ## Writing `s` raises `VibWriteError` whose message holds all `words`.
  let p = getTempDir() / ("ssvib-tseg-refused-" & $getCurrentProcessId())
  try:
    if segd: s.writeSegd(p, vib) else: s.writeSegy(p, segy, vib)
    doAssert false, "was written (wanted: " & $words & ")"
  except VibWriteError as e:
    for w in words:
      doAssert w in e.msg, "'" & w & "' not in: " & e.msg
  doAssert not fileExists(p)

const
  rev1 = SegyOutputOptions(revision: SegyRevision(major: 1, minor: 0))
  made = VibScale(accMvPerCount: 0.5, torquePctPerCount: 0.125, lvdtFactor: 8000.0,
    drivePerCount: 0.0625) ## made-up constants, exact in binary
  trig = VibTime(year: 2001, month: 2, day: 3, hour: 4, minute: 5, second: 7,
    nanosecond: 789_000_000)

proc main*() =
  let dir = tmpDir()
  defer: removeDir(dir)
  let syn = SynthVib(preTrigger: 40.25, afterTrigger: 260, taperFrames: 20, startHz: 30,
    rateHzPerS: 40)
  var s = parseVib(synthVib(syn))
  s.cycle[vvDriveRatio][3] = NaN.float32
  s.cycle[vvCycle2][4] = -0.0'f32
  s.data[vcDrive][5] = -32768
  s.data[vcDrive][6] = 32767
  s.triggerFrame = 40.25 # the synthetic record is too short for the fit: as if given
  s.triggerSource = tsGiven
  let start = float64(posixSeconds(s.start))
  let n = s.len

  block mapping:
    doAssert segyTraceCode(vcReference) == 21
    doAssert [segyTraceCode(vcBaseplateA), segyTraceCode(vcMassA)] == [257'i16, 258]
    doAssert [segyTraceCode(vcBaseplateB), segyTraceCode(vcMassB)] == [19'i16, 18]
    doAssert [segyTraceCode(vcBaseplateA, vsA), segyTraceCode(vcMassA, vsA)] ==
      [19'i16, 18]
    doAssert [segyTraceCode(vcBaseplateB, vsA), segyTraceCode(vcMassB, vsA)] ==
      [259'i16, 260]
    doAssert [segyTraceCode(vcTorqueMotor), segyTraceCode(vcValve),
      segyTraceCode(vcMassStroke), segyTraceCode(vcDrive)] == [261'i16, 262, 263, 264]
    doAssert [segyTraceCode(vvDriveRatio), segyTraceCode(vvCycle2)] == [265'i16, 266]
    doAssert segyGroundForceCode(vsB) == 20 and segyGroundForceCode(vsA) == 267
    doAssert segyGroundForceCode(vsA, vsA) == 20 and segyGroundForceCode(vsB, vsA) == 267
    doAssert segdChannelType(vcReference) == sctSourceRefSweep and
      segdChannelType(vcReference, reference = sctSourceRefPilot) == sctSourceRefPilot
    doAssert segdChannelType(vcBaseplateB) == sctSourceBasePlate and
      segdChannelType(vcMassB) == sctSourceMass and
      segdChannelType(vcBaseplateA) == sctSourceOther and
      segdChannelType(vcBaseplateA, vsA) == sctSourceBasePlate and
      segdChannelType(vcValve) == sctSourceValve and
      segdChannelType(vcDrive) == sctSourceExcitation and
      segdChannelType(vcTorqueMotor) == sctSourceOther
    doAssert $vcBaseplateB == "baseplate acceleration, set B" and $vsB == "B"
    let k = toTraceKeys(s, 19, 4)
    doAssert k.record == 1 and k.channel == 4 and k.traceCode == 19 and
      k.status == tsAuxiliary and k.intervalUs == 500 and
      abs(k.t0Ms + 40.25 * 0.5) < 1e-9 and k.time == start
    doAssert k.srcX.isNaN and k.srcLine.isNaN and k.srcPoint.isNaN
    doAssert toTraceKeys(s, 19, 4, VibWriteOptions(record: 12)).record == 12
    doAssert toTraceKeys(s, 19, 4, firstFrame = 100).t0Ms == (100 - 40.25) * 0.5

  block codes:
    let p = dir / "a.sgy"
    s.writeSegy(p)
    var f = openSeismic(p, keys = true)
    doAssert f.len == 10 # the nine channels and the computed ground force
    let expected = [21'i16, 257, 258, 19, 18, 261, 262, 263, 264, 20]
    for i in 0 ..< 10:
      let k = f.traceKeys(i)
      doAssert k.traceCode == expected[i] and k.status == (if expected[i] <
          100: tsAuxiliary else: tsUnknown),
        $(i, k.traceCode, k.status)
      doAssert k.record == 1 and k.channel == float64(i + 1)
      doAssert k.time == start and k.intervalUs == 500, $(k.time, start, k.intervalUs)
      doAssert abs(k.t0Ms + 20.125) < 1e-3, $k.t0Ms
      doAssert k.srcX.isNaN and k.srcPoint.isNaN
    let back = readBack(f, 10)
    for c in VibChannel:
      doAssert bitsEqual(back[ord(c)], s.samples(c)), "samples of " & $c # bit for bit
    var gf: seq[float32] = @[]
    for i in 0 ..< n:
      gf.add float32(6000.0 * float64(s.data[vcBaseplateB][i]) +
        4000.0 * float64(s.data[vcMassB][i]))
    doAssert bitsEqual(back[9], gf)
    doAssert bitsEqual(back[9], groundForce(s))
    let text = f.textHeader
    for w in ["vibrator controller .vib signature record", "recording began 2001-02-03",
        "record 1", "(assumed)", "raw counts", "ground force (computed, an estimate)",
        "baseplate weight x baseplate", "trigger frame 40.250 given by the caller",
        "t = 0 is the trigger", "second the recording began, not the trigger",
        "trace 1 reference (counts)", "trace 4 baseplate acceleration, set B (counts)",
        "trace 10 ground force, estimated, from accelerometer set B (pound-counts)",
        "no polarity is changed", "parseSSVIB"]:
      doAssert w in flat(text), w
    for banned in ["real", "true", "measured", "simulated"]:
      doAssert banned notin text, banned
    f.close()
    # the ground force switched off; a subset of channels
    s.writeSegy(dir / "a2.sgy", vib = VibWriteOptions(groundForce: {},
      channels: {vcReference, vcMassB}))
    f = openSeismic(dir / "a2.sgy", keys = true)
    doAssert f.len == 2 and f.traceKeys(0).traceCode == 21 and f.traceKeys(1).traceCode == 18
    doAssert "ground force" notin f.textHeader
    f.close()
    # a record number of its own; the file name's number otherwise
    s.writeSegy(dir / "a3.sgy", vib = VibWriteOptions(record: 77, groundForce: {},
      channels: {vcReference}))
    f = openSeismic(dir / "a3.sgy", keys = true)
    doAssert f.traceKeys(0).record == 77
    f.close()
    var named = s
    named.nameNumber = 4242
    named.writeSegy(dir / "a4.sgy", vib = VibWriteOptions(groundForce: {},
      channels: {vcReference}))
    f = openSeismic(dir / "a4.sgy", keys = true)
    doAssert f.traceKeys(0).record == 4242
    f.close()

  block primarySet:
    ## The other set gets the standard codes when it is named primary.
    s.writeSegy(dir / "pa.sgy", vib = VibWriteOptions(primary: vsA, groundForce: {vsA, vsB}))
    var f = openSeismic(dir / "pa.sgy", keys = true)
    doAssert f.len == 11
    var codes: seq[int16] = @[]
    for i in 0 ..< f.len:
      codes.add f.traceKeys(i).traceCode
    doAssert codes == @[21'i16, 19, 18, 259, 260, 261, 262, 263, 264, 20, 267], $codes
    let back = readBack(f, 11)
    doAssert bitsEqual(back[9], groundForce(s, vsA)) and bitsEqual(back[10], groundForce(s, vsB))
    f.close()
    # both sets, the default primary: the order is primary first
    s.writeSegy(dir / "pb.sgy", vib = VibWriteOptions(groundForce: {vsA, vsB},
      channels: {}))
    f = openSeismic(dir / "pb.sgy", keys = true)
    doAssert f.len == 2 and f.traceKeys(0).traceCode == 20 and f.traceKeys(1).traceCode == 267
    let b2 = readBack(f, 2)
    doAssert bitsEqual(b2[0], groundForce(s, vsB)) and bitsEqual(b2[1], groundForce(s, vsA))
    f.close()

  block cycleValues:
    s.writeSegy(dir / "cy.sgy", vib = VibWriteOptions(cycleValues: true, groundForce: {},
      channels: {vcReference}))
    var f = openSeismic(dir / "cy.sgy", keys = true)
    doAssert f.len == 3 and f.traceKeys(1).traceCode == 265 and f.traceKeys(2).traceCode == 266
    let back = readBack(f, 3)
    doAssert bitsEqual(back[1], s.samples(vvDriveRatio)) # the NaN too
    doAssert bitsEqual(back[2], s.samples(vvCycle2)) # and the -0.0
    doAssert back[1][3].isNaN and cast[uint32](back[2][4]) == cast[uint32](-0.0'f32)
    f.close()

  block timeAxis:
    ## The default: t = 0 at the trigger frame; `vaRecord`: at the first frame. The `time`
    ## key is the trigger's when the caller gave it, else the second the recording began.
    var f: SeismicFile
    s.writeSegy(dir / "t1.sgy", vib = VibWriteOptions(timeAxis: vaRecord, groundForce: {},
      channels: {vcReference}))
    f = openSeismic(dir / "t1.sgy", keys = true)
    doAssert f.traceKeys(0).t0Ms == 0 and f.traceKeys(0).time == start
    doAssert "t = 0 is the first frame" in f.textHeader
    f.close()
    var known = s
    known.setTrigger(trig)
    known.writeSegy(dir / "t2.sgy", vib = VibWriteOptions(groundForce: {}, channels: {vcReference}))
    f = openSeismic(dir / "t2.sgy", keys = true)
    doAssert abs(f.traceKeys(0).t0Ms + 20.125) < 1e-3
    doAssert abs(f.traceKeys(0).time - (float64(posixSeconds(trig)) + 0.789)) < 1e-3,
      $f.traceKeys(0).time
    doAssert "date/time is the trigger time, given by the caller (from the .dat file)" in
      flat(f.textHeader)
    f.close()
    # the record axis with a known trigger: t = 0 is the first frame, 20.125 ms earlier
    known.writeSegy(dir / "t3.sgy", vib = VibWriteOptions(timeAxis: vaRecord,
      groundForce: {}, channels: {vcReference}))
    f = openSeismic(dir / "t3.sgy", keys = true)
    doAssert f.traceKeys(0).t0Ms == 0
    doAssert abs(f.traceKeys(0).time - (float64(posixSeconds(trig)) + 0.789 - 0.020125)) < 1e-3,
      $f.traceKeys(0).time
    f.close()
    # without a trigger frame, the trigger axis falls back to the record axis
    var none = s
    none.triggerFrame = NaN
    none.triggerSource = tsNone
    none.writeSegy(dir / "t4.sgy", vib = VibWriteOptions(groundForce: {}, channels: {vcReference}))
    f = openSeismic(dir / "t4.sgy", keys = true)
    doAssert f.traceKeys(0).t0Ms == 0 and f.traceKeys(0).time == start
    doAssert "no trigger frame: t = 0 is the first frame" in f.textHeader
    f.close()
    # a negative start survives SEG-D too
    s.writeSegd(dir / "t5.sgd", VibWriteOptions(groundForce: {}, channels: {vcReference}))
    f = openSeismic(dir / "t5.sgd", keys = true)
    doAssert abs(f.traceKeys(0).t0Ms + 20.125) < 1e-3, $f.traceKeys(0).t0Ms
    f.close()
    # the estimated frame is the one that reaches the file
    var est = s
    est.triggerFrame = 100.5
    est.triggerSource = tsEstimated
    est.triggerSigmaFrames = 0.5
    est.writeSegy(dir / "t6.sgy", vib = VibWriteOptions(groundForce: {}, channels: {vcReference}))
    f = openSeismic(dir / "t6.sgy", keys = true)
    doAssert abs(f.traceKeys(0).t0Ms + 50.25) < 1e-3
    doAssert "trigger frame 100.500 estimated from the reference" in
      flat(f.textHeader)
    doAssert "one sigma 0.500 frames" in flat(f.textHeader), flat(f.textHeader)
    f.close()

  block exactNanoseconds:
    ## The trigger time's nanoseconds reach a Rev 2 file as they are; on the record
    ## axis they are those of the first frame's time.
    var known = s
    for ns in [789_000_000, 123_456_789, 999_999_999, 1, 0]:
      var t = trig
      t.nanosecond = ns
      known.setTrigger(t)
      let p = dir / "ns.sgy"
      known.writeSegy(p, vib = VibWriteOptions(groundForce: {}, channels: {vcReference}))
      var f = openSeismic(p, keys = true)
      doAssert f.headerValue(0, "ext1", "nanoseconds") == $ns, $ns
      doAssert f.headerValue(0, "trace", "second") == "7", $ns
      f.close()
    # the record axis: trigger 7.000000100 s minus 20.125 ms = 6.979875100
    var t = trig
    t.nanosecond = 100
    known.setTrigger(t)
    known.writeSegy(dir / "ns2.sgy", vib = VibWriteOptions(timeAxis: vaRecord,
      groundForce: {}, channels: {vcReference}))
    var f = openSeismic(dir / "ns2.sgy", keys = true)
    doAssert f.headerValue(0, "ext1", "nanoseconds") == "979875100"
    doAssert f.headerValue(0, "trace", "second") == "6"
    f.close()
    # Rev 1 has no extension header: the file is written, to the second and a fraction
    s.writeSegy(dir / "r1.sgy", rev1)
    f = openSeismic(dir / "r1.sgy", keys = true)
    doAssert f.len == 10 and abs(f.traceKeys(0).time - start) < 1.0
    f.close()

  block cards:
    ## Cards are at most 76 characters (parseSEG adds "C nn "); a longer line goes on
    ## the next card, never cut.
    let long = VibWriteOptions(units: vuPhysical, scale: VibScale(accMvPerCount: 123456.789,
      torquePctPerCount: 2.5, lvdtFactor: 0.25, drivePerCount: 3.5), removeMean: true,
      controllerSerial: 4321)
    let longCards = textCards(s, long)
    for c in longCards:
      doAssert c.len <= 76, c
    let joined = longCards.join("\n").replace("\n  ", " ")
    for w in ["acc 123456.789", "torque motor 2.5", "lvdt 0.25", "drive 3.5",
        "mean removed", "controller serial 4321 (given by the caller, not in the file)"]:
      doAssert w in joined, w
    var wide = s
    wide.incompleteWhy = "the file ends 13 bytes into a frame: a copy cut short, and a " &
      "second sentence to make the card long enough to continue"
    wide.complete = false
    wide.endsInSweep = true
    let cuts = textCards(wide, VibWriteOptions())
    for c in cuts:
      doAssert c.len <= 76, c
    let all = cuts.join("\n").replace("\n  ", " ")
    doAssert "incomplete recording: the file ends 13 bytes into a frame: a copy cut " &
      "short, and a second sentence to make the card long enough to continue" in all, all
    doAssert "the record ends inside the sweep: a stopped recording" in all
    wide.writeSegy(dir / "cards.sgy", vib = long)
    var f = openSeismic(dir / "cards.sgy")
    for line in f.textHeader.splitLines:
      doAssert line.len == 80
    doAssert "stopped recording" in f.textHeader
    f.close()

  block scaleAndMean:
    let p = dir / "g.sgy"
    s.writeSegy(p, vib = VibWriteOptions(removeMean: true, cycleValues: true,
      groundForce: {vsB}))
    var f = openSeismic(p)
    let back = readBack(f, 12)
    for c in VibChannel:
      let m = meanOf(s.data[c])
      for j in 0 ..< n:
        doAssert back[ord(c)][j] == float32(float64(s.data[c][j]) - m), $(c, j)
    doAssert "raw counts, mean removed" in f.textHeader
    # the ground force of the mean-removed channels
    let mb = meanOf(s.data[vcBaseplateB])
    let mm = meanOf(s.data[vcMassB])
    for j in 0 ..< n:
      doAssert back[11][j] == float32(6000.0 * (float64(s.data[vcBaseplateB][j]) - mb) +
        4000.0 * (float64(s.data[vcMassB][j]) - mm)), $j
    f.close()

  block physical:
    let o = VibWriteOptions(units: vuPhysical, scale: made, groundForce: {vsB})
    s.writeSegy(dir / "ph.sgy", vib = o)
    var f = openSeismic(dir / "ph.sgy", keys = true)
    let back = readBack(f, 10)
    for c in VibChannel:
      let fct = scaleOf(s, c, made)
      for j in 0 ..< n:
        doAssert back[ord(c)][j] == float32(fct * float64(s.data[c][j])), $(c, j)
    doAssert bitsEqual(back[9], groundForce(s, vsB, made))
    doAssert back[0][100] == float32(40000.0 / 32767.0 * float64(s.data[vcReference][100]))
    let text = flat(f.textHeader)
    for w in ["physical units; constants: acc 0.5", "(lbf)", "(percent)", "(unit unknown)",
        "ground force, estimated, from accelerometer set B (lbf)"]:
      doAssert w in text, w
    f.close()
    # in g instead of lbf
    s.writeSegy(dir / "ph2.sgy", vib = VibWriteOptions(units: vuPhysical, scale: made,
      force: false, groundForce: {vsB}, channels: {vcBaseplateB}))
    f = openSeismic(dir / "ph2.sgy")
    let b2 = readBack(f, 2)
    doAssert b2[0][50] == float32(0.5 / 20.0 * float64(s.data[vcBaseplateB][50]))
    # the ground force stays in lbf: it needs the weights
    doAssert bitsEqual(b2[1], groundForce(s, vsB, made))
    doAssert "(g)" in f.textHeader
    f.close()
    # physical needs the constants: plain words
    refusal(s, ["vib file (unnumbered)", "the accelerometer constant", "not finite and above 0",
      "physical units"], vib = VibWriteOptions(units: vuPhysical))
    refusal(s, ["torque-motor constant"], vib = VibWriteOptions(units: vuPhysical,
      scale: VibScale(accMvPerCount: 1), channels: {vcTorqueMotor}, groundForce: {}))
    # only what is written is needed
    s.writeSegy(dir / "ph3.sgy", vib = VibWriteOptions(units: vuPhysical,
      channels: {vcReference}, groundForce: {}))
    var zero = s
    zero.header.holdDownLb = 0
    refusal(zero, ["hold-down weight"], vib = VibWriteOptions(units: vuPhysical,
      channels: {vcReference}, groundForce: {}))
    # the ground force in lbf needs a weight
    zero = s
    zero.header.massLb = 0
    refusal(zero, ["weights are 6000.0 and 0.0", "set B"], vib = VibWriteOptions(
      channels: {vcReference}))
    refusal(zero, ["reaction-mass weight", "pounds-force"], vib = VibWriteOptions(
      units: vuPhysical, scale: made, channels: {vcReference}))

  block externalConverter:
    ## The external converter's 13 traces from made-up constants: the first `cut` frames
    ## dropped, every mean removed, its scales and codes.
    let cut = 7
    let o = VibWriteOptions(externalConverter: true, scale: made, converterCut: cut)
    s.writeSegy(dir / "cv.sgy", rev1, o)
    var f = openSeismic(dir / "cv.sgy", keys = true)
    doAssert f.len == 13
    let codes = [21'i16, 19, 18, 20, 29, 28, 30, 33, 34, 35, 36, 1, 1]
    for i in 0 ..< 13:
      doAssert f.traceKeys(i).traceCode == codes[i], $i
      doAssert f.traceKeys(i).status == (if codes[i] == 1: tsLive else: tsUnknown) or
        codes[i] in [21'i16, 19, 18, 20]
      doAssert f.traceKeys(i).intervalUs == 500
      doAssert abs(f.traceKeys(i).t0Ms - (float64(cut) - 40.25) * 0.5) < 1e-3
    let back = readBack(f, 13)
    doAssert back[0].len == n - cut
    proc kept(c: VibChannel): seq[float64] =
      for j in cut ..< n:
        result.add float64(s.data[c][j])
    proc mean(x: seq[float64]): float64 =
      for v in x: result += v
      result / float64(x.len)
    proc scaled(c: VibChannel): seq[float64] =
      let x = kept(c)
      let m = mean(x)
      let fct = scaleOf(s, c, made)
      for v in x: result.add fct * (v - m)
    proc same(t: seq[float32]; v: seq[float64]; what: string) =
      doAssert t.len == v.len, what
      for j in 0 ..< v.len:
        doAssert t[j] == float32(v[j]), what & " " & $j
    same(back[0], scaled(vcReference), "reference")
    same(back[1], scaled(vcBaseplateA), "baseplate A")
    same(back[2], scaled(vcMassA), "mass A")
    var sumA: seq[float64] = @[]
    for j in 0 ..< n - cut:
      sumA.add scaled(vcBaseplateA)[j] + scaled(vcMassA)[j]
    same(back[3], sumA, "ground force A")
    same(back[4], scaled(vcBaseplateB), "baseplate B")
    same(back[5], scaled(vcMassB), "mass B")
    var sumB: seq[float64] = @[]
    for j in 0 ..< n - cut:
      sumB.add scaled(vcBaseplateB)[j] + scaled(vcMassB)[j]
    same(back[6], sumB, "ground force B")
    same(back[7], scaled(vcTorqueMotor), "torque motor")
    same(back[8], scaled(vcValve), "valve")
    same(back[9], scaled(vcMassStroke), "mass displacement")
    same(back[10], scaled(vcDrive), "drive")
    for v in VibCycleValue:
      var x: seq[float64] = @[]
      for j in cut ..< n: x.add float64(s.cycle[v][j])
      let m = mean(x)
      if not m.isNaN: # the NaN of the test shot makes this mean NaN, as the converter's
        var y: seq[float64] = @[]
        for a in x: y.add a - m
        same(back[11 + ord(v)], y, $v)
    doAssert "converter-compatible traces: first 7 frames dropped, mean removed" in f.textHeader
    f.close()
    # the polarity of every trace is the file's: a positive-going count stays positive
    # (a trace mean removed can be either; the reference is checked by its formula above)

  block externalRefusals:
    let o = VibWriteOptions(externalConverter: true, scale: made, converterCut: 3)
    refusal(s, ["SEG-Y Rev 1 only", "codes 28 to 36", "Rev 2"], vib = o) # the default Rev 2.1
    refusal(s, ["Rev 1 only", "Rev 0"], vib = o, segy = SegyOutputOptions(
      revision: SegyRevision(major: 0, minor: 0)))
    refusal(s, ["SEG-Y Rev 1 only", "SEG-D"], true, o)
    var w = openSeismicWriter(dir / "rv2.sgy", SegyOutputOptions())
    doAssertRaises(VibWriteError):
      w.writeSegyTraces(s, o, extHeader = true)
    discard w.close()
    refusal(s, ["cut of -1 frames"], vib = VibWriteOptions(externalConverter: true,
      scale: made), segy = rev1)
    refusal(s, ["cut of " & $n & " frames"], vib = VibWriteOptions(externalConverter: true,
      scale: made, converterCut: n), segy = rev1)
    refusal(s, ["the accelerometer constant"], vib = VibWriteOptions(externalConverter: true,
      converterCut: 1), segy = rev1)
    refusal(s, ["the drive constant", "external converter's traces"], vib = VibWriteOptions(
      externalConverter: true, scale: VibScale(accMvPerCount: 1, torquePctPerCount: 1,
      lvdtFactor: 1), converterCut: 1), segy = rev1)
    # the converter's cut of every frame but one is still a file
    s.writeSegy(dir / "cv1.sgy", rev1, VibWriteOptions(externalConverter: true,
      scale: made, converterCut: n - 1))
    var f = openSeismic(dir / "cv1.sgy")
    doAssert f.len == 13
    f.close()

  block segd:
    let p = dir / "j.sgd"
    s.writeSegd(p) # the default options
    var f = openSeismic(p, keys = true)
    doAssert f.len == 10
    # the writer makes one channel set per channel type, in order of first appearance;
    # the traces of a set follow each other, so the file's trace order is by set
    var types: seq[int]
    var traces = 0
    for cs in f.channelSets:
      types.add cs.channelType
      traces += cs.traceCount
      doAssert cs.samplesPerTrace == n and cs.sampleIntervalUs == 500
    doAssert traces == 10
    doAssert types == @[0x96, 0x97, 0x95, 0x99, 0x9B, 0x9A, 0x93], $types
    for i in 0 ..< 10:
      let k = f.traceKeys(i)
      doAssert k.record == 1 and k.status == tsAuxiliary, $k.status
      doAssert abs(k.time - start) < 1e-6, $(k.time, start)
      doAssert k.srcX.isNaN and k.srcY.isNaN, "no position is written"
    let back = readBack(f, 10)
    for c in VibChannel:
      doAssert anyIt(back, bitsEqual(it, s.samples(c))), "SEG-D samples of " & $c
    f.close()
    s.writeSegd(dir / "k.sgd", VibWriteOptions(groundForce: {vsA, vsB}, cycleValues: true,
      segdReference: sctSourceRefPilot, record: 99))
    f = openSeismic(dir / "k.sgd", keys = true)
    var t2: seq[int]
    for cs in f.channelSets: t2.add cs.channelType
    doAssert t2 == @[0x98, 0x97, 0x95, 0x99, 0x9B, 0x9A, 0x93], $t2
    doAssert f.len == 13 and f.traceKeys(0).record == 99
    f.close()
    refusal(s, ["SEG-D reference channel type is 0x70", "not 0x96 or 0x98"], true,
      VibWriteOptions(segdReference: sctOther))

  block writerRefusals:
    ## Plain words that name the value, as `VibWriteError`.
    var odd = s
    odd.sampleIntervalUs = 500.5
    refusal(odd, ["500.5 us", "whole number of microseconds"], true)
    odd.writeSegy(dir / "odd.sgy") # SEG-Y takes a fractional interval
    refusal(s, ["record number 16777216", "above 16777215"], true,
      VibWriteOptions(record: 16_777_216))
    s.writeSegd(dir / "num.sgd", VibWriteOptions(record: 16_777_215))
    refusal(s, ["record number -5 is negative"], vib = VibWriteOptions(record: -5))
    refusal(s, ["no trace is chosen"], vib = VibWriteOptions(channels: {}, groundForce: {}))
    refusal(s, ["no trace is chosen"], true, VibWriteOptions(channels: {}, groundForce: {}))
    # a shot with no samples (not from the decoder), or channels of different lengths
    refusal(VibShot(), ["holds no samples"])
    refusal(VibShot(), ["holds no samples"], true)
    var broken = s
    broken.data[vcMassA].setLen(5)
    refusal(broken, ["reaction-mass acceleration, set A channel has 5 samples"])
    broken = s
    broken.cycle[vvCycle2].setLen(5)
    refusal(broken, ["per-cycle value 2", "5 samples"])
    var badInterval = s
    badInterval.sampleIntervalUs = 0
    refusal(badInterval, ["sample interval 0.0 us is not positive"])
    var badTrigger = s
    badTrigger.triggerFrame = float64(n) + 5
    refusal(badTrigger, ["trigger frame", "outside the shot's"])
    refusal(badTrigger, ["trigger frame", "outside the shot's"], vib = VibWriteOptions(
      timeAxis: vaRecord)) # on every axis
    # an extreme year does not overflow the time: SEG-D takes it or refuses it in words
    var far = s
    far.start.year = 9999
    far.writeSegy(dir / "far.sgy")
    try:
      far.writeSegd(dir / "far.sgd")
    except VibWriteError:
      discard

  block severalShots:
    ## Several shots into one writer: one record each, SEG-Y and SEG-D.
    var shots: seq[VibShot] = @[]
    for i in 0 ..< 3:
      shots.add parseVib(synthVib(SynthVib(afterTrigger: 100, preTrigger: 20.5)))
    var w = openSeismicWriter(dir / "m.sgy", SegyOutputOptions())
    for i, sh in shots:
      w.writeSegyTraces(sh, VibWriteOptions(record: int64(7001 + i), groundForce: {}))
    doAssert w.close().len == 0
    var f = openSeismic(dir / "m.sgy", keys = true)
    doAssert f.len == 27
    for i in 0 ..< 27:
      doAssert f.traceKeys(i).record == float64(7001 + i div 9)
    f.close()
    var d = openSeismicWriter(dir / "m.sgd", SegdOutputOptions(sampleIntervalUs: 500,
      numSamples: shots[0].len))
    for i, sh in shots:
      d.writeSegdTraces(sh, VibWriteOptions(record: int64(7001 + i), groundForce: {}))
    doAssert d.close().len == 0
    f = openSeismic(dir / "m.sgd", keys = true)
    doAssert f.len == 27
    for i in 0 ..< 27:
      doAssert f.traceKeys(i).record == float64(7001 + i div 9)
    f.close()

  block folderForms:
    let folder = dir / "out"
    let stem = vibFileStem(s, 42)
    doAssert stem == "0042_20010203T040506Z_vib"
    let p = s.writeSegyTo(folder, 42)
    doAssert p == folder / (stem & ".sgy") and fileExists(p)
    var f = openSeismic(p)
    doAssert f.len == 10 and "controller serial 42" in f.textHeader
    f.close()
    # never overwritten silently
    try:
      discard s.writeSegyTo(folder, 42)
      doAssert false
    except VibWriteError as e:
      doAssert "exists" in e.msg and stem in e.msg
    var other = s
    other.data[vcReference][0] += 1
    let before = readFile(p)
    doAssertRaises(VibWriteError):
      discard other.writeSegyTo(folder, 42)
    doAssert readFile(p) == before
    doAssert other.writeSegyTo(folder, 42, overwrite = true) == p and readFile(p) != before
    let q = s.writeSegdTo(folder, 42)
    doAssert q == folder / (stem & ".sgd") and fileExists(q)
    doAssertRaises(VibWriteError):
      discard s.writeSegdTo(folder, 42)
    doAssert s.writeSegdTo(folder, 42, overwrite = true) == q
    # the trigger time known: the stem carries it to the nanosecond, a different file
    var known = s
    known.setTrigger(trig)
    let kp = known.writeSegyTo(folder, 42)
    doAssert kp == folder / "0042_20010203T040507.789000000Z_vib.sgy" and fileExists(kp)
    # no serial given: no file name
    try:
      discard s.writeSegyTo(folder, -1)
      doAssert false
    except VibWriteError as e:
      doAssert "serial" in e.msg and "does not hold it" in e.msg
    doAssertRaises(VibWriteError):
      discard s.writeSegdTo(folder, -1)
    doAssert not fileExists(folder / "0000_20010203T040506Z_vib.sgy")

  block incompleteShot:
    ## An incomplete shot is written with the frames it has, and says so.
    let d = synthVib(SynthVib(afterTrigger: 100, preTrigger: 20.5, tailBytes: 9))
    let part = parseVib(d, allowIncomplete = true)
    doAssert not part.complete
    part.writeSegy(dir / "n.sgy")
    var f = openSeismic(dir / "n.sgy")
    doAssert f.len == 10 and f.readBack(1)[0] == part.samples(vcReference)
    doAssert "incomplete recording" in f.textHeader and "cut short" in f.textHeader
    f.close()
    part.writeSegd(dir / "n.sgd")

  block polarityAsRecorded:
    ## The samples and the computed ground force go in as recorded: no sign changes.
    var neg = s
    for i in 0 ..< n:
      neg.data[vcMassB][i] = -abs(neg.data[vcMassB][i]) - 1
      neg.data[vcBaseplateB][i] = -abs(neg.data[vcBaseplateB][i]) - 2
      neg.data[vcReference][i] = abs(neg.data[vcReference][i]) + 3
    neg.writeSegy(dir / "pol.sgy")
    var f = openSeismic(dir / "pol.sgy")
    let back = readBack(f, 10)
    for i in 0 ..< n:
      doAssert back[0][i] == float32(neg.data[vcReference][i]) and back[0][i] > 0
      doAssert back[4][i] == float32(neg.data[vcMassB][i]) and back[4][i] < 0
      doAssert back[9][i] < 0
    doAssert "no polarity is changed" in f.textHeader.replace("\n", " ")
    f.close()

  block exclusiveClaim:
    ## A name is claimed in one step: a file already there means `VibWriteError`; the
    ## empty claim of a failed write is removed.
    let folder = dir / "claim"
    createDir(folder)
    let stem = vibFileStem(s, 5)
    writeFile(folder / (stem & ".sgy"), "")
    doAssertRaises(VibWriteError):
      discard s.writeSegyTo(folder, 5)
    doAssert readFile(folder / (stem & ".sgy")) == "" # not touched
    removeFile(folder / (stem & ".sgy"))
    # a write that fails after the claim leaves nothing: SEG-D with a fractional interval
    # is caught before the claim; a year parseSEG cannot take is caught after it
    var odd = s
    odd.sampleIntervalUs = 500.5
    doAssertRaises(VibWriteError):
      discard odd.writeSegdTo(folder, 5)
    doAssert not fileExists(folder / (stem & ".sgd"))
    # a folder that cannot be made is an IOError (its parent is a file)
    writeFile(dir / "plain", "x")
    doAssertRaises(IOError):
      discard s.writeSegyTo(dir / "plain" / "sub", 5)
    doAssertRaises(IOError):
      discard s.writeSegdTo(dir / "plain" / "sub", 5)

  when defined(posix):
    block folderNotWritable:
      ## The file system's refusal (permission denied) comes out as `IOError`. Not when
      ## run as root.
      let ro = dir / "readonly"
      createDir(ro)
      setFilePermissions(ro, {fpUserRead, fpUserExec})
      try:
        if not (try: (writeFile(ro / "probe", "x"); false) except IOError: true):
          removeFile(ro / "probe") # the permission does not bind this user
        else:
          doAssertRaises(IOError):
            discard s.writeSegyTo(ro / "sub", 5)
          doAssertRaises(IOError):
            discard s.writeSegdTo(ro, 5)
          doAssertRaises(IOError):
            discard s.writeSegyTo(ro, 5)
      finally:
        setFilePermissions(ro, {fpUserRead, fpUserWrite, fpUserExec})

  block racingWriters:
    ## Writers after one name at the same time: exactly one gets it.
    type Race = object
      shot: ptr VibShot
      folder: cstring
      won, lost, other: Atomic[int]
    let raceDir = dir / "race"
    var race = Race(folder: cstring(raceDir))
    var shot = s
    race.shot = addr shot
    proc worker(r: ptr Race) {.thread.} =
      {.cast(gcsafe).}:
        try:
          discard r.shot[].writeSegyTo($r.folder, 9, vib = VibWriteOptions(
            channels: {vcReference}, groundForce: {}))
          discard r.won.fetchAdd(1)
        except VibWriteError:
          discard r.lost.fetchAdd(1)
        except CatchableError:
          discard r.other.fetchAdd(1)
    for round in 0 ..< 5:
      removeDir(dir / "race")
      race.won.store(0)
      race.lost.store(0)
      race.other.store(0)
      var threads: array[8, Thread[ptr Race]]
      for i in 0 ..< threads.len:
        createThread(threads[i], worker, addr race)
      joinThreads(threads)
      doAssert race.won.load == 1 and race.lost.load == 7 and race.other.load == 0,
        $(race.won.load, race.lost.load, race.other.load)
      doAssert openSeismic(dir / "race" / (vibFileStem(s, 9) & ".sgy")).len == 1

  block writerRevisions:
    ## `writeSegyTraces` with its default suits a Rev 1 writer; the exact nanoseconds
    ## are for a Rev 2 writer, which `extHeader = true` asks for.
    var known = s
    known.setTrigger(trig)
    var w = openSeismicWriter(dir / "rev1.sgy", rev1)
    w.writeSegyTraces(known)
    doAssert w.close().len == 0
    var f = openSeismic(dir / "rev1.sgy")
    doAssert f.len == 10
    f.close()
    var w2 = openSeismicWriter(dir / "rev2.sgy", SegyOutputOptions())
    w2.writeSegyTraces(known, extHeader = true)
    doAssert w2.close().len == 0
    f = openSeismic(dir / "rev2.sgy", keys = true)
    doAssert f.headerValue(0, "ext1", "nanoseconds") == "789000000"
    f.close()
    var w3 = openSeismicWriter(dir / "rev1b.sgy", rev1)
    doAssertRaises(VibWriteError): # asking for the extension a Rev 1 file has not got
      w3.writeSegyTraces(known, extHeader = true)
    discard w3.close()

  block revisionZero:
    ## Rev 0 knows trace codes 1 to 8 only: the codes still reach the file (the status is
    ## unknown, so parseSEG keeps them), the time of sample 0 is a whole ms.
    let zeroRev = SegyOutputOptions(revision: SegyRevision(major: 0, minor: 0))
    s.writeSegy(dir / "r0.sgy", zeroRev)
    var f = openSeismic(dir / "r0.sgy", keys = true)
    let expected = [21'i16, 257, 258, 19, 18, 261, 262, 263, 264, 20]
    doAssert f.len == 10
    for i in 0 ..< 10:
      doAssert f.traceKeys(i).traceCode == expected[i], $(i, f.traceKeys(i).traceCode)
    doAssert abs(f.traceKeys(0).t0Ms + 20.125) <= 0.5, $f.traceKeys(0).t0Ms
    let back = readBack(f, 10)
    for c in VibChannel:
      doAssert bitsEqual(back[ord(c)], s.samples(c))
    f.close()
    # through a Rev 0 writer of one's own
    var w = openSeismicWriter(dir / "r0b.sgy", zeroRev)
    w.writeSegyTraces(s, VibWriteOptions(channels: {vcReference, vcMassB}, groundForce: {}),
      major = 0)
    doAssert w.close().len == 0
    f = openSeismic(dir / "r0b.sgy", keys = true)
    doAssert f.traceKeys(0).traceCode == 21 and f.traceKeys(1).traceCode == 18
    f.close()
    doAssert toTraceKeys(s, 21, 1, segyMajor = 0).status == tsUnknown
    doAssert toTraceKeys(s, 21, 1, segyMajor = 1).status == tsAuxiliary
    doAssert toTraceKeys(s, 1, 1, segyMajor = 0).status == tsLive

  block cardLoop:
    ## A word longer than a card, in the text or from a number, never makes the card
    ## writer loop; an absurd trigger frame or uncertainty is refused on every axis.
    var long = s
    long.incompleteWhy = "x " & repeat('y', 80)
    long.complete = false
    let cards = textCards(long, VibWriteOptions(timeAxis: vaRecord))
    for c in cards:
      doAssert c.len <= 76, c
    var run = 0 # the 80 y's are all there, over the cards that follow the sentence
    for c in cards:
      if c.strip(chars = {' ', 'y'}).len == 0 or c.endsWith("yyyy"):
        run += c.count('y')
    doAssert run == 80, $run
    for axis in [vaTrigger, vaRecord]:
      for bad in [1e100, Inf, -Inf, -1.0, float64(n) + 1]:
        var h = s
        h.triggerFrame = bad
        refusal(h, ["trigger frame"], vib = VibWriteOptions(timeAxis: axis))
        doAssertRaises(VibWriteError):
          discard textCards(h, VibWriteOptions(timeAxis: axis))
      for bad in [1e100, Inf, -1.0, 1e7]:
        var h = s
        h.triggerSource = tsEstimated
        h.triggerSigmaFrames = bad
        refusal(h, ["uncertainty"], vib = VibWriteOptions(timeAxis: axis))

  block intervalBound:
    ## An interval the SEG-Y field cannot hold is refused in words (it used to overflow
    ## the clock arithmetic of the record axis).
    var big = s
    big.sampleIntervalUs = 1e15
    big.setTrigger(trig, 40.5)
    refusal(big, ["sample interval", "most a SEG-Y interval field holds"],
      vib = VibWriteOptions(timeAxis: vaRecord))
    refusal(big, ["sample interval", "most a SEG-Y interval field holds"], true,
      VibWriteOptions(timeAxis: vaRecord))
    big.sampleIntervalUs = 65536
    refusal(big, ["65536.0 us"], vib = VibWriteOptions(timeAxis: vaRecord))
    big.sampleIntervalUs = 65535
    big.writeSegy(dir / "big.sgy", vib = VibWriteOptions(timeAxis: vaRecord,
      channels: {vcReference}, groundForce: {}))
    doAssert textCards(big, VibWriteOptions()).len > 0

  block recordBound:
    refusal(s, ["record number 2147483648", "SEG-Y"], vib = VibWriteOptions(
      record: 2_147_483_648'i64))
    refusal(s, ["record number 9007199254740993"], vib = VibWriteOptions(
      record: 9_007_199_254_740_993'i64))
    s.writeSegy(dir / "rec.sgy", vib = VibWriteOptions(record: 2_147_483_647,
      channels: {vcReference}, groundForce: {}))
    var f = openSeismic(dir / "rec.sgy", keys = true)
    doAssert f.traceKeys(0).record == 2147483647.0
    f.close()

  block roundedClock:
    ## On the record axis the first frame's time is the trigger minus the frame times the
    ## interval, rounded to the nanosecond (not cut).
    var known = s
    var t = trig
    t.nanosecond = 500_000_000
    known.setTrigger(t, 40.0000019) # 40.0000019 frames x 500 us = 20000000.95 ns
    known.writeSegy(dir / "rnd.sgy", vib = VibWriteOptions(timeAxis: vaRecord,
      groundForce: {}, channels: {vcReference}))
    var f = openSeismic(dir / "rnd.sgy", keys = true)
    doAssert f.headerValue(0, "ext1", "nanoseconds") == "479999999", f.headerValue(0, "ext1", "nanoseconds")
    f.close()

  block zeroWeightMessage:
    var zero = s
    zero.header.massLb = 0
    refusal(zero, ["groundForce = {}"], vib = VibWriteOptions(channels: {vcReference}))
    refusal(zero, ["groundForce = {}"], vib = VibWriteOptions(units: vuPhysical,
      scale: made, channels: {vcReference}))
    zero.writeSegy(dir / "zw.sgy", vib = VibWriteOptions(channels: {vcReference},
      groundForce: {})) # and so it is written

  block traceOrder:
    ## `voForces`: the reference; the primary set's mass, baseplate and ground force; the
    ## other set's the same; torque motor, valve, mass displacement, drive; per-cycle
    ## values. Codes and samples follow their column; the SEG-Y trace number is the
    ## position.
    proc check(vib: VibWriteOptions; codes: seq[int16]; cols: seq[string]) =
      var o = vib
      o.traceOrder = voForces
      let p = dir / "ord.sgy"
      s.writeSegy(p, vib = o)
      var f = openSeismic(p, keys = true)
      doAssert f.len == codes.len, $(f.len, codes.len)
      let back = readBack(f, f.len)
      for i in 0 ..< codes.len:
        doAssert f.traceKeys(i).traceCode == codes[i], $(i, f.traceKeys(i).traceCode)
        doAssert f.traceKeys(i).channel == float64(i + 1)
        # the samples are those of the named column
        let want = case cols[i]
          of "ref": s.samples(vcReference)
          of "mA": s.samples(vcMassA)
          of "bA": s.samples(vcBaseplateA)
          of "mB": s.samples(vcMassB)
          of "bB": s.samples(vcBaseplateB)
          of "tm": s.samples(vcTorqueMotor)
          of "valve": s.samples(vcValve)
          of "stroke": s.samples(vcMassStroke)
          of "drive": s.samples(vcDrive)
          of "c1": s.samples(vvDriveRatio)
          of "c2": s.samples(vvCycle2)
          of "gfA": groundForce(s, vsA)
          else: groundForce(s, vsB)
        doAssert bitsEqual(back[i], want), $(i, cols[i])
      f.close()
    check(VibWriteOptions(), @[21'i16, 18, 19, 20, 258, 257, 261, 262, 263, 264],
      @["ref", "mB", "bB", "gfB", "mA", "bA", "tm", "valve", "stroke", "drive"])
    check(VibWriteOptions(groundForce: {vsA, vsB}, cycleValues: true),
      @[21'i16, 18, 19, 20, 258, 257, 267, 261, 262, 263, 264, 265, 266],
      @["ref", "mB", "bB", "gfB", "mA", "bA", "gfA", "tm", "valve", "stroke", "drive",
        "c1", "c2"])
    check(VibWriteOptions(groundForce: {}), @[21'i16, 18, 19, 258, 257, 261, 262, 263, 264],
      @["ref", "mB", "bB", "mA", "bA", "tm", "valve", "stroke", "drive"])
    check(VibWriteOptions(channels: {vcReference, vcMassB, vcBaseplateB}),
      @[21'i16, 18, 19, 20], @["ref", "mB", "bB", "gfB"])
    check(VibWriteOptions(channels: {vcMassB, vcValve}, groundForce: {}),
      @[18'i16, 262], @["mB", "valve"])
    check(VibWriteOptions(primary: vsA, groundForce: {vsA, vsB}),
      @[21'i16, 18, 19, 20, 260, 259, 267, 261, 262, 263, 264],
      @["ref", "mA", "bA", "gfA", "mB", "bB", "gfB", "tm", "valve", "stroke", "drive"])
    # file order is unchanged and explicit
    s.writeSegy(dir / "ord2.sgy", vib = VibWriteOptions(traceOrder: voFile))
    var f = openSeismic(dir / "ord2.sgy", keys = true)
    doAssert f.traceKeys(3).traceCode == 19 and f.traceKeys(9).traceCode == 20
    f.close()
    # SEG-D: the same traces, grouped by channel type as the writer does; one
    # trace per column whichever the order
    s.writeSegd(dir / "ord.sgd", VibWriteOptions(traceOrder: voForces, cycleValues: true,
      groundForce: {vsA, vsB}))
    f = openSeismic(dir / "ord.sgd", keys = true)
    doAssert f.len == 13
    let back = readBack(f, 13)
    for want in [s.samples(vcReference), s.samples(vcMassB), s.samples(vcBaseplateB),
        groundForce(s, vsB), s.samples(vcMassA), s.samples(vcBaseplateA),
        groundForce(s, vsA), s.samples(vcDrive), s.samples(vvCycle2)]:
      doAssert anyIt(back, bitsEqual(it, want))
    f.close()
    # the text header lists the traces in the written order
    let cards = flat(textCards(s, VibWriteOptions(traceOrder: voForces)).join(" "))
    doAssert "trace 2 reaction-mass acceleration, set B (counts) trace 3 baseplate " &
      "acceleration, set B (counts) trace 4 ground force, estimated, from accelerometer " &
      "set B" in cards, cards

  block unwritable:
    doAssertRaises(CatchableError):
      s.writeSegy(dir / "no" / "such" / "folder" / "x.sgy")

when isMainModule:
  main()
