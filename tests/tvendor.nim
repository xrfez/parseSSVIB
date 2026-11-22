## The shot block (`vendorLayout`): written into SEG-Y and SEG-D files, read back through
## parseSEG with the maps of `vendormaps/` applied. The block's 1280 bytes are built
## again here, offset by offset, from the map's own numbers; every field of a decoded
## block equals the shot and the options; every trace is rebuilt from the counts and its
## table entry; and a file written without the layout has none of it.
##
## Seen to fail: with the `(byteOrder big)` of `record` dropped from the SEG-Y map,
## `mapsAgree` fails (the little-endian decode of `segy` was not run with it alone); with
## the file's header put one byte early, `blockGolden` fails; with the external header
## passed to no trace, `segd` finds no block; with card 37 left out of the text header,
## `segy` finds no block; with one field line of the SEG-D map moved, the maps do not load
## clean (`registry`); with the table's means written as 0, `blockGolden` fails; with
## `firstFrame` written as 0, `segy` fails for the external converter; with the incomplete
## words not cut, `incomplete` fails; with the Rev 0 refusal left out, `refusals` fails;
## with `writeSegdTo` not passing the serial, `serials` fails; with `datFileNumber` not
## written, `blockGolden` fails. Not mutated: the rebuilding of traces from the table
## (`checkRebuilt`) with a wrong factor alone, the blank padding of `incompleteWhy`, and the
## `checkBlockFields` bounds other than the 32-bit sentinel, the trigger year and the
## trigger nanosecond.

import std/[math, os, sequtils, strutils, tables, times]
import parseSEG
import parseSSVIB
import vibsynth

const
  MapDir = currentSourcePath().parentDir.parentDir / "vendormaps"
  made = VibScale(accMvPerCount: 0.5, torquePctPerCount: 0.125, lvdtFactor: 8000.0,
    drivePerCount: 0.0625) ## made-up constants, exact in binary
  trig = VibTime(year: 2001, month: 2, day: 3, hour: 4, minute: 5, second: 6,
    nanosecond: 789_000_000)

proc registry(): VendorRegistry =
  var log: DiagLog
  result.loadVendorMaps([MapDir / "parseSSVIB-segy-1.nif", MapDir / "parseSSVIB-segd-1.nif"],
    log)
  doAssert log.len == 0, $log

proc byName(b: VendorBlock): Table[string, VendorValue] =
  for f in b.fields:
    result[f.name] = f.value

proc stanzaBlocks(f: SeismicFile): seq[seq[byte]] =
  ## The bytes of every binary stanza of the extended textual header.
  let ext = f.index.segy.extended
  for st in ext.stanzas:
    if st.isBinary and not st.isUserData:
      result.add ext.data[st.dataStart ..< st.dataStart + st.byteCount]

proc blocksOf(f: SeismicFile; reg: VendorRegistry): seq[VendorBlock] =
  var log: DiagLog
  if f.kind == skSegy:
    result = reg.decodeVendorAreas(f.index.segy, log)
  else:
    for rec in f.index.segdRecords:
      result.add reg.decodeVendorAreas(rec, log)
  doAssert log.count(sevWarning) == 0 and log.count(sevError) == 0, $log

proc rawBlocks(f: SeismicFile): seq[seq[byte]] =
  if f.kind == skSegy:
    result = stanzaBlocks(f)
  else:
    for rec in f.index.segdRecords:
      result.add rec.external

proc readBack(f: SeismicFile; n: int): seq[seq[float32]] =
  var log: DiagLog
  let x = f.readTraces(0 ..< n, log)
  doAssert log.len == 0
  for i in 0 ..< n:
    result.add newSeq[float32](x.shape[1])
    for j in 0 ..< x.shape[1]:
      result[i][j] = x[i, j]

proc near(a, b: float64): bool =
  abs(a - b) <= 1e-9 * max(1.0, abs(b))

proc unixOf(year: int; month: Month; day, hour, minute, second: int): int64 =
  dateTime(year, month, day, hour, minute, second, zone = utc()).toTime.toUnix

proc intCheck(v: Table[string, VendorValue]; name: string; want: SomeInteger) =
  doAssert name in v and v[name].intVal == int64(want), name & " " & $want

proc recordOf(s: VibShot; o: VibWriteOptions): int64 =
  if o.record >= 0: o.record elif s.nameNumber >= 0: s.nameNumber else: 1

proc firstOf(o: VibWriteOptions): int =
  if o.externalConverter: o.converterCut else: 0

