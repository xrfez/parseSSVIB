## The decoder against synthetic files: every field round-trips, the refusals say what
## is wrong, and a copy cut short is told from a corrupt file.
##
## Seen to fail: with the 16-bit counts masked to 15 bits in `decodeInto`, `roundTrip`
## fails; with the hold-down weight read one byte late, `header` fails; with the month
## limit at 13 or the second's at 61, `badDates` fails; with the kind check taken out of
## `fillInfo`, `refusals` fails; with the tail check taken out, `partialFrame` fails;
## with the `frames == 0` refusal taken out, `noSamples` fails; with the size check taken
## out, `sizeLimit` fails; with the interval check loosened, `interval` fails; with the
## shot's `triggerKnown` not reset in `decodeInto`, `reuse` fails; with `nameNumberOf`
## taking any extension, `names` fails.

import std/[math, os, strutils]
import parseSSVIB/[decode, types]
import vibsynth

proc bits(x: float32): uint32 =
  cast[uint32](x)

let none: seq[byte] = @[] ## an empty file

proc refused(data: openArray[byte]; words: openArray[string]; allow = false): string =
  ## The message of the `VibFormatError` `parseVib` raises for `data`; each of
  ## `words` is in it.
  try:
    discard parseVib(data, allow)
    doAssert false, "was not refused (wanted: " & $words & ")"
  except VibFormatError as e:
    result = e.msg
    for w in words:
      doAssert w in e.msg, "'" & w & "' not in: " & e.msg

proc incomplete(data: openArray[byte]; words: openArray[string]; allow = false) =
  ## The same, and the error is a `VibIncompleteError`.
  try:
    discard parseVib(data, allow)
    doAssert false, "was not refused (wanted: " & $words & ")"
  except VibIncompleteError as e:
    for w in words:
      doAssert w in e.msg, "'" & w & "' not in: " & e.msg
  except VibFormatError as e:
    doAssert false, "a VibFormatError that is not incomplete: " & e.msg

proc sameShot(a, b: VibShot) =
  ## Every field of two shots is the same (floats bit for bit).
  doAssert a.header.raw == b.header.raw and a.start == b.start
  doAssert a.frames == b.frames and a.tailBytes == b.tailBytes and
    a.complete == b.complete and a.incompleteWhy == b.incompleteWhy
  doAssert a.sampleIntervalUs == b.sampleIntervalUs and a.nameNumber == b.nameNumber
  doAssert a.data == b.data
  for v in VibCycleValue:
    doAssert a.cycle[v].len == b.cycle[v].len
    for i in 0 ..< a.cycle[v].len:
      doAssert bits(a.cycle[v][i]) == bits(b.cycle[v][i]), $(v, i)
  doAssert a.sweep.valid == b.sweep.valid and a.sweep.crossings == b.sweep.crossings
  doAssert a.triggerSource == b.triggerSource and a.triggerKnown == b.triggerKnown
  doAssert a.trigger == b.trigger and a.endsInSweep == b.endsInSweep
  doAssert (a.triggerFrame.isNaN and b.triggerFrame.isNaN) or
    a.triggerFrame == b.triggerFrame

