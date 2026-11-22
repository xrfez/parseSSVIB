## Decoder of a vibrator controller's `.vib` signature file.
##
## A file is a 47-byte header and then fixed 26-byte frames to its end, all
## little-endian: no blocks, no checksums, no record header and no sample count.
##
## | bytes | field |
## |---|---|
## | 0-2 | `VIB` |
## | 3 | values per frame: 11 for the signature record this library decodes |
## | 4-39 | nine `float32`: the LVDT calibrations, two unknowns, the hold-down weight, the accelerometer sensitivity twice, the baseplate and reaction-mass weights |
## | 40-46 | the second, minute, hour, day and month (one byte each) and the year (`uint16`) the recording began |
## | 47 + 26 k | frame k: nine `int16` (`VibChannel`) and two `float32` (`VibCycleValue`) |
##
## A frame is one sample of every channel. The sample interval, the trigger position
## and the sweep are not in the file: the interval is 500 us for every file seen (the
## caller can say another), and the trigger can be estimated from the reference
## (`fitSweep`). The header's time is the second the recording began, not the
## trigger; the trigger's time to the microsecond, the controller's serial number and
## the file number are in the `.dat` file of the same sweep, and `setTrigger` takes
## them from there.
##
## A file with another value in byte 3 (the one other kind seen has 6, and 36-byte
## records) is a different file: `parseVib` refuses it with `VibFormatError`, as an
## empty file. A copy cut short at a frame boundary cannot be told from a stopped
## recording, except by `endsInSweep`.
##
## `parseVib` checks every byte it relies on and raises `VibFormatError` for bytes
## that break the format; it never reads outside its input and sizes its allocation
## from the input's length (the file states no number to trust). For a list of many
## files, `readVibInfo` reads 47 bytes of a file and never its samples. For decoding
## many files, `decodeInto` and `readVibInto` fill a `VibShot` and a byte buffer the
## caller keeps: after the first files they allocate nothing. Every proc here is safe
## to call from several threads on different files and objects (there is no global
## state).

import std/[math, os, strutils]
import ./[sweep, types]

const
  DefaultIntervalUs = 500.0
  KindOther = "a .vib file of another kind"

func raiseFormat(msg: string; offset: int64 = -1) {.noinline, noreturn.} =
  ## Raises a `VibFormatError` with the file offset of the problem.
  var e = newException(VibFormatError, msg)
  e.offset = offset
  raise e

func raiseIncomplete(msg: string; offset: int64 = -1) {.noinline, noreturn.} =
  ## Raises a `VibIncompleteError` with the file offset of the problem.
  var e = newException(VibIncompleteError, msg)
  e.offset = offset
  raise e

func u16le(b: openArray[byte]; at: int): uint16 {.inline.} =
  uint16(b[at]) or (uint16(b[at + 1]) shl 8)

func u32le(b: openArray[byte]; at: int): uint32 {.inline.} =
  uint32(b[at]) or (uint32(b[at + 1]) shl 8) or (uint32(b[at + 2]) shl 16) or
    (uint32(b[at + 3]) shl 24)

func f32le(b: openArray[byte]; at: int): float32 {.inline.} =
  cast[float32](u32le(b, at))

func vibKind*(head: openArray[byte]): VibKind =
  ## The kind of file that starts with `head` (4 bytes are enough): `vkSignature` for
  ## `VIB` and 11, `vkOther` for `VIB` and another number, `vkNotVib` for anything
  ## else, also a `head` shorter than 4 bytes. Never raises.
  if head.len < 4 or head[0] != byte('V') or head[1] != byte('I') or head[2] != byte('B'):
    vkNotVib
  elif head[3] == VibSignatureKind:
    vkSignature
  else:
    vkOther

func isLeapYear(y: int): bool =
  (y mod 4 == 0 and y mod 100 != 0) or y mod 400 == 0

func daysInMonth(y, m: int): int =
  case m
  of 2: (if isLeapYear(y): 29 else: 28)
  of 4, 6, 9, 11: 30
  else: 31

func validTime(t: VibTime): bool =
  ## A valid date and time of day: years 1970 to 9999, a second up to 60.
  t.year in 1970 .. 9999 and t.month in 1 .. 12 and
    t.day in 1 .. daysInMonth(t.year, t.month) and t.hour in 0 .. 23 and
    t.minute in 0 .. 59 and t.second in 0 .. 60 and t.nanosecond in 0 .. 999_999_999