proc cutWords(why: string): string =
  if why.len <= 76: why
  else:
    let at = why.rfind(' ', 0, 76)
    if at > 0: why[0 ..< at] else: why[0 ..< 76]

proc checkFields(v: Table[string, VendorValue]; s: VibShot; o: VibWriteOptions;
    traces: int) =
  ## Every field of the block but the table's entries, by name, against the shot and the
  ## options.
  proc intF(name: string; want: SomeInteger) =
    doAssert name in v and v[name].intVal == int64(want), name & " " & $want & " " &
      (if name in v: $v[name].intVal else: "missing")
  proc optF(name: string; want: int64) =
    ## A field with the sentinel 0xFFFFFFFF: absent when none.
    if want < 0: doAssert name notin v, name
    else: intF name, want
  proc floatF(name: string; want: float64) =
    doAssert name in v, name & " missing"
    if want.isNaN: doAssert v[name].floatVal.isNaN, name
    else: doAssert near(v[name].floatVal, want), name & " " & $want & " " & $v[name].floatVal
  proc flagsF(name: string; want: seq[string]) =
    doAssert v[name].flags == want, name & " " & $v[name].flags
  let first = firstOf(o)
  let hasTrigger = not s.triggerFrame.isNaN
  let atTrigger = o.timeAxis == vaTrigger and hasTrigger
  doAssert v["magic"].text == "SSVIBSHT"
  intF "layoutVersion", 1
  intF "blockBytes", 1280
  intF "record", recordOf(s, o)
  optF "nameNumber", s.nameNumber
  optF "controllerSerial", o.controllerSerial
  optF "datFileNumber", o.datFileNumber
  intF "complete", ord(s.complete)
  doAssert v["complete"].label == (if s.complete: "complete" else: "incomplete")
  intF "endsInSweep", ord(s.endsInSweep)
  intF "traces", traces
  intF "groundForcePolarity", 0
  doAssert v["groundForcePolarity"].label == "as recorded"
  intF "frames", s.len
  intF "firstFrame", first
  intF "samples", s.len - first
  intF "tailBytes", s.tailBytes
  floatF "sampleIntervalUs", s.sampleIntervalUs
  floatF "t0Ms", (float64(first) - (if atTrigger: s.triggerFrame else: 0.0)) *
    s.sampleIntervalUs / 1000
  # the clock of t = 0, from the standard library's calendar
  let startUnix = unixOf(s.start.year, Month(s.start.month), s.start.day,
    s.start.hour, s.start.minute, s.start.second)
  var seconds = startUnix
  var nanos = 0'i64
  if s.triggerKnown and hasTrigger:
    let t = s.trigger
    seconds = unixOf(t.year, Month(t.month), t.day, t.hour, t.minute, t.second)
    nanos = int64(t.nanosecond)
    if not atTrigger:
      nanos -= int64(round(s.triggerFrame * s.sampleIntervalUs * 1000))
      seconds += floorDiv(nanos, 1_000_000_000'i64)
      nanos = floorMod(nanos, 1_000_000_000'i64)
  intF "timeZeroSeconds", seconds
  intF "timeZeroNanosecond", nanos
  intF "timeAxis", ord(o.timeAxis)
  doAssert v["timeAxis"].label == (if o.timeAxis == vaTrigger: "trigger" else: "first frame")
  intF "timeZero", (if atTrigger: 0 else: 1)
  intF "triggerSource", ord(s.triggerSource)
  intF "triggerKnown", ord(s.triggerKnown)
  floatF "triggerFrame", s.triggerFrame
  floatF "triggerSigmaFrames", s.triggerSigmaFrames
  for name in ["triggerYear", "triggerMonth", "triggerDay", "triggerHour", "triggerMinute",
      "triggerSecond", "triggerNanosecond"]:
    if not s.triggerKnown: doAssert name notin v, name # the (when) group is absent
  if s.triggerKnown:
    intF "triggerYear", s.trigger.year
    intF "triggerMonth", s.trigger.month
    intF "triggerDay", s.trigger.day
    intF "triggerHour", s.trigger.hour
    intF "triggerMinute", s.trigger.minute
    intF "triggerSecond", s.trigger.second
    intF "triggerNanosecond", s.trigger.nanosecond
  intF "sweepValid", ord(s.sweep.valid)
  intF "sweepCrossings", s.sweep.crossings
  floatF "sweepTriggerFrame", s.sweep.triggerFrame
  floatF "sweepTriggerSigmaFrames", s.sweep.triggerSigmaFrames
  floatF "sweepStartHz", s.sweep.startHz
  floatF "sweepRateHzPerS", s.sweep.rateHzPerS
  floatF "sweepResidualCycles", s.sweep.residualCycles
  floatF "sweepRmsCycles", s.sweep.rmsCycles
  intF "units", ord(o.units)
  intF "force", ord(o.force)
  intF "removeMean", ord(o.removeMean)
  intF "cycleValues", ord(o.cycleValues)
  var sets: seq[string] = @[]
  if vsA in o.groundForce: sets.add "setA"
  if vsB in o.groundForce: sets.add "setB"
  flagsF "groundForce", sets
  intF "primary", ord(o.primary)
  doAssert v["primary"].label == $o.primary
  intF "traceOrder", ord(o.traceOrder)
  intF "externalConverter", ord(o.externalConverter)
  intF "segdReference", ord(o.segdReference)
  let names = ["reference", "baseplateA", "massA", "baseplateB", "massB", "torqueMotor",
    "valve", "massStroke", "drive"]
  var chans: seq[string] = @[]
  for c in VibChannel:
    if c in o.channels: chans.add names[ord(c)]
  flagsF "channels", chans
  floatF "accMvPerCount", o.scale.accMvPerCount
  floatF "torquePctPerCount", o.scale.torquePctPerCount
  floatF "lvdtFactor", o.scale.lvdtFactor
  floatF "drivePerCount", o.scale.drivePerCount
  # the file's header, decoded in place
  doAssert v["vibMagic"].text == "VIB"
  intF "channelsPerFrame", s.header.channelsPerFrame
  floatF "valveCal", s.header.valveCal
  floatF "massCal", s.header.massCal
  floatF "unknown12", s.header.unknown12
  floatF "unknown16", s.header.unknown16
  floatF "holdDownLb", s.header.holdDownLb
  floatF "sensitivity1", s.header.sensitivity1
  floatF "sensitivity2", s.header.sensitivity2
  floatF "baseplateLb", s.header.baseplateLb
  floatF "massLb", s.header.massLb
  intF "startSecond", s.start.second
  intF "startMinute", s.start.minute
  intF "startHour", s.start.hour
  intF "startDay", s.start.day
  intF "startMonth", s.start.month
  intF "startYear", s.start.year
  doAssert v["incompleteWhy"].text == cutWords(s.incompleteWhy)
  doAssert ("traceChannel[" & $traces & "]") notin v # the repeat count is `traces`

proc checkRebuilt(v: Table[string, VendorValue]; f: SeismicFile; s: VibShot; traces: int) =
  ## Every written trace, rebuilt in float64 from the shot's counts and its table
  ## entry, equals the file's samples bit for bit.
  let first = int(v["firstFrame"].intVal)
  let n = int(v["samples"].intVal)
  let back = readBack(f, traces)
  var seen = 0
  for i in 0 ..< traces:
    let k = "[" & $i & "]"
    # the file's trace that this entry describes: the entry's channel is its number
    var at = -1
    for j in 0 ..< traces:
      if f.traceKeys(j).channel == float64(v["traceChannel" & k].intVal): at = j
    doAssert at >= 0 and v["traceChannel" & k].intVal == i + 1
    if f.kind == skSegy:
      doAssert at == i and f.traceKeys(at).traceCode == v["traceCode" & k].intVal
    let src = int(v["traceSource" & k].intVal)
    let (fa, ma) = (v["traceFactor" & k].floatVal, v["traceMean" & k].floatVal)
    let (fb, mb) = (v["traceFactor2" & k].floatVal, v["traceMean2" & k].floatVal)
    for j in 0 ..< n:
      var want: float32
      case src
      of 0 .. 8: want = float32(fa * (float64(s.data[VibChannel(src)][first + j]) - ma))
      of 9, 10: want = float32(fa * (float64(s.cycle[VibCycleValue(src - 9)][first + j]) - ma))
      else:
        let (bp, rm) = if src == 11: (vcBaseplateA, vcMassA) else: (vcBaseplateB, vcMassB)
        want = float32(fa * (float64(s.data[bp][first + j]) - ma) +
          fb * (float64(s.data[rm][first + j]) - mb))
      doAssert cast[uint32](back[at][j]) == cast[uint32](want), "trace " & $i & " frame " & $j
    if src <= 10: doAssert fb.isNaN and mb.isNaN
    inc seen
  doAssert seen == traces

type Case = tuple[name: string; shot: VibShot; opts: VibWriteOptions]

proc caseList(base: VibShot; syn: SynthVib): seq[Case] =
  ## The option sets of the file tests, each with the shot it is written from.
  result = @[]
  var named = base
  named.nameNumber = 5
  result.add ("defaults", named, VibWriteOptions())
  result.add ("physical", base, VibWriteOptions(units: vuPhysical, scale: made,
    removeMean: true, cycleValues: true, groundForce: {vsA, vsB}, primary: vsA,
    traceOrder: voForces, record: 12, controllerSerial: 9, datFileNumber: 3))
  result.add ("record axis", base, VibWriteOptions(timeAxis: vaRecord))
  let noFit = parseVib(synthVib(syn), findTrigger = false)
  result.add ("no trigger", noFit, VibWriteOptions())
  var given = noFit
  given.setTrigger(trig, 100.5)
  result.add ("given trigger", given, VibWriteOptions(timeAxis: vaRecord))
  result.add ("subset", base, VibWriteOptions(channels: {vcReference, vcMassB},
    groundForce: {}))
  result.add ("converter", base, VibWriteOptions(externalConverter: true, scale: made,
    converterCut: 7))

proc main*() =
  let dir = getTempDir() / ("ssvib-tvendor-" & $getCurrentProcessId())
  createDir(dir)
  defer: removeDir(dir)
  let reg = registry()
  let syn = SynthVib()
  var s = parseVib(synthVib(syn))
  doAssert s.sweep.valid and s.triggerSource == tsEstimated
  s.setTrigger(trig) # the estimate stays, the trigger time is the caller's
  let cases = caseList(s, syn)

  block mapsAgree:
    ## The two maps hold the same field lines, and both load and check clean.
    var lines: array[2, seq[string]]
    for i, name in ["parseSSVIB-segy-1.nif", "parseSSVIB-segd-1.nif"]:
      let text = readFile(MapDir / name)
      var inTarget = false
      for line in text.splitLines:
        if line.strip.startsWith("(target"): inTarget = true
        elif inTarget: lines[i].add line
      let m = loadVendorMap(text, name)
      doAssert checkVendorMap(m).len == 0, $checkVendorMap(m)
      doAssert m.name == name.changeFileExt("")
      var widest = 0
      for line in lines[i]:
        let at = line.find("(at ")
        if "(field" in line and at >= 0:
          let start = parseInt(line[at + 4 ..< line.find(')', at)])
          var width = 0
          var multi = false
          for (enc, w) in [("u8", 1), ("i8", 1), ("u16", 2), ("i16", 2), ("u32", 4),
              ("i64", 8), ("f32", 4), ("f64", 8)]:
            if ("(enc " & enc & ")") in line:
              width = w
              multi = w > 1
          let lenAt = line.find("(len ")
          if lenAt >= 0: width = parseInt(line[lenAt + 5 ..< line.find(')', lenAt)])
          var inTable = false
          for n in ["traceChannel", "traceSource", "traceCode", "traceSegdType", "traceUnit",
              "traceFactor", "traceMean"]:
            if ("(field " & n & " ") in line: inTable = true
          if inTable:
            # an entry of the table: at most 48 bytes from its own start
            doAssert start - 1 + width <= 48, line
            if multi: doAssert "(byteOrder big)" in line, line
          else:
            widest = max(widest, start - 1 + width)
            if multi:
              # the file's 47 header bytes (257-303) are little-endian, the rest big
              if start in 257 .. 303: doAssert "(byteOrder little)" in line, line
              else: doAssert "(byteOrder big)" in line, line
      doAssert widest <= 1280 and widest > 1100, $widest
      doAssert "(stride 48)" in text and "(at 321)" in text and "(count (ref traces))" in text
      doAssert 320 + 16 * 48 <= 1280
    doAssert lines[0] == lines[1] and lines[0].len > 80
    doAssert "(kind stanza)" in readFile(MapDir / "parseSSVIB-segy-1.nif")
    doAssert "(kind externalHeader)" in readFile(MapDir / "parseSSVIB-segd-1.nif")

  block blockGolden:
    ## The block built here from the map's offsets, byte for byte.
    let o = VibWriteOptions(units: vuPhysical, scale: made, removeMean: true,
      cycleValues: true, groundForce: {vsA, vsB}, record: 9, controllerSerial: 42,
      datFileNumber: 7)
    var e = newSeq[byte](1280)
    proc be(at, width: int; v: uint64) =
      ## `at` is the map's 1-based offset.
      for i in 0 ..< width:
        e[at - 1 + i] = byte((v shr (8 * (width - 1 - i))) and 0xFF)
    proc fl(at: int; v: float64) = be(at, 8, cast[uint64](v))
    for i, c in "SSVIBSHT": e[i] = byte(c)
    be 9, 2, 1
    be 11, 2, 1280
    be 13, 4, 9
    be 17, 4, 0xFFFFFFFF'u64
    be 21, 4, 42
    be 25, 4, 7
    be 29, 1, 1
    be 30, 1, 0
    be 31, 1, 13
    be 32, 1, 0
    be 33, 4, uint64(s.len)
    be 37, 4, 0
    be 41, 4, uint64(s.len)
    be 45, 4, 0
    fl 49, 500.0
    fl 57, -s.triggerFrame * 500.0 / 1000.0
    be 65, 8, uint64(unixOf(2001, mFeb, 3, 4, 5, 6))
    be 73, 4, 789_000_000
    be 77, 1, 0
    be 78, 1, 0
    be 79, 1, 1
    be 80, 1, 1
    fl 81, s.triggerFrame
    fl 89, s.triggerSigmaFrames
    be 97, 2, 2001
    be 99, 1, 2
    be 100, 1, 3
    be 101, 1, 4
    be 102, 1, 5
    be 103, 1, 6
    be 105, 4, 789_000_000
    be 113, 1, 1
    be 117, 4, uint64(s.sweep.crossings)
    fl 121, s.sweep.triggerFrame
    fl 129, s.sweep.triggerSigmaFrames
    fl 137, s.sweep.startHz
    fl 145, s.sweep.rateHzPerS
    fl 153, s.sweep.residualCycles
    fl 161, s.sweep.rmsCycles
    be 169, 1, 1 # physical
    be 170, 1, 1 # force
    be 171, 1, 1 # remove mean
    be 172, 1, 1 # cycle values
    be 173, 1, 3 # both ground forces
    be 174, 1, 1 # primary B
    be 175, 1, 0 # file order
    be 176, 1, 0
    be 177, 1, 150
    be 179, 2, 511
    fl 181, 0.5
    fl 189, 0.125
    fl 197, 8000.0
    fl 205, 0.0625
    let file = synthVib(syn)
    for i in 0 ..< 47: e[256 + i] = file[i]
    # the table: source column, code, SEG-D type, unit, factor and mean (formulas of
    # `units.nim` written out)
    func meanC(c: VibChannel): float64 =
      var sum = 0.0
      for x in s.data[c]: sum += float64(x)
      sum / float64(s.len)
    func meanV(c: VibCycleValue): float64 =
      var sum = 0.0
      for x in s.cycle[c]: sum += float64(x)
      sum / float64(s.len)
    let accPer = 0.5 / 20.0 # accelerometer constant over the sensitivity
    let wb = 6000.0 * accPer
    let wm = 4000.0 * accPer
    var entries: seq[tuple[source, code, segd, unit: int; f, m, f2, m2: float64]] = @[]
    entries.add (0, 21, 150, 2, 40000.0 / 32767.0, meanC(vcReference), NaN, NaN)
    entries.add (1, 257, 151, 2, wb, meanC(vcBaseplateA), NaN, NaN)
    entries.add (2, 258, 151, 2, wm, meanC(vcMassA), NaN, NaN)
    entries.add (3, 19, 149, 2, wb, meanC(vcBaseplateB), NaN, NaN)
    entries.add (4, 18, 153, 2, wm, meanC(vcMassB), NaN, NaN)
    entries.add (5, 261, 151, 4, 0.125, meanC(vcTorqueMotor), NaN, NaN)
    entries.add (6, 262, 155, 4, 8000.0 / 3200.0, meanC(vcValve), NaN, NaN)
    entries.add (7, 263, 151, 4, 8000.0 / 2560.0, meanC(vcMassStroke), NaN, NaN)
    entries.add (8, 264, 154, 6, 0.0625, meanC(vcDrive), NaN, NaN)
    entries.add (9, 265, 151, 5, 1.0, meanV(vvDriveRatio), NaN, NaN)
    entries.add (10, 266, 151, 5, 1.0, meanV(vvCycle2), NaN, NaN)
    entries.add (12, 20, 147, 2, wb, meanC(vcBaseplateB), wm, meanC(vcMassB))
    entries.add (11, 267, 151, 2, wb, meanC(vcBaseplateA), wm, meanC(vcMassA))
    for i, t in entries:
      let at = 321 + 48 * i
      be at, 1, uint64(i + 1)
      be at + 1, 1, uint64(t.source)
      be at + 2, 2, uint64(t.code)
      be at + 4, 1, uint64(t.segd)
      be at + 5, 1, uint64(t.unit)
      fl at + 8, t.f
      fl at + 16, t.m
      fl at + 24, t.f2
      fl at + 32, t.m2
    for i in 0 ..< 76: e[1088 + i] = 0x20 # no words: blanks
    doAssert e[0 ..< 12] == @[byte 0x53, 0x53, 0x56, 0x49, 0x42, 0x53, 0x48, 0x54, 0, 1, 5, 0]
    let b = shotBlock(s, o)
    doAssert b.len == VibShotBlockBytes and VibShotBlockBytes == 1280
    doAssert VibShotMagic == "SSVIBSHT"
    doAssert b == e, "first difference at byte " & $(block:
      var d = 0
      while d < 1280 and b[d] == e[d]: inc d
      d + 1)
    doAssert shotBlock(s, o) == b # deterministic
    var o2 = o
    o2.removeMean = false
    doAssert shotBlock(s, o2) != b
    doAssert b[256 ..< 303] == @(s.header.raw)

  block segy:
    ## Rev 2.1 big- and little-endian, Rev 2.0 and Rev 1.0, every option set.
    for (major, minor, order) in [(2, 1, boBig), (2, 1, boLittle), (2, 0, boBig),
        (1, 0, boBig)]:
      for (name, sh, o) in cases:
        if not (o.externalConverter and major != 1):
          let p = dir / "a.sgy"
          sh.writeSegy(p, SegyOutputOptions(revision: SegyRevision(major: uint8(major),
            minor: uint8(minor)), byteOrder: order), o)
          var f = openSeismic(p, keys = true)
          doAssert not f.log.isFatal, $f.log
          let ctx = name & " Rev " & $major & "." & $minor & " " & $order
          let blocks = f.blocksOf(reg)
          doAssert blocks.len == 1 and blocks[0].name == "parseSSVIBShot" and
            blocks[0].mapName == "parseSSVIB-segy-1", ctx & " " & $blocks.len
          let v = byName(blocks[0])
          let traces = int(v["traces"].intVal)
          checkFields(v, sh, o, traces)
          checkRebuilt(v, f, sh, traces)
          let raw = f.rawBlocks
          doAssert raw.len == 1 and raw[0] == shotBlock(sh, o), ctx
          doAssert raw[0][256 ..< 303] == @(sh.header.raw), ctx
          doAssert f.len == traces and f.traceKeys(0).record == float64(recordOf(sh, o)), ctx
          doAssert VibShotCardText in f.textHeader.replace("C37 ", "").replace("C 37 ", ""),
            ctx & " " & f.textHeader
          f.close()

  block segd:
    ## The same block as the record's external header, and as the SEG-Y stanza.
    for (name, sh, o) in cases:
      if not o.externalConverter:
        let p = dir / "a.sgd"
        sh.writeSegd(p, o)
        var f = openSeismic(p, keys = true)
        doAssert f.kind == skSegd and not f.log.isFatal, $f.log
        let blocks = f.blocksOf(reg)
        doAssert blocks.len == 1 and blocks[0].name == "parseSSVIBShot" and
          blocks[0].mapName == "parseSSVIB-segd-1", name & " " & $blocks.len
        let v = byName(blocks[0])
        let traces = int(v["traces"].intVal)
        checkFields(v, sh, o, traces)
        checkRebuilt(v, f, sh, traces)
        doAssert f.index.segdRecords[0].externalHeaderBlocks == 40
        doAssert f.rawBlocks[0] == shotBlock(sh, o), name
        f.close()
        sh.writeSegy(dir / "same.sgy", SegyOutputOptions(), o)
        var g = openSeismic(dir / "same.sgy", keys = true)
        var h = openSeismic(p, keys = true)
        doAssert g.rawBlocks[0] == h.rawBlocks[0], name
        g.close()
        h.close()

  block incomplete:
    ## A recording cut short and a stopped one; a reason longer than 76 characters.
    let part = parseVib(synthVib(SynthVib(tailBytes: 11)), allowIncomplete = true)
    doAssert not part.complete
    var stopped = parseVib(synthVib(SynthVib(stopAt: 3000)))
    doAssert stopped.endsInSweep
    for (sh, why) in [(part, ""), (stopped, "")]:
      for segd in [false, true]:
        let p = dir / (if segd: "i.sgd" else: "i.sgy")
        if segd: sh.writeSegd(p) else: sh.writeSegy(p)
        var f = openSeismic(p, keys = true)
        let bl = f.blocksOf(reg)
        doAssert bl.len == 1
        let v = byName(bl[0])
        checkFields(v, sh, VibWriteOptions(), int(v["traces"].intVal))
        if not sh.complete:
          doAssert v["complete"].label == "incomplete" and v["tailBytes"].intVal == 11
          doAssert v["incompleteWhy"].text.len > 0 and
            sh.incompleteWhy.startsWith(v["incompleteWhy"].text)
        else:
          doAssert v["endsInSweep"].intVal == 1 and
            v["endsInSweep"].label == "yes: a stopped recording"
        f.close()
    var long = part
    long.incompleteWhy = "the file holds 50 of the 226 blocks its header announces: the " &
      "recording stopped or the copy was cut short"
    let b = shotBlock(long, VibWriteOptions())
    let text = cast[string](b[1088 ..< 1164]).strip(leading = false)
    doAssert text == "the file holds 50 of the 226 blocks its header announces: the recording",
      text
    long.incompleteWhy = "x".repeat(200) # no space: cut at 76
    doAssert cast[string](shotBlock(long, VibWriteOptions())[1088 ..< 1164]) == "x".repeat(76)
    long.incompleteWhy = ""
    doAssert shotBlock(long, VibWriteOptions())[1088 ..< 1164] == newSeq[byte](76).mapIt(
      byte(0x20))

  block manyShots:
    ## One block per shot, in order, each with the record of its traces.
    var shots: seq[VibShot] = @[]
    var optsOf: seq[VibWriteOptions] = @[]
    for i in 0 ..< 3:
      var sh = s
      sh.nameNumber = int64(100 + i)
      shots.add sh
      optsOf.add VibWriteOptions(record: int64(i + 1), controllerSerial: int64(10 + i),
        channels: {vcReference, vcMassB}, groundForce: {})
    var w = openSeismicWriter(dir / "m.sgy", SegyOutputOptions(
      text: withVibShotCard(textCards(shots[0], optsOf[0]))))
    for i in 0 ..< 3:
      w.addShotBlock(shots[i], optsOf[i])
    for i in 0 ..< 3:
      w.writeSegyTraces(shots[i], optsOf[i])
    doAssert w.close().len == 0
    var f = openSeismic(dir / "m.sgy", keys = true)
    var bl = f.blocksOf(reg)
    doAssert bl.len == 3 and f.len == 6
    for i in 0 ..< 3:
      let v = byName(bl[i])
      intCheck(v, "record", i + 1)
      intCheck(v, "controllerSerial", 10 + i)
      intCheck(v, "nameNumber", 100 + i)
      for c in 0 ..< 2:
        doAssert f.traceKeys(2 * i + c).record == float64(i + 1)
      doAssert f.rawBlocks[i] == shotBlock(shots[i], optsOf[i])
    f.close()
    var d = openSeismicWriter(dir / "m.sgd", SegdOutputOptions(sampleIntervalUs: 500,
      numSamples: s.len))
    for i in 0 ..< 3:
      d.writeSegdTraces(shots[i], optsOf[i])
    doAssert d.close().len == 0
    f = openSeismic(dir / "m.sgd", keys = true)
    bl = f.blocksOf(reg)
    doAssert bl.len == 3 and f.len == 6
    for i in 0 ..< 3:
      let v = byName(bl[i])
      intCheck(v, "record", i + 1)
      intCheck(v, "controllerSerial", 10 + i)
      doAssert f.rawBlocks[i] == shotBlock(shots[i], optsOf[i])
    f.close()

  block plain:
    ## `vendorLayout = false`: no block, no card, no diagnostic from the maps, and the
    ## same traces and headers as the file with the layout.
    for (name, sh, o) in cases:
      if not o.externalConverter:
        var q = o
        q.vendorLayout = false
        sh.writeSegy(dir / "p.sgy", vib = q)
        sh.writeSegy(dir / "v.sgy", vib = o)
        var p = openSeismic(dir / "p.sgy", keys = true)
        var v = openSeismic(dir / "v.sgy", keys = true)
        doAssert p.blocksOf(reg).len == 0 and p.rawBlocks.len == 0, name
        doAssert VibShotCardText notin p.textHeader and "parseSSVIB" in p.textHeader
        doAssert v.len == p.len
        doAssert p.readBack(p.len) == v.readBack(v.len), name
        for i in 0 ..< p.len:
          doAssert $p.traceKeys(i) == $v.traceKeys(i), name # NaN fields: as text
          doAssert p.traceHeaders(i).len == v.traceHeaders(i).len, name
        let a = readFile(dir / "p.sgy")
        let b = readFile(dir / "v.sgy")
        doAssert b.len > a.len # the stanza
        let tail = p.len * (240 + 4 * s.len)
        doAssert a[a.len - tail ..< a.len] == b[b.len - tail ..< b.len], name
        p.close()
        v.close()
        sh.writeSegd(dir / "p.sgd", q)
        sh.writeSegd(dir / "v.sgd", o)
        p = openSeismic(dir / "p.sgd", keys = true)
        v = openSeismic(dir / "v.sgd", keys = true)
        doAssert p.blocksOf(reg).len == 0 and p.index.segdRecords[0].externalHeaderBlocks == 0
        doAssert p.readBack(p.len) == v.readBack(v.len), name
        for i in 0 ..< p.len:
          doAssert $p.traceKeys(i) == $v.traceKeys(i), name
        p.close()
        v.close()

  block refusals:
    ## Each refusal in words; the same shot is then written without the layout.
    proc refused(sh: VibShot; o: VibWriteOptions; words: openArray[string];
        segd = true; segy = true) =
      for isSegd in [false, true]:
        if (isSegd and segd) or (not isSegd and segy):
          let p = dir / "limit.out"
          try:
            if isSegd: sh.writeSegd(p, o) else: sh.writeSegy(p, vib = o)
            doAssert false, "was written: " & $words
          except VibWriteError as e:
            for w in words:
              doAssert w in e.msg, w & " not in " & e.msg
          doAssert not fileExists(p)
    proc plainOk(sh: VibShot; o: VibWriteOptions) =
      var q = o
      q.vendorLayout = false
      sh.writeSegy(dir / "ok.sgy", vib = q)
      sh.writeSegd(dir / "ok.sgd", q)
    # a negative .dat number is refused with or without the layout
    refused(s, VibWriteOptions(datFileNumber: -2), ["-2", "negative"])
    refused(s, VibWriteOptions(datFileNumber: -2, vendorLayout: false), ["-2"])
    doAssertRaises(VibWriteError):
      discard shotBlock(s, VibWriteOptions(datFileNumber: -2))
    # Rev 0 has no extended textual header
    let rev0 = SegyOutputOptions(revision: SegyRevision(major: 0, minor: 0))
    try:
      s.writeSegy(dir / "r0.sgy", rev0)
      doAssert false, "Rev 0 was written with the layout"
    except VibWriteError as e:
      doAssert "Rev 1 or later" in e.msg and "vendorLayout" in e.msg, e.msg
    doAssert not fileExists(dir / "r0.sgy")
    s.writeSegy(dir / "r0.sgy", rev0, VibWriteOptions(vendorLayout: false))
    # the block's "none" cannot be given as a number
    for (what, o) in [("controller serial", VibWriteOptions(controllerSerial: 0xFFFFFFFF'i64)),
        ("paired .dat file number", VibWriteOptions(datFileNumber: 0xFFFFFFFF'i64))]:
      refused(s, o, [what, "vendorLayout"])
      plainOk(s, o)
      doAssertRaises(VibWriteError):
        discard shotBlock(s, o)
    var named = s
    named.nameNumber = 0xFFFFFFFF'i64
    refused(named, VibWriteOptions(record: 1), ["name number", "vendorLayout"])
    plainOk(named, VibWriteOptions(record: 1))
    # a known trigger time the block's bytes cannot hold
    var odd = s
    odd.trigger.year = 70000
    refused(odd, VibWriteOptions(), ["trigger time", "vendorLayout"])
    odd = s
    odd.trigger.nanosecond = 1_000_000_000
    refused(odd, VibWriteOptions(), ["trigger time", "vendorLayout"])
    # a stanza after the first trace, and on a SEG-D writer
    var w = openSeismicWriter(dir / "late.sgy", SegyOutputOptions())
    w.writeSegyTraces(s)
    doAssertRaises(VibWriteError):
      w.addShotBlock(s)
    discard w.close()
    var d = openSeismicWriter(dir / "d.sgd", SegdOutputOptions(sampleIntervalUs: 500,
      numSamples: s.len))
    doAssertRaises(VibWriteError):
      d.addShotBlock(s)
    doAssertRaises(ValueError): # nothing was written
      discard d.close()

  block serials:
    ## `writeSegyTo` and `writeSegdTo` put their serial in the block.
    let a = s.writeSegyTo(dir / "to", 77)
    let b = s.writeSegdTo(dir / "to", 77)
    for p in [a, b]:
      var f = openSeismic(p, keys = true)
      let bl = f.blocksOf(reg)
      doAssert bl.len == 1
      intCheck(byName(bl[0]), "controllerSerial", 77)
      f.close()

when isMainModule:
  main()