proc main*() =

  block roundTrip:
    ## Every field, and every column exact, with the extreme counts and the odd floats.
    var syn = SynthVib(preTrigger: 2.5)
    syn.header = VibHeader(channelsPerFrame: 11, valveCal: 1234.5, massCal: 2345.25,
      unknown12: 3.5, unknown16: -4.25, holdDownLb: 56789.0, sensitivity1: 21.5,
      sensitivity2: 22.5, baseplateLb: 7001.0, massLb: 4002.0)
    syn.start = VibTime(year: 2019, month: 12, day: 31, hour: 23, minute: 59, second: 58)
    let counts = [-32768'i16, -1, 0, 32767, 1, -2, 255, 256]
    for c in VibChannel:
      for i in 0 ..< counts.len:
        syn.data[c].add counts[(i + ord(c)) mod counts.len]
    let odd = [NaN.float32, -0.0'f32, 0.0'f32, Inf.float32, -Inf.float32, 1.5'f32,
      3.0e38'f32, 1.0e-45'f32]
    for v in VibCycleValue:
      for i in 0 ..< odd.len:
        syn.cycle[v].add odd[(i + ord(v)) mod odd.len]
    let d = synthVib(syn)
    doAssert d.len == 47 + 26 * 8
    doAssert looksLikeVib(d) and vibKind(d) == vkSignature
    let s = parseVib(d)
    doAssert s.header.channelsPerFrame == 11
    doAssert s.header.valveCal == 1234.5'f32 and s.header.massCal == 2345.25'f32
    doAssert s.header.unknown12 == 3.5'f32 and s.header.unknown16 == -4.25'f32
    doAssert s.header.holdDownLb == 56789.0'f32 and s.header.sensitivity1 == 21.5'f32
    doAssert s.header.sensitivity2 == 22.5'f32 and s.header.baseplateLb == 7001.0'f32
    doAssert s.header.massLb == 4002.0'f32
    doAssert @(s.header.raw) == d[0 .. 46]
    doAssert s.start == syn.start and s.start.nanosecond == 0
    doAssert s.frames == 8 and s.len == 8 and s.tailBytes == 0 and s.complete
    doAssert s.incompleteWhy == "" and s.sampleIntervalUs == 500 and s.nameNumber == -1
    for c in VibChannel:
      doAssert s.data[c] == syn.data[c], $c
      doAssert s.samples(c).len == 8
      for i in 0 ..< 8:
        doAssert s.samples(c)[i] == float32(syn.data[c][i])
    for v in VibCycleValue:
      for i in 0 ..< 8:
        doAssert bits(s.cycle[v][i]) == bits(syn.cycle[v][i]), $(v, i)
        doAssert bits(s.samples(v)[i]) == bits(syn.cycle[v][i])
    doAssert bits(-0.0'f32) != bits(0.0'f32) # the test would see a lost sign
    # the info is the same minus the samples
    let i = parseVibInfo(d)
    doAssert i.header == s.header and i.start == s.start and i.frames == 8 and
      i.complete and i.tailBytes == 0
    # a longer file, derived channels: a plain shot round-trips its own columns
    let plain = parseVib(synthVib(SynthVib()))
    doAssert plain.frames == frameCount(SynthVib()) and plain.header.raw[0 .. 3] ==
      [byte('V'), byte('I'), byte('B'), 11'u8]

  block header:
    ## Every header float at its own offset: nine different values.
    var h = MadeUpHeader
    h.valveCal = 1.0
    h.massCal = 2.0
    h.unknown12 = 3.0
    h.unknown16 = 4.0
    h.holdDownLb = 5.0
    h.sensitivity1 = 6.0
    h.sensitivity2 = 7.0
    h.baseplateLb = 8.0
    h.massLb = 9.0
    let s = parseVib(synthVib(SynthVib(header: h, afterTrigger: 10)))
    doAssert [s.header.valveCal, s.header.massCal, s.header.unknown12,
      s.header.unknown16, s.header.holdDownLb, s.header.sensitivity1,
      s.header.sensitivity2, s.header.baseplateLb, s.header.massLb] ==
      [1.0'f32, 2, 3, 4, 5, 6, 7, 8, 9]
    # a NaN and a negative weight are kept as stored, not checked
    h.holdDownLb = NaN.float32
    h.massLb = -3.0
    let t = parseVib(synthVib(SynthVib(header: h, afterTrigger: 10)))
    doAssert t.header.holdDownLb.isNaN and t.header.massLb == -3.0'f32

  block kinds:
    let sig = synthVib(SynthVib(afterTrigger: 5))
    doAssert vibKind(sig) == vkSignature and vibKind(sig.toOpenArray(0, 3)) == vkSignature
    doAssert vibKind(sig.toOpenArray(0, 2)) == vkNotVib and vibKind(none) == vkNotVib
    doAssert vibKind([byte('V'), byte('I'), byte('X'), 11'u8]) == vkNotVib
    doAssert vibKind(synthOtherKind(5)) == vkOther
    doAssert vibKind(synthVib(SynthVib(kindByte: 12, afterTrigger: 5))) == vkOther
    doAssert not looksLikeVib(sig.toOpenArray(0, 45)) and looksLikeVib(sig.toOpenArray(0, 46))
    doAssert not looksLikeVib(synthOtherKind(5)) and not looksLikeVib(none)
    var bad = sig
    bad[44] = 13 # the month
    doAssert not looksLikeVib(bad)

  block refusals:
    discard refused(none, ["empty", "not a .vib file"])
    discard refused([byte('V'), byte('I'), byte('B')], ["3 bytes", "not a .vib file"])
    var wrong = synthVib(SynthVib(afterTrigger: 5))
    wrong[0] = byte('X')
    discard refused(wrong, ["not a .vib file", "VIB"])
    discard refused(newSeq[byte](100), ["not a .vib file"])
    let six = refused(synthOtherKind(20), ["another kind", "6 values per record",
      "36-byte records", "not a signature record"])
    doAssert "decoded" notin six
    discard refused(synthOtherKind(0), ["another kind"])
    discard refused(synthVib(SynthVib(kindByte: 12, afterTrigger: 5)), ["12 values per frame",
      "not known"])
    discard refused(synthVib(SynthVib(kindByte: 0, afterTrigger: 5)), ["0 values per frame"])
    discard refused(synthVib(SynthVib(kindByte: 255, afterTrigger: 5)), ["255 values"])
    # the offset is where the problem is
    try:
      discard parseVib(synthOtherKind(3))
    except VibFormatError as e:
      doAssert e.offset == 3
    # the cut header, and no frame: incomplete, still a VibFormatError
    let sig = synthVib(SynthVib(afterTrigger: 5))
    incomplete(sig[0 ..< 46], ["header is cut short", "46 bytes"])
    incomplete(sig[0 ..< 4], ["header is cut short"])
    incomplete(sig[0 ..< 47], ["no samples"])
    incomplete(sig[0 ..< 47], ["no samples"], true) # allowIncomplete does not help

  block badDates:
    var base = synthVib(SynthVib(afterTrigger: 5))
    proc with(at: int; v: byte): seq[byte] =
      result = base
      result[at] = v
    for (at, v, what) in [(44, 13'u8, "month 13"), (44, 0'u8, "month 0"),
        (43, 0'u8, "day 0"), (43, 32'u8, "day 32"), (42, 24'u8, "hour 24"),
        (41, 60'u8, "minute 60"), (40, 61'u8, "second 61")]:
      let m = refused(with(at, v), ["start time is not a valid date"])
      doAssert m.len > 0, what
    # February: 29 only in a leap year
    var feb = base
    feb[44] = 2
    feb[43] = 29
    feb[45] = 0xD0 # 2000 = 0x07D0
    feb[46] = 0x07
    doAssert parseVib(feb).start == VibTime(year: 2000, month: 2, day: 29, hour: 4,
      minute: 5, second: 6)
    feb[45] = 0x34 # 2100 = 0x0834: not a leap year
    feb[46] = 0x08
    discard refused(feb, ["valid date"])
    feb[45] = 0xB1 # 1969 = 0x07B1
    feb[46] = 0x07
    discard refused(feb, ["valid date"])
    feb[43] = 28
    discard refused(feb, ["valid date"]) # still 1969
    # the leap second and the last valid instant
    var last = base
    last[40] = 60
    doAssert parseVib(last).start.second == 60
    # parseVibInfo says the same
    doAssertRaises(VibFormatError):
      discard parseVibInfo(with(44, 13'u8))

  block noSamples:
    let h = synthVib(SynthVib(afterTrigger: 5))[0 ..< 47]
    incomplete(h, ["no samples"])
    incomplete(h & @[byte 1, 2, 3], ["no samples"], true) # a part of a frame is not a sample
    doAssertRaises(VibIncompleteError):
      discard parseVibInfo(h)

  block partialFrame:
    ## A copy cut short leaves a partial last frame: refused, or the whole frames.
    for extra in [1, 13, 25]:
      let d = synthVib(SynthVib(afterTrigger: 50, tailBytes: extra))
      incomplete(d, ["ends " & $extra & " bytes into a frame", "copy cut short"])
      let s = parseVib(d, allowIncomplete = true)
      doAssert s.frames == frameCount(SynthVib(afterTrigger: 50)) and not s.complete
      doAssert s.tailBytes == extra and "copy cut short" in s.incompleteWhy
      doAssert s.data[vcReference].len == s.frames and s.cycle[vvCycle2].len == s.frames
      # the whole frames are those of the complete file
      let whole = parseVib(synthVib(SynthVib(afterTrigger: 50)))
      doAssert s.data == whole.data
      # the info does not refuse
      let i = parseVibInfo(d)
      doAssert not i.complete and i.tailBytes == extra and i.frames == s.frames
      doAssert i.incompleteWhy == s.incompleteWhy
    # every cut of a file: whole frames or one of the errors
    let d = synthVib(SynthVib(afterTrigger: 10, preTrigger: 3.5))
    for n in 0 .. d.len:
      let part = d[0 ..< n]
      var ok = true
      try:
        let s = parseVib(part, allowIncomplete = true)
        doAssert s.frames == (n - 47) div 26 and s.tailBytes == (n - 47) mod 26
        doAssert s.complete == (s.tailBytes == 0)
      except VibFormatError:
        ok = false
      doAssert ok == (n >= 47 + 26), $n

  block sizeLimit:
    ## A file above `MaxVibBytes` is refused before it is read: from the size alone.
    let dir = getTempDir() / ("ssvib-tdecode-" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    let big = dir / "0001.VIB"
    block:
      let f = open(big, fmWrite)
      f.setFilePos(MaxVibBytes) # sparse: one byte past the limit
      f.write("x")
      f.close()
    doAssert getFileSize(big) == MaxVibBytes + 1
    var buffer: seq[byte] = @[]
    var shot = VibShot()
    for attempt in 0 .. 3:
      try:
        case attempt
        of 0: discard readVib(big)
        of 1: readVibInto(big, shot, buffer)
        of 2: discard readVibInfo(big)
        else: discard parseVibInfo(synthVib(SynthVib(afterTrigger: 2)).toOpenArray(0, 46),
          MaxVibBytes + 1)
        doAssert false, "was read " & $attempt
      except VibFormatError as e:
        doAssert "larger than any .vib file" in e.msg or "larger than any" in e.msg, e.msg
    doAssert buffer.len == 0, "the buffer was grown before the size was checked"
    # a file of exactly the limit is not refused for its size (here: not a .vib file)
    let edge = dir / "edge.VIB"
    block:
      let f = open(edge, fmWrite)
      f.setFilePos(MaxVibBytes - 1)
      f.write("x")
      f.close()
    try:
      discard readVib(edge)
    except VibFormatError as e:
      doAssert "larger" notin e.msg and "not a .vib file" in e.msg, e.msg

  block interval:
    let d = synthVib(SynthVib(afterTrigger: 5))
    for bad in [0.0, -1.0, NaN, Inf, -Inf]:
      doAssertRaises(ValueError):
        discard parseVib(d, sampleIntervalUs = bad)
      doAssertRaises(ValueError):
        discard parseVibInfo(d, bad)
      doAssertRaises(ValueError):
        var s = VibShot()
        decodeInto(s, d, sampleIntervalUs = bad)
    let s = parseVib(d, sampleIntervalUs = 250.5)
    doAssert s.sampleIntervalUs == 250.5
    doAssert parseVibInfo(d, 1000.0).sampleIntervalUs == 1000.0
    # not even a hostile file hides a bad interval
    doAssertRaises(ValueError):
      discard parseVib(none, sampleIntervalUs = 0)

  block infoOnly:
    ## `readVibInfo` and `parseVibInfo` are `parseVib` minus the samples.
    let dir = getTempDir() / ("ssvib-tdecode-info-" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    for syn in [SynthVib(afterTrigger: 300), SynthVib(afterTrigger: 1, preTrigger: 0.5),
        SynthVib(afterTrigger: 40, tailBytes: 7)]:
      let d = synthVib(syn)
      writeFile(dir / "0042.VIB", cast[string](d))
      let full = parseVib(d, allowIncomplete = true)
      for info in [parseVibInfo(d), parseVibInfo(d.toOpenArray(0, 46), int64(d.len)),
          readVibInfo(dir / "0042.VIB")]:
        doAssert info.header == full.header and info.start == full.start
        doAssert info.frames == full.frames and info.tailBytes == full.tailBytes
        doAssert info.complete == full.complete and info.incompleteWhy == full.incompleteWhy
        doAssert info.sampleIntervalUs == full.sampleIntervalUs
      doAssert readVibInfo(dir / "0042.VIB").nameNumber == 42
      doAssert parseVibInfo(d).nameNumber == -1
    # a short head is a ValueError, not an out-of-range read
    let d = synthVib(SynthVib(afterTrigger: 20))
    doAssertRaises(ValueError):
      discard parseVibInfo(d.toOpenArray(0, 30), int64(d.len))
    # a file of 5 bytes needs only 5 bytes of head
    doAssertRaises(VibFormatError):
      discard parseVibInfo([byte(1), 2, 3, 4, 5], 5)
    # a missing file is an IOError with the path
    try:
      discard readVibInfo(dir / "missing.VIB")
      doAssert false
    except IOError as e:
      doAssert "missing.VIB" in e.msg

  block reuse:
    ## `decodeInto` over files of different lengths gives what a fresh decode gives,
    ## also after a file that was refused, and forgets the trigger a caller set.
    var shot = VibShot()
    let files = [SynthVib(afterTrigger: 3000), SynthVib(afterTrigger: 50, preTrigger: 3.25),
      SynthVib(afterTrigger: 6000, preTrigger: 700.5), SynthVib(afterTrigger: 1),
      SynthVib(afterTrigger: 80, tailBytes: 4)]
    for syn in files:
      let d = synthVib(syn)
      decodeInto(shot, d, allowIncomplete = true)
      sameShot(shot, parseVib(d, allowIncomplete = true))
      shot.setTrigger(VibTime(year: 2020, month: 1, day: 2, hour: 3, minute: 4, second: 5,
        nanosecond: 6), 3.0)
      doAssert shot.triggerKnown and shot.triggerSource == tsGiven
      try:
        decodeInto(shot, synthOtherKind(4))
      except VibFormatError:
        discard
    # the same shot decodes the next file: no leftover of the trigger or the sweep
    decodeInto(shot, synthVib(SynthVib(afterTrigger: 50)))
    doAssert not shot.triggerKnown and shot.trigger == VibTime() and
      shot.triggerSource == tsNone and shot.triggerFrame.isNaN and not shot.sweep.valid
    decodeInto(shot, synthVib(SynthVib()))
    doAssert shot.triggerSource == tsEstimated and shot.sweep.valid
    shot.setTrigger(VibTime(year: 2020, month: 1, day: 2), 4.0)
    decodeInto(shot, synthVib(SynthVib()))
    doAssert not shot.triggerKnown and shot.triggerSource == tsEstimated and
      shot.triggerFrame > 500
    # the file reader reuses the buffer
    let dir = getTempDir() / ("ssvib-tdecode-reuse-" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    var buffer: seq[byte] = @[]
    for (name, syn) in [("0001.VIB", SynthVib(afterTrigger: 500)),
        ("0002.vib", SynthVib(afterTrigger: 20))]:
      writeFile(dir / name, cast[string](synthVib(syn)))
      readVibInto(dir / name, shot, buffer)
      doAssert shot.frames == frameCount(syn) and buffer.len == 47 + 26 * shot.frames
      sameShot(shot, readVib(dir / name))
    doAssert shot.nameNumber == 2

  block nameNumberReset:
    ## A shot that was read from a file named by a number forgets it in the next decode
    ## of bytes (a number that is not the name of a file).
    let dir = getTempDir() / ("ssvib-tdecode-name-" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    writeFile(dir / "0077.VIB", cast[string](synthVib(SynthVib(afterTrigger: 20))))
    var shot = readVib(dir / "0077.VIB")
    doAssert shot.nameNumber == 77
    decodeInto(shot, synthVib(SynthVib(afterTrigger: 20)))
    doAssert shot.nameNumber == -1

  block lyingSize:
    ## A size that does not fit an `int` (32-bit) or is negative is refused with words,
    ## never a range error.
    let head = synthVib(SynthVib(afterTrigger: 20))[0 ..< 47]
    for size in [-3_000_000_000'i64, -1'i64, low(int64), 0'i64]:
      doAssertRaises(VibFormatError):
        discard parseVibInfo(head, size)
    doAssertRaises(ValueError): # a head shorter than the size needs
      discard parseVibInfo(head[0 ..< 10], 1000'i64)
    doAssertRaises(VibFormatError):
      discard parseVibInfo(head, high(int64))

  block findTrigger:
    let d = synthVib(SynthVib(preTrigger: 650.25))
    let on = parseVib(d)
    doAssert on.sweep.valid and on.triggerSource == tsEstimated
    doAssert abs(on.triggerFrame - 650.25) < 0.02 and on.triggerFrame == on.sweep.triggerFrame
    doAssert on.triggerSigmaFrames > 0 and on.triggerSigmaFrames < 0.05 and
      on.triggerSigmaFrames == on.sweep.triggerSigmaFrames
    let off = parseVib(d, findTrigger = false)
    doAssert not off.sweep.valid and off.triggerSource == tsNone and
      off.triggerFrame.isNaN and off.triggerSigmaFrames.isNaN
    doAssert not off.endsInSweep
    # a pulse-shaped file has no estimate and still decodes
    var pulse = SynthVib()
    for i in 0 ..< 3000:
      pulse.data[vcReference].add int16(if i in 100 .. 130: 20000 - 300 * (i - 100) else: 0)
    let p = parseVib(synthVib(pulse))
    doAssert not p.sweep.valid and p.triggerSource == tsNone and p.triggerFrame.isNaN

  block setTrigger:
    var s = parseVib(synthVib(SynthVib(preTrigger: 650.25)))
    let est = s.triggerFrame
    let t = VibTime(year: 2001, month: 2, day: 3, hour: 4, minute: 5, second: 7,
      nanosecond: 789_000_000)
    s.setTrigger(t)
    doAssert s.triggerKnown and s.trigger == t and s.triggerFrame == est and
      s.triggerSource == tsEstimated and s.triggerSigmaFrames > 0
    s.setTrigger(t, 651.5)
    doAssert s.triggerFrame == 651.5 and s.triggerSource == tsGiven and
      s.triggerSigmaFrames.isNaN
    for bad in [-0.5, float64(s.len) + 1, Inf, -Inf]:
      doAssertRaises(ValueError):
        s.setTrigger(t, bad)
    doAssertRaises(ValueError):
      s.setTrigger(VibTime(year: 2001, month: 13, day: 1))
    doAssertRaises(ValueError):
      s.setTrigger(VibTime(year: 2001, month: 1, day: 1, nanosecond: 1_000_000_000))
    doAssert s.triggerFrame == 651.5 # a refused call changes nothing
    # frames 0 and len are allowed
    s.setTrigger(t, 0.0)
    s.setTrigger(t, float64(s.len))

  block triggerWindow:
    var s = parseVib(synthVib(SynthVib(preTrigger: 600.0)))
    let start = posixTime(s.start)
    doAssert abs(s.triggerFrame - 600.0) < 0.02
    var w = s.triggerWindow
    doAssert abs(w.lo - (start + s.triggerFrame * 0.0005)) < 1e-6 and
      abs(w.hi - w.lo - 1.02) < 1e-6
    s.setTrigger(VibTime(year: 2001, month: 2, day: 3, hour: 4, minute: 5, second: 7),
      1000.0)
    w = s.triggerWindow
    doAssert abs(w.lo - (start + 0.5)) < 1e-6 and abs(w.hi - (start + 1.52)) < 1e-6
    # no trigger frame: the start second plus 0.2 to 1.5 s
    let n = parseVib(synthVib(SynthVib(afterTrigger: 20)))
    doAssert n.triggerFrame.isNaN
    w = n.triggerWindow
    doAssert abs(w.lo - (posixTime(n.start) + 0.2)) < 1e-6 and
      abs(w.hi - (posixTime(n.start) + 1.5)) < 1e-6

  block times:
    let t = VibTime(year: 2001, month: 2, day: 3, hour: 4, minute: 5, second: 6,
      nanosecond: 789_000_000)
    doAssert posixSeconds(t) == 981173106 and abs(posixTime(t) - 981173106.789) < 1e-6
    doAssert $t == "2001-02-03T04:05:06.789000Z"
    doAssert posixSeconds(VibTime(year: 1970, month: 1, day: 1)) == 0
    doAssert posixSeconds(VibTime(year: 2000, month: 3, day: 1)) == 951868800
    doAssert posixSeconds(VibTime(year: 9999, month: 12, day: 31, hour: 23, minute: 59,
      second: 59)) == 253402300799
    doAssert $VibTime(year: 2001, month: 2, day: 3) == "2001-02-03T00:00:00.000000Z"

  block stems:
    var s = parseVib(synthVib(SynthVib(afterTrigger: 20)))
    doAssert vibFileStem(s, 42) == "0042_20010203T040506Z_vib"
    doAssert vibFileStem(s, 12345) == "12345_20010203T040506Z_vib"
    doAssert vibFileStem(s, 0) == "0000_20010203T040506Z_vib"
    s.setTrigger(VibTime(year: 2001, month: 2, day: 3, hour: 4, minute: 5, second: 7,
      nanosecond: 789_000_000))
    doAssert vibFileStem(s, 42) == "0042_20010203T040507.789000000Z_vib"
    s.setTrigger(VibTime(year: 2001, month: 2, day: 3, hour: 4, minute: 5, second: 7,
      nanosecond: 5))
    doAssert vibFileStem(s, 7) == "0007_20010203T040507.000000005Z_vib"
    doAssertRaises(ValueError):
      discard vibFileStem(s, -1)
    for c in vibFileStem(s, 7):
      doAssert c notin {':', '/', '\\', '*', '?', '"', '<', '>', '|', ' '}

  block names:
    doAssert nameNumberOf("a/b/0042.VIB") == 42 and nameNumberOf("0042.vib") == 42 and
      nameNumberOf("x/0000.Vib") == 0 and nameNumberOf("123456789.VIB") == 123456789
    for bad in ["a/b/0042.dat", "a/b/abcd.VIB", "a/b/.VIB", "0042", "a/0042.VIB.bak",
        "1234567890.VIB", "12 4.VIB", "-5.VIB", ""]:
      doAssert nameNumberOf(bad) == -1, bad
    doAssert serialFromPath("root/Data/0042/05-06-07/0001.VIB") == 42
    doAssert serialFromPath("0042/05-06-07/0001.VIB") == 42
    doAssert serialFromPath("root/0000/05-06-07/0001.VIB") == 0
    for bad in ["0001.VIB", "05-06-07/0001.VIB", "root/abcd/05-06-07/0001.VIB",
        "root/12_0042/05-06-07/0001.VIB", "", "root/12345678901/05-06-07/0001.VIB",
        "root/_5/x/0001.VIB", "root/42/05-06-07/0001.VIB", "root/00042/05-06-07/0001.VIB",
        "root/12345/x/0001.VIB", "root/+042/x/0001.VIB"]:
      doAssert serialFromPath(bad) == -1, bad

  block endsInSweepFlag:
    doAssert not parseVib(synthVib(SynthVib())).endsInSweep
    doAssert parseVib(synthVib(SynthVib(stopAt: 5000, preTrigger: 600.0))).endsInSweep

when isMainModule:
  main()