func startOf(b: openArray[byte]): VibTime =
  VibTime(second: int(b[40]), minute: int(b[41]), hour: int(b[42]), day: int(b[43]),
    month: int(b[44]), year: int(u16le(b, 45)))

func looksLikeVib*(head: openArray[byte]): bool =
  ## True when `head` starts as a signature record: `VIB`, 11, at least 47 bytes and
  ## a valid start date and time. Never raises. For a file list that only has the
  ## start of each file.
  result = vibKind(head) == vkSignature and head.len >= VibHeaderBytes and
    validTime(startOf(head))

func posixSeconds*(t: VibTime): int64 =
  ## UTC POSIX seconds of `t`, without its nanoseconds. Exact.
  let y = if t.month <= 2: t.year - 1 else: t.year
  let era = (if y >= 0: y else: y - 399) div 400
  let yoe = y - era * 400
  let mp = if t.month > 2: t.month - 3 else: t.month + 9
  let doy = (153 * mp + 2) div 5 + t.day - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  let days = int64(era) * 146097 + int64(doe) - 719468
  days * 86400 + int64(t.hour * 3600 + t.minute * 60 + t.second)

func posixTime*(t: VibTime): float64 =
  ## UTC POSIX seconds of `t`, with its nanoseconds as a fraction (a `float64` holds
  ## about 0.2 microseconds of a time near now: keep `t` where an exact time matters).
  float64(posixSeconds(t)) + float64(t.nanosecond) / 1e9

func `$`*(t: VibTime): string =
  ## ISO 8601 with microseconds, `2001-02-03T04:05:06.789000Z`.
  intToStr(t.year, 4) & "-" & intToStr(t.month, 2) & "-" & intToStr(t.day, 2) & "T" &
    intToStr(t.hour, 2) & ":" & intToStr(t.minute, 2) & ":" & intToStr(t.second, 2) &
    "." & intToStr(t.nanosecond div 1000, 6) & "Z"

func serialText(serial: int64): string =
  let s = $serial
  repeat('0', max(0, 4 - s.len)) & s

func vibFileStem*(s: VibShot; serial: int64): string =
  ## A file name (without extension) for output made from `s`: the controller's
  ## serial, zero-padded to four digits (a serial above 9999 gives a wider stem), the
  ## time and `_vib`. The serial is not in the file: the caller says it (see
  ## `serialFromPath`, or the `.dat` file of the sweep). With the trigger time known
  ## (`setTrigger`) the stem has it to the nanosecond, as `datFileStem` of the `.dat`
  ## file would plus `_vib`, so the two sort together and never collide:
  ## `0042_20010203T040506.789000000Z_vib`. Without it, the second the recording
  ## began: `0042_20010203T040506Z_vib`. Holds no character Windows forbids. Raises
  ## `ValueError` for a negative serial.
  if serial < 0:
    raise newException(ValueError, "the controller serial must not be negative, not " &
      $serial)
  let t = if s.triggerKnown: s.trigger else: s.start
  result = serialText(serial) & "_" & intToStr(t.year, 4) & intToStr(t.month, 2) &
    intToStr(t.day, 2) & "T" & intToStr(t.hour, 2) & intToStr(t.minute, 2) &
    intToStr(t.second, 2)
  if s.triggerKnown:
    result.add "." & intToStr(t.nanosecond, 9)
  result.add "Z_vib"

func digitsValue(t: string): int64 =
  ## `t` as a number when it is 1 to 9 digits, else -1.
  result = -1
  if t.len in 1 .. 9 and t.allCharsInSet(Digits):
    result = 0
    for c in t:
      result = result * 10 + int64(ord(c) - ord('0'))

func serialFromPath*(path: string): int64 =
  ## The number in the name of the folder two levels above the file, for the layout
  ## controllers' folders have (`<serial>/<date>/NNNN.VIB`): a folder named by exactly
  ## four digits. -1 when the folder is named otherwise (a year folder `2023` is four
  ## digits too: the caller checks the layout). A convenience: the caller decides what
  ## the serial is.
  let folder = splitPath(splitPath(splitPath(path).head).head).tail
  if folder.len == 4 and folder.allCharsInSet(Digits): digitsValue(folder) else: -1

func nameNumberOf*(path: string): int64 =
  ## The digits of a `NNNN.VIB` file name (1 to 9 digits; the extension in any case),
  ## else -1. The controller counts its `.vib` files with them.
  let (_, name, ext) = splitFile(path)
  if ext.toLowerAscii == ".vib": digitsValue(name) else: -1

func len*(s: VibShot): int =
  ## Frames present.
  s.data[vcReference].len

func samples*(s: VibShot; c: VibChannel): seq[float32] =
  ## The counts of channel `c` as `float32`; every 16-bit count is exact.
  result = newSeq[float32](s.data[c].len)
  for i, v in s.data[c]:
    result[i] = float32(v)

func samples*(s: VibShot; v: VibCycleValue): seq[float32] =
  ## The per-cycle value `v` as stored.
  s.cycle[v]

func triggerWindow*(s: VibShot): tuple[lo, hi: float64] =
  ## The POSIX seconds the trigger lies in, for pairing the file with the `.dat` of
  ## its sweep. With a trigger frame known: the start second plus the frame times
  ## the interval, plus 0 to 1.02 s (the first frame lies 0.016 to 1.005 s after the
  ## start second in every file seen). Without one: the start second plus 0.2 to
  ## 1.5 s (the trigger lay 0.30 to 1.41 s after it).
  let base = posixTime(s.start)
  if not s.triggerFrame.isNaN:
    let at = base + s.triggerFrame * s.sampleIntervalUs / 1e6
    result = (at, at + 1.02)
  else:
    result = (base + 0.2, base + 1.5)

proc setTrigger*(s: var VibShot; t: VibTime; frame = NaN) =
  ## Records the trigger time from elsewhere (the `.dat` file of the sweep): `t`, UTC.
  ## `frame` is the trigger as a fractional frame and replaces the estimate (source
  ## `tsGiven`, no uncertainty); NaN keeps the estimate. Raises `ValueError` for a
  ## time that is not a valid date, or a frame beyond the shot's frames or below 0.
  if not validTime(t):
    raise newException(ValueError, "the trigger time " & $t & " is not a valid date")
  if not frame.isNaN:
    if not (frame >= 0 and frame <= float64(s.len)):
      raise newException(ValueError, "the trigger frame " & $frame &
        " is outside the shot's " & $s.len & " frames")
    s.triggerFrame = frame
    s.triggerSigmaFrames = NaN
    s.triggerSource = tsGiven
  s.trigger = t
  s.triggerKnown = true

proc checkInterval(v: float64) =
  if not (v > 0 and v < Inf):
    raise newException(ValueError, "the sample interval must be positive and finite, " &
      "not " & $v)

proc fillInfo(s: var VibInfo; head: openArray[byte]; fileSize: int64; interval: float64;
    strictTail: bool) =
  ## The checks every reader makes, in order, and the fields of `s` that come from
  ## the header and the size. `head` holds the first `min(fileSize, 47)` bytes at
  ## least. With `strictTail` a partial last frame raises `VibIncompleteError`.
  checkInterval(interval)
  if fileSize > MaxVibBytes:
    raiseFormat("the file is " & $fileSize & " bytes, larger than any .vib file " &
      "(the limit is " & $MaxVibBytes & ")", 0)
  if fileSize < 4 or head.len < 4 or vibKind(head) == vkNotVib:
    raiseFormat((if fileSize == 0: "the file is empty" else: "the file is " & $fileSize &
      " bytes") & ": not a .vib file (it must start with VIB)", 0)
  let kind = int(head[3])
  if kind != VibSignatureKind:
    if kind == 6:
      raiseFormat(KindOther & " (6 values per record, 36-byte records): not a " &
        "signature record", 3)
    else:
      raiseFormat("a .vib file with " & $kind & " values per frame, a kind not known",
        3)
  if fileSize < VibHeaderBytes or head.len < VibHeaderBytes:
    raiseIncomplete("the header is cut short: the file is " & $fileSize &
      " bytes, the header 47", fileSize)
  let start = startOf(head)
  if not validTime(start):
    raiseFormat("the start time is not a valid date (" & $start.year & "-" &
      $start.month & "-" & $start.day & " " & $start.hour & ":" & $start.minute & ":" &
      $start.second & ")", 40)
  let body = fileSize - VibHeaderBytes
  let frames = int(body div VibFrameBytes)
  let tail = int(body mod VibFrameBytes)
  if frames == 0:
    raiseIncomplete("the file holds no samples: no frame after the header", 47)
  s.header.channelsPerFrame = kind
  s.header.valveCal = f32le(head, 4)
  s.header.massCal = f32le(head, 8)
  s.header.unknown12 = f32le(head, 12)
  s.header.unknown16 = f32le(head, 16)
  s.header.holdDownLb = f32le(head, 20)
  s.header.sensitivity1 = f32le(head, 24)
  s.header.sensitivity2 = f32le(head, 28)
  s.header.baseplateLb = f32le(head, 32)
  s.header.massLb = f32le(head, 36)
  for i in 0 ..< VibHeaderBytes:
    s.header.raw[i] = head[i]
  s.start = start
  s.frames = frames
  s.tailBytes = tail
  s.sampleIntervalUs = interval
  s.nameNumber = -1
  s.complete = tail == 0
  s.incompleteWhy.setLen(0)
  if tail != 0:
    let why = "the file ends " & $tail & " bytes into a frame: a copy cut short"
    if strictTail:
      raiseIncomplete(why, fileSize - tail)
    s.incompleteWhy = why

proc parseVibInfo*(head: openArray[byte]; fileSize: int64;
    sampleIntervalUs = DefaultIntervalUs): VibInfo =
  ## Everything about a file but its samples, from `head` (its first
  ## `min(fileSize, 47)` bytes at least) and the file's size. A file that ends inside
  ## a frame is not refused: `complete` is false with the reason in words. Raises
  ## `VibFormatError` as `parseVib` does for what it can see, `VibIncompleteError` for
  ## a header cut short or a file without a frame, and `ValueError` for a bad
  ## interval or a `head` too short.
  checkInterval(sampleIntervalUs)
  if int64(head.len) < min(fileSize, int64(VibHeaderBytes)):
    raise newException(ValueError, "the first bytes of the file are missing")
  result = VibInfo()
  fillInfo(result, head, fileSize, sampleIntervalUs, false)

proc parseVibInfo*(data: openArray[byte]; sampleIntervalUs = DefaultIntervalUs): VibInfo =
  ## `parseVibInfo` of a whole file held in memory.
  parseVibInfo(data, int64(data.len), sampleIntervalUs)

proc fileError(path: string; e: ref Exception) {.noinline, noreturn.} =
  raise newException(IOError, "cannot read " & path & ": " & e.msg)

proc readVibInfo*(path: string; sampleIntervalUs = DefaultIntervalUs): VibInfo =
  ## The `VibInfo` of the file at `path`, reading its first 47 bytes and nothing else
  ## (see `parseVibInfo`); `nameNumber` is set from the name. A file larger than
  ## `MaxVibBytes` raises `VibFormatError`; one that cannot be read, `IOError` with the
  ## path.
  var head: array[VibHeaderBytes, byte]
  var size = 0'i64
  var got = 0
  try:
    let f = open(path, fmRead)
    try:
      size = f.getFileSize # of the open file: a path's size can lag on Windows
      if size > MaxVibBytes:
        raiseFormat(path & " is larger than any .vib file", 0)
      got = f.readBuffer(addr head[0], int(min(size, int64(head.len))))
    finally:
      f.close()
  except OSError as e:
    fileError(path, e)
  except IOError as e:
    fileError(path, e)
  if got != int(min(size, int64(head.len))):
    raise newException(IOError, "cannot read " & path & ": the file changed while it " &
      "was read")
  result = parseVibInfo(head.toOpenArray(0, got - 1), size, sampleIntervalUs)
  result.nameNumber = nameNumberOf(path)

proc decodeInto*(s: var VibShot; data: openArray[byte]; allowIncomplete = false;
    sampleIntervalUs = DefaultIntervalUs; findTrigger = true) =
  ## Decodes the bytes of a `.vib` file into `s`, which a caller keeps between files:
  ## its sample arrays are reused, so after the first few files nothing is allocated
  ## (the sweep fit allocates nothing either). `s` holds nothing useful after an
  ## exception.
  ##
  ## Raises `VibFormatError` for bytes that are not a signature record (the message
  ## says what: empty, not `VIB`, another kind, a start time that is no date, larger
  ## than `MaxVibBytes`) and `VibIncompleteError` for a header cut short, a file
  ## without a frame, or a file that ends inside a frame, unless `allowIncomplete` is
  ## set: then such a file gives the whole frames (`complete = false`, `incompleteWhy`
  ## in words). `ValueError` for an interval that is not positive and finite. No input
  ## makes it raise a `Defect` or allocate more than a small multiple of `data.len`.
  ##
  ## With `findTrigger` the sweep is fitted to the reference: a valid fit sets
  ## `triggerFrame` (with `triggerSigmaFrames`) and `triggerSource = tsEstimated`;
  ## `sweep` holds the fit either way. `endsInSweep` is always set.
  s.fillInfo(data, int64(data.len), sampleIntervalUs, not allowIncomplete)
  let n = s.frames
  for c in VibChannel:
    s.data[c].setLen(n)
    let col = ord(c) * 2
    for i in 0 ..< n:
      let at = VibHeaderBytes + i * VibFrameBytes + col
      s.data[c][i] = cast[int16](u16le(data, at))
  for v in VibCycleValue:
    s.cycle[v].setLen(n)
    let col = 18 + ord(v) * 4
    for i in 0 ..< n:
      s.cycle[v][i] = f32le(data, VibHeaderBytes + i * VibFrameBytes + col)
  s.sweep = VibSweep()
  s.triggerFrame = NaN
  s.triggerSigmaFrames = NaN
  s.triggerSource = tsNone
  s.trigger = VibTime()
  s.triggerKnown = false
  s.endsInSweep = endsInSweep(s.data[vcReference])
  if findTrigger:
    s.sweep = fitSweep(s.data[vcReference], sampleIntervalUs)
    if s.sweep.valid:
      s.triggerFrame = s.sweep.triggerFrame
      s.triggerSigmaFrames = s.sweep.triggerSigmaFrames
      s.triggerSource = tsEstimated

proc parseVib*(data: openArray[byte]; allowIncomplete = false;
    sampleIntervalUs = DefaultIntervalUs; findTrigger = true): VibShot =
  ## Decodes the bytes of a `.vib` file; see `decodeInto`. `sampleIntervalUs` is the
  ## interval of the frames: the file does not state it, so this is an assumption of
  ## the caller (500 us for every file seen).
  result = VibShot()
  decodeInto(result, data, allowIncomplete, sampleIntervalUs, findTrigger)

proc readVibInto*(path: string; s: var VibShot; buffer: var seq[byte];
    allowIncomplete = false; sampleIntervalUs = DefaultIntervalUs; findTrigger = true) =
  ## Reads the file at `path` into `buffer` (which the caller keeps for the next file)
  ## and decodes it into `s`; see `decodeInto`. Sets `nameNumber` from the name. A file
  ## larger than `MaxVibBytes` raises `VibFormatError` before it is read; one that
  ## cannot be read, `IOError` with the path.
  try:
    let f = open(path, fmRead)
    try:
      let size = f.getFileSize # of the open file: a path's size can lag on Windows
      if size > MaxVibBytes:
        raiseFormat(path & " is larger than any .vib file", 0)
      buffer.setLen(int(size))
      if size > 0 and f.readBuffer(addr buffer[0], int(size)) != int(size):
        raise newException(IOError, "the file is shorter than its size says")
    finally:
      f.close()
  except OSError as e:
    fileError(path, e)
  except IOError as e:
    fileError(path, e)
  decodeInto(s, buffer, allowIncomplete, sampleIntervalUs, findTrigger)
  s.nameNumber = nameNumberOf(path)

proc readVib*(path: string; allowIncomplete = false; sampleIntervalUs = DefaultIntervalUs;
    findTrigger = true): VibShot =
  ## Reads and decodes the file at `path` (see `decodeInto`); `nameNumber` is set from
  ## the name.
  var buffer: seq[byte] = @[]
  result = VibShot()
  readVibInto(path, result, buffer, allowIncomplete, sampleIntervalUs, findTrigger)
