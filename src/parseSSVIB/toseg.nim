## A decoded `.vib` shot as SEG-Y or SEG-D, through parseSEG's writers.
##
## `toTraceKeys` and `VibShot.samples` give the shape parseSEG's `writeTrace` takes;
## `writeSegyTraces` and `writeSegdTraces` hand every trace of a shot to an open
## writer, so several shots can go into one file, a record each. The `.vib` holds raw
## counts: the options of `VibWriteOptions` decide any scaling, mean removal and
## derived trace. Samples are written exactly as recorded and no option changes a
## sign.
##
## **Traces**, in this order: the chosen channels in file order, then the two
## per-cycle values (when asked), then the computed ground forces. The set that
## `primary` names (B by default: the one the `.dat` file records) gets the standard
## codes; every other column gets 256 plus its column number, a code that is "optional
## use" in Rev 1 and Rev 2 alike.
##
## | trace | SEG-Y code | SEG-D type |
## |---|---:|---|
## | reference | 21 | `segdReference` (0x96, or 0x98) |
## | baseplate acceleration of the primary set | 19 | 0x95 |
## | reaction-mass acceleration of the primary set | 18 | 0x99 |
## | ground force of the primary set, computed | 20 | 0x93 |
## | torque-motor current, valve, mass displacement, drive, other set's accelerations, per-cycle values | 256 + column | 0x97, valve 0x9B, drive 0x9A |
## | ground force of the other set, computed | 267 | 0x97 |
##
## **Time.** With `vaTrigger` (the default) the time of sample 0 is minus the trigger
## frame times the interval (negative: the pre-trigger), so t = 0 is the trigger, when
## the shot has a trigger frame (the estimate of the sweep fit, or the caller's);
## otherwise, and with `vaRecord`, t = 0 is the first frame. SEG-Y keeps the fraction
## of a millisecond. The `time` key is the time of t = 0: the trigger time when the
## caller gave it (`setTrigger`), else the second the recording began, which the
## text header says. The `.vib` has no position, line or station: none is written.
##
## **Errors.** A value the format cannot hold or an option that makes no sense raises
## `VibWriteError` with plain words: a constant a physical trace needs and the caller
## did not give, a record number SEG-D cannot hold, an interval that is not a whole
## number of microseconds for SEG-D, an existing file in the folder forms. Whatever
## else parseSEG refuses for a shot is translated into the same error. Problems with
## the file system, and diagnostics the writer reports when it closes, are `IOError`.

import std/[math, os, strutils]
when defined(windows):
  import std/winlean
else:
  import std/posix
import parseSEG
import ./[decode, types, units]

const
  PackageVersion = "0.1.0"
  CodeReference = 21'i16
  CodeBaseplate = 19'i16
  CodeMass = 18'i16
  CodeGroundForce = 20'i16 ## the primary set's computed ground force
  CodeOtherBase = 256'i16  ## 256 + the column number for the other columns
  CodeGroundForceOther = 267'i16
  CardWidth = 76           ## parseSEG puts "C nn " before each textual header card of 80
  MaxSegdFileNumber = 16_777_215
  ConverterCodes = [21'i16, 19, 18, 20, 29, 28, 30, 33, 34, 35, 36, 1, 1]

type
  VibUnits* = enum
    vuCounts   ## raw counts, as recorded (default)
    vuPhysical ## pounds-force, g and percent, by `scaleOf` (needs `VibWriteOptions.scale`)

  VibTimeAxis* = enum
    vaTrigger
      ## t = 0 at the trigger frame: sample 0 is at minus the trigger frame times the
      ## interval. Falls back to `vaRecord` for a shot without a trigger frame.
    vaRecord ## t = 0 at the first frame: all frames from the start of the record

  VibWriteOptions* = object
    ## What the writers do with a shot.
    units*: VibUnits = vuCounts
    scale*: VibScale              ## the caller's constants for `vuPhysical` and `externalConverter`
    force*: bool = true           ## `vuPhysical`: accelerations as forces (lbf) rather than g
    channels*: set[VibChannel] = {low(VibChannel) .. high(VibChannel)}
    cycleValues*: bool = false    ## add the two per-cycle float channels
    groundForce*: set[VibSet] = {vsB}
      ## The computed traces: baseplate weight times baseplate plus reaction-mass
      ## weight times reaction mass, of each set named. In pounds-force with
      ## `vuPhysical`, else in pound-counts.
    primary*: VibSet = vsB ## the set that gets the standard codes 19, 18 and 20
    timeAxis*: VibTimeAxis = vaTrigger
    removeMean*: bool = false ## subtract each written column's mean (before scaling)
    record*: int64 = -1 ## the record number: -1 is the file name's number, else 1
    controllerSerial*: int64 = -1 ## the controller's serial, for the text header; -1 none
    segdReference*: SegdChannelType = sctSourceRefSweep
      ## The SEG-D channel type of the reference: `sctSourceRefSweep` (0x96) or
      ## `sctSourceRefPilot` (0x98).
    externalConverter*: bool = false
      ## Write the 13 traces of the external converter that some sites use, instead
      ## of the options above: the first `converterCut` frames dropped, every column's
      ## mean removed, its scales (`scale` has no built-in values: all four constants
      ## are the caller's) and its codes: 21 reference, 19 18 20 baseplate, mass and
      ## their sum of set A, 29 28 30 the same of set B, 33 torque motor, 34 valve, 35
      ## mass displacement, 36 drive, 1 and 1 the per-cycle values. The two sums are
      ## computed in pounds-force from the weights as the converter does. SEG-Y Rev 1
      ## only: codes 28 to 36 mean electromagnetic data in Rev 2.
    converterCut*: int = -1 ## frames the converter drops from the start (no built-in value)

  TraceKind = enum
    tkChannel
    tkCycle
    tkGround

  TracePlan = object
    kind: TraceKind
    channel: VibChannel
    cycle: VibCycleValue
    which: VibSet
    code: int16
    segd: SegdChannelType
    name: string

  OutTrace = object
    keys: TraceKeys
    samples: seq[float32]
    channelType: SegdChannelType

func segyTraceCode*(c: VibChannel; primary = vsB): int16 =
  ## The SEG-Y trace code of channel `c`: 21 for the reference, 19 and 18 for the
  ## baseplate and reaction-mass accelerations of the `primary` set, 256 plus the
  ## column number for every other channel.
  case c
  of vcReference: CodeReference
  of vcBaseplateA: (if primary == vsA: CodeBaseplate else: CodeOtherBase + 1)
  of vcMassA: (if primary == vsA: CodeMass else: CodeOtherBase + 2)
  of vcBaseplateB: (if primary == vsB: CodeBaseplate else: CodeOtherBase + 3)
  of vcMassB: (if primary == vsB: CodeMass else: CodeOtherBase + 4)
  else: CodeOtherBase + int16(ord(c))

func segyTraceCode*(v: VibCycleValue): int16 =
  ## 265 and 266: 256 plus the column number.
  CodeOtherBase + 9 + int16(ord(v))

func segyGroundForceCode*(which: VibSet; primary = vsB): int16 =
  ## 20 for the ground force of the `primary` set, 267 for the other's.
  if which == primary: CodeGroundForce else: CodeGroundForceOther

func segdChannelType*(c: VibChannel; primary = vsB;
    reference = sctSourceRefSweep): SegdChannelType =
  ## The SEG-D Rev 3 channel type: source reference sweep (0x96, or `reference`), base
  ## plate (0x95) and mass (0x99) of the `primary` set, valve (0x9B), excitation (0x9A)
  ## for the drive, other (0x97) for everything else.
  case c
  of vcReference: reference
  of vcBaseplateA: (if primary == vsA: sctSourceBasePlate else: sctSourceOther)
  of vcMassA: (if primary == vsA: sctSourceMass else: sctSourceOther)
  of vcBaseplateB: (if primary == vsB: sctSourceBasePlate else: sctSourceOther)
  of vcMassB: (if primary == vsB: sctSourceMass else: sctSourceOther)
  of vcValve: sctSourceValve
  of vcDrive: sctSourceExcitation
  else: sctSourceOther

proc fail(s: VibInfo; what: string) {.noinline, noreturn.} =
  raise newException(VibWriteError, "vib file " & (if s.nameNumber >= 0:
    $s.nameNumber else: "(unnumbered)") & ": " & what)

func positive(v: float64): bool =
  v > 0 and v < Inf

func recordOf(s: VibInfo; opts: VibWriteOptions): int64 =
  if opts.record >= 0: opts.record elif s.nameNumber >= 0: s.nameNumber else: 1

func hasTrigger(s: VibShot): bool =
  not s.triggerFrame.isNaN

func originFrame(s: VibShot; opts: VibWriteOptions): float64 =
  ## The frame that is t = 0.
  if opts.timeAxis == vaTrigger and s.hasTrigger: s.triggerFrame else: 0.0

type ClockTime = tuple[seconds: int64; nanosecond: int]

func clockOfZero(s: VibShot; opts: VibWriteOptions): ClockTime =
  ## The clock time of t = 0 in seconds and nanoseconds, without a float in between.
  let atTrigger = opts.timeAxis == vaTrigger and s.hasTrigger
  if s.triggerKnown and (atTrigger or s.hasTrigger):
    result = (posixSeconds(s.trigger), s.trigger.nanosecond)
    if not atTrigger:
      # t = 0 is the first frame: the trigger frame earlier than the trigger
      let back = int64(round(s.triggerFrame * s.sampleIntervalUs * 1000))
      let ns = int64(result.nanosecond) - back
      result.seconds += floorDiv(ns, 1_000_000_000'i64)
      result.nanosecond = int(floorMod(ns, 1_000_000_000'i64))
  else:
    result = (posixSeconds(s.start), 0)

func statusOf(code: int16): TraceStatus =
  ## The status the SEG-Y writer keeps a code for: it writes a code only when it says
  ## what the status says, and codes above 22 (21 is the last of Rev 1 that is not
  ## "optional use") have no status; they stay unknown so that the code reaches the file.
  case code
  of 18 .. 22: tsAuxiliary
  of 1: tsLive
  else: tsUnknown

func toTraceKeys*(s: VibShot; code: int16; channel: int; opts = VibWriteOptions();
    firstFrame = 0): TraceKeys =
  ## The keys of trace number `channel` (from 1) of `s` in parseSEG's shape: the record
  ## number, the trace `code`, its status (auxiliary for codes 18 to 22, unknown for the codes above
  ## 22, which have none: parseSEG writes a code only when it fits the status), the interval as `s` says, the
  ## time of sample `firstFrame` as `t0Ms` (see the module's text on the time axis)
  ## and the clock time of t = 0 as `time`. No position, line or station.
  result = initTraceKeys()
  result.record = float64(recordOf(s, opts))
  result.channel = float64(channel)
  result.traceCode = code
  result.status = statusOf(code)
  result.intervalUs = s.sampleIntervalUs
  result.t0Ms = (float64(firstFrame) - originFrame(s, opts)) * s.sampleIntervalUs / 1000
  let clock = clockOfZero(s, opts)
  result.time = float64(clock.seconds) + float64(clock.nanosecond) / 1e9

func meanOf[T](v: openArray[T]; first: int): float64 =
  var sum = 0.0
  for i in first ..< v.len:
    sum += float64(v[i])
  if v.len > first: sum / float64(v.len - first) else: 0.0

proc plan(s: VibShot; opts: VibWriteOptions; segd: bool): seq[TracePlan] =
  ## The traces to write, in order, with their codes.
  result = @[]
  if opts.externalConverter:
    # the converter's order: reference, baseplate, mass and ground force of set A,
    # the same of set B, torque motor, valve, mass displacement, drive, per-cycle values
    result.add TracePlan(kind: tkChannel, channel: vcReference, name: $vcReference)
    for c in [vcBaseplateA, vcMassA]:
      result.add TracePlan(kind: tkChannel, channel: c, name: $c)
    result.add TracePlan(kind: tkGround, which: vsA,
        name: "ground force, estimated, from accelerometer set A")
    for c in [vcBaseplateB, vcMassB]:
      result.add TracePlan(kind: tkChannel, channel: c, name: $c)
    result.add TracePlan(kind: tkGround, which: vsB,
        name: "ground force, estimated, from accelerometer set B")
    for c in [vcTorqueMotor, vcValve, vcMassStroke, vcDrive]:
      result.add TracePlan(kind: tkChannel, channel: c, name: $c)
    for v in VibCycleValue:
      result.add TracePlan(kind: tkCycle, cycle: v, name: $v)
    for i in 0 ..< result.len:
      result[i].code = ConverterCodes[i]
      result[i].segd = sctSourceOther
  else:
    for c in VibChannel:
      if c in opts.channels:
        result.add TracePlan(kind: tkChannel, channel: c,
          code: segyTraceCode(c, opts.primary),
          segd: segdChannelType(c, opts.primary, opts.segdReference), name: $c)
    if opts.cycleValues:
      for v in VibCycleValue:
        result.add TracePlan(kind: tkCycle, cycle: v, code: segyTraceCode(v),
          segd: sctSourceOther, name: $v)
    for which in [opts.primary, (if opts.primary == vsA: vsB else: vsA)]:
      if which in opts.groundForce:
        result.add TracePlan(kind: tkGround, which: which,
          code: segyGroundForceCode(which, opts.primary),
          segd: (if which == opts.primary: sctSourceSigEstimated else: sctSourceOther),
          name: "ground force, estimated, from accelerometer set " & $which)

proc checkOptions(s: VibShot; opts: VibWriteOptions; segd: bool; extHeader = false) =
  ## Everything that makes a shot or the options unwritable, said in our words.
  if s.len == 0:
    fail(s, "the shot holds no samples")
  for c in VibChannel:
    if s.data[c].len != s.len:
      fail(s, "the " & $c & " channel has " & $s.data[c].len & " samples, the " &
        "reference " & $s.len)
  for v in VibCycleValue:
    if s.cycle[v].len != s.len:
      fail(s, "the " & $v & " has " & $s.cycle[v].len & " samples, the reference " &
        $s.len)
  if not (s.sampleIntervalUs > 0 and s.sampleIntervalUs < Inf):
    fail(s, "the sample interval " & $s.sampleIntervalUs & " us is not positive")
  if opts.record < -1:
    fail(s, "the record number " & $opts.record & " is negative")
  if opts.timeAxis == vaTrigger and s.hasTrigger and not (s.triggerFrame >= 0 and
      s.triggerFrame <= float64(s.len)):
    fail(s, "the trigger frame " & $s.triggerFrame & " is outside the shot's " &
      $s.len & " frames")
  if opts.externalConverter:
    if segd:
      fail(s, "the external converter's traces are SEG-Y Rev 1 only: its trace " &
        "codes mean something else in SEG-D")
    if extHeader:
      fail(s, "the external converter's traces are SEG-Y Rev 1 only: its trace " &
        "codes 28 to 36 mean electric and magnetic field components in Rev 2")
    if opts.converterCut < 0 or opts.converterCut >= s.len:
      fail(s, "the converter's cut of " & $opts.converterCut & " frames is not " &
        "between 0 and the shot's " & $(s.len - 1) & " frames")
  if opts.externalConverter or opts.units == vuPhysical:
    try:
      for c in VibChannel:
        if opts.externalConverter or c in opts.channels:
          discard scaleOf(s, c, opts.scale, opts.force or opts.externalConverter)
    except ValueError as e:
      fail(s, e.msg & " (needed for " & (if opts.externalConverter:
        "the external converter's traces" else: "physical units") & ")")
  if opts.units == vuCounts and not opts.externalConverter:
    for which in opts.groundForce:
      let (wb, wm) = (float64(s.header.baseplateLb), float64(s.header.massLb))
      if not positive(wb) or not positive(wm):
        fail(s, "the header's weights are " & $wb & " and " & $wm & " lb: the " &
          "ground force of set " & $which & " cannot be computed")
  if opts.units == vuPhysical and not opts.externalConverter and opts.groundForce != {}:
    try:
      for which in opts.groundForce:
        discard scaleOf(s, (if which == vsA: vcBaseplateA else: vcBaseplateB),
          opts.scale, true)
        discard scaleOf(s, (if which == vsA: vcMassA else: vcMassB), opts.scale, true)
    except ValueError as e:
      fail(s, e.msg & " (needed for the ground force in pounds-force)")
  if plan(s, opts, segd).len == 0:
    fail(s, "no trace is chosen: channels, cycle values and ground forces are empty")
  if segd:
    if opts.segdReference notin {sctSourceRefSweep, sctSourceRefPilot}:
      fail(s, "the SEG-D reference channel type is 0x" &
        toHex(ord(opts.segdReference), 2) & ", not 0x96 or 0x98")
    if s.sampleIntervalUs != floor(s.sampleIntervalUs):
      fail(s, "the sample interval " & $s.sampleIntervalUs &
        " us is not a whole number of microseconds, which SEG-D needs")
    if recordOf(s, opts) > MaxSegdFileNumber:
      fail(s, "the record number " & $recordOf(s, opts) & " is above " &
        $MaxSegdFileNumber & ", the most SEG-D can number")

proc outTraces(s: VibShot; opts: VibWriteOptions; segd, exactTime: bool): seq[OutTrace] =
  ## The traces to write: keys, samples and SEG-D channel type of each.
  result = @[]
  let first = if opts.externalConverter: opts.converterCut else: 0
  let n = s.len - first
  let removeMean = opts.removeMean or opts.externalConverter
  let physical = opts.units == vuPhysical or opts.externalConverter
  let clock = clockOfZero(s, opts)
  var number = 0
  for p in plan(s, opts, segd):
    inc number
    var values = newSeq[float64](n)
    case p.kind
    of tkChannel:
      let m = if removeMean: meanOf(s.data[p.channel], first) else: 0.0
      let f = if physical: scaleOf(s, p.channel, opts.scale,
        opts.force or opts.externalConverter) else: 1.0
      for i in 0 ..< n:
        values[i] = f * (float64(s.data[p.channel][first + i]) - m)
    of tkCycle:
      let m = if removeMean: meanOf(s.cycle[p.cycle], first) else: 0.0
      for i in 0 ..< n:
        values[i] = float64(s.cycle[p.cycle][first + i]) - m
    of tkGround:
      let (bp, rm) = if p.which == vsA: (vcBaseplateA, vcMassA) else: (vcBaseplateB, vcMassB)
      let mb = if removeMean: meanOf(s.data[bp], first) else: 0.0
      let mm = if removeMean: meanOf(s.data[rm], first) else: 0.0
      # the weights, in pounds-force per count when physical, else the plain weights
      let wb = if physical: scaleOf(s, bp, opts.scale, true) else: float64(s.header.baseplateLb)
      let wm = if physical: scaleOf(s, rm, opts.scale, true) else: float64(s.header.massLb)
      for i in 0 ..< n:
        values[i] = wb * (float64(s.data[bp][first + i]) - mb) +
          wm * (float64(s.data[rm][first + i]) - mm)
    var k = toTraceKeys(s, p.code, number, opts, first)
    if segd: k.status = tsAuxiliary
    if exactTime:
      k.time = float64(clock.seconds)
    var v = newSeq[float32](n)
    for i in 0 ..< n:
      v[i] = float32(values[i])
    result.add OutTrace(keys: k, samples: v, channelType: p.segd)

template translating(s: VibInfo; what: string; body: untyped) =
  try:
    body
  except IOError:
    raise
  except VibWriteError:
    raise
  except CatchableError as e:
    fail(s, "cannot be written as " & what & ": " & e.msg)

proc writeSegyTraces*(w: var SeismicWriter; s: VibShot; opts = VibWriteOptions();
    extHeader = false) =
  ## Appends the traces of `s` to the open SEG-Y writer `w`: one record. `extHeader`
  ## must be set only for a Rev 2 or later writer (the default, false, suits every
  ## revision): the time's nanoseconds then go exactly into Trace Header Extension 1,
  ## which a Rev 1 or Rev 0 writer has not got (it would refuse them). Without it the
  ## time goes in as seconds with a fraction, as far as the format and the writer
  ## keep one. `writeSegy` sets it from its options. Raises `VibWriteError` (see the
  ## module's text), also for `externalConverter` with `extHeader` (Rev 2).
  checkOptions(s, opts, false, extHeader)
  var overrides: seq[HeaderOverride] = @[]
  if extHeader:
    overrides.add headerOverride("ext1.nanoseconds", clockOfZero(s, opts).nanosecond)
  for t in outTraces(s, opts, false, extHeader):
    translating(s, "SEG-Y"):
      w.writeTrace(t.keys, t.samples, overrides, t.channelType)

proc writeSegdTraces*(w: var SeismicWriter; s: VibShot; opts = VibWriteOptions()) =
  ## Appends the traces of `s` to the open SEG-D Rev 3 writer `w`, one record numbered
  ## by `opts.record` (records must not go backwards: sort shots by number). The time
  ## is kept to the microsecond, the resolution of SEG-D's timestamps. The writer makes one
  ## channel set per channel type, so the file's trace order is by type, not the order
  ## written. Raises
  ## `VibWriteError` (see the module's text), also for `externalConverter`.
  checkOptions(s, opts, true)
  for t in outTraces(s, opts, true, false):
    translating(s, "SEG-D"):
      w.writeTrace(t.keys, t.samples, [], t.channelType)

func wrapped(cards: var seq[string]; text: string) =
  ## Adds `text` as cards of at most `CardWidth` characters, broken at spaces.
  var rest = text
  while rest.len > CardWidth:
    var at = rest.rfind(' ', 0, CardWidth)
    if at <= 0: at = CardWidth
    cards.add rest[0 ..< at]
    rest = "  " & rest[at .. ^1].strip(trailing = false)
  cards.add rest

func unitOf(p: TracePlan; opts: VibWriteOptions): string =
  let physical = opts.units == vuPhysical or opts.externalConverter
  if not physical:
    return (if p.kind == tkGround: "pound-counts" else: "counts")
  case p.kind
  of tkCycle: "as stored"
  of tkGround: "lbf"
  of tkChannel:
    case p.channel
    of vcReference: "lbf"
    of vcBaseplateA, vcMassA, vcBaseplateB, vcMassB:
      if opts.force or opts.externalConverter: "lbf" else: "g"
    of vcTorqueMotor, vcValve, vcMassStroke: "percent"
    of vcDrive: "unit unknown"

proc textCards*(s: VibShot; opts: VibWriteOptions): seq[string] =
  ## The textual header cards of a SEG-Y file written from `s`: each at most 76
  ## characters (parseSEG adds a card number), longer lines continued on the next
  ## card. Raises `VibWriteError` for options `writeSegy` would refuse.
  checkOptions(s, opts, false)
  var cards: seq[string] = @[]
  cards.wrapped "vibrator controller .vib signature record"
  if opts.controllerSerial >= 0:
    cards.wrapped "controller serial " & $opts.controllerSerial &
      " (given by the caller, not in the file)"
  cards.wrapped "recording began " & $s.start & " (to the second), record " &
    $recordOf(s, opts) & ", sample interval " & $s.sampleIntervalUs & " us (assumed)"
  let axisTrigger = opts.timeAxis == vaTrigger and s.hasTrigger
  case s.triggerSource
  of tsNone:
    cards.wrapped "no trigger frame: t = 0 is the first frame"
  of tsEstimated:
    cards.wrapped "trigger frame " & formatFloat(s.triggerFrame, ffDecimal, 3) &
      " estimated from the reference (sweep fit, one sigma " &
      formatFloat(s.triggerSigmaFrames, ffDecimal, 3) & " frames)"
  of tsGiven:
    cards.wrapped "trigger frame " & formatFloat(s.triggerFrame, ffDecimal, 3) &
      " given by the caller"
  cards.wrapped (if axisTrigger: "t = 0 is the trigger: sample 0 is before it" else:
    "t = 0 is the first frame")
  if s.triggerKnown and (axisTrigger or s.hasTrigger):
    cards.wrapped "date/time is the trigger time" & (if axisTrigger: "" else:
      " minus the trigger frame") & ", given by the caller (from the .dat file)"
  else:
    cards.wrapped "date/time is the second the recording began, not the trigger"
  var number = 0
  for p in plan(s, opts, false):
    inc number
    cards.wrapped "trace " & $number & " " & p.name & " (" & unitOf(p, opts) & ")"
  if opts.externalConverter:
    cards.wrapped "converter-compatible traces: first " & $opts.converterCut &
      " frames dropped, mean removed"
    let k = opts.scale
    cards.wrapped "constants: acc " & $k.accMvPerCount & ", torque motor " &
      $k.torquePctPerCount & ", lvdt " & $k.lvdtFactor & ", drive " & $k.drivePerCount
  elif opts.units == vuPhysical:
    let k = opts.scale
    cards.wrapped "physical units; constants: acc " & $k.accMvPerCount &
      ", torque motor " & $k.torquePctPerCount & ", lvdt " & $k.lvdtFactor &
      ", drive " & $k.drivePerCount
    if opts.removeMean: cards.wrapped "mean removed"
  else:
    cards.wrapped (if opts.removeMean: "raw counts, mean removed" else: "raw counts")
  if opts.groundForce != {} or opts.externalConverter:
    cards.wrapped "ground force (computed, an estimate): baseplate weight x baseplate " &
      "acceleration + reaction-mass weight x reaction-mass acceleration"
  cards.wrapped "samples and signs as recorded: no polarity is changed"
  if not s.complete:
    cards.wrapped "incomplete recording: " & s.incompleteWhy
  if s.endsInSweep:
    cards.wrapped "the record ends inside the sweep: a stopped recording"
  cards.wrapped "written by parseSSVIB " & PackageVersion
  cards

proc finish(w: var SeismicWriter) =
  ## Closes the writer; its diagnostics, if any, become an `IOError`.
  var problems: seq[string] = @[]
  for d in w.close():
    problems.add d.msg
  if problems.len > 0:
    raise newException(IOError, problems.join("; "))

proc writeSegy*(s: VibShot; path: string; opts = SegyOutputOptions();
    vib = VibWriteOptions()) =
  ## Writes `s` as a SEG-Y file at `path`, replacing a file there: one record and the
  ## traces `vib` chooses (see the module's text). When `opts.text` is empty the
  ## textual header names the file, the time axis, the traces and the units. Raises
  ## `VibWriteError` (an `externalConverter` shot needs a Rev 1 `opts.revision`), and
  ## `IOError` with the writer's diagnostics when it reports any.
  checkOptions(s, vib, false, opts.revision.major >= 2)
  if vib.externalConverter and opts.revision.major != 1:
    fail(s, "the external converter's traces are SEG-Y Rev 1 only, not Rev " &
      $opts.revision.major)
  var o = opts
  if o.text.len == 0:
    o.text = textCards(s, vib)
  var w: SeismicWriter
  translating(s, "SEG-Y"):
    w = openSeismicWriter(path, o)
  w.writeSegyTraces(s, vib, opts.revision.major >= 2)
  translating(s, "SEG-Y"):
    w.finish()

proc writeSegd*(s: VibShot; path: string; vib = VibWriteOptions()) =
  ## Writes `s` as a SEG-D Rev 3 file at `path`, replacing a file there: one record,
  ## a channel set per channel type, 32-bit float samples, the clock time of t = 0 as
  ## the recording time. No free text: an incomplete recording is not flagged in the
  ## file. Raises `VibWriteError`, and `IOError` with the writer's diagnostics when it
  ## reports any.
  checkOptions(s, vib, true)
  var w: SeismicWriter
  translating(s, "SEG-D"):
    let clock = clockOfZero(s, vib)
    w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: s.sampleIntervalUs,
      numSamples: s.len, time: float64(clock.seconds) + float64(clock.nanosecond) / 1e9))
  w.writeSegdTraces(s, vib)
  translating(s, "SEG-D"):
    w.finish()

proc createExclusively(path: string): bool =
  ## Creates an empty file at `path` unless a file is there, in one step the file
  ## system makes atomic (`O_EXCL`, `CREATE_NEW`): false when `path` exists. Raises
  ## `OSError` for any other failure.
  when defined(windows):
    const alreadyExists = [80'i32, 183] # ERROR_FILE_EXISTS, ERROR_ALREADY_EXISTS
    let h = createFileW(newWideCString(path), GENERIC_WRITE, 0, nil, CREATE_NEW,
      FILE_ATTRIBUTE_NORMAL, 0)
    result = h != INVALID_HANDLE_VALUE
    if result:
      discard closeHandle(h)
    elif getLastError() notin alreadyExists:
      raiseOSError(osLastError())
  else:
    let fd = posix.open(path.cstring, O_CREAT or O_EXCL or O_WRONLY, Mode(0o644))
    result = fd >= 0
    if result:
      discard posix.close(fd)
    elif errno != EEXIST:
      raiseOSError(osLastError())

proc claimedPath(s: VibShot; serial: int64; folder, ext: string; overwrite: bool): string =
  ## The output path `folder / vibFileStem(s, serial) & ext`, with the folder made.
  ## Unless `overwrite`, the path is claimed by creating an empty file there,
  ## exclusively: of several writers after one name exactly one gets it, the others
  ## `VibWriteError`. (The winner's finished file replaces the empty one.)
  if serial < 0:
    fail(s, "the controller serial is " & $serial & ": the file name needs it (the " &
      "file does not hold it)")
  result = folder / (vibFileStem(s, serial) & ext)
  try:
    createDir(folder)
    if not overwrite and not createExclusively(result):
      fail(s, "the output file " & result & " exists and is not overwritten")
  except OSError as e:
    raise newException(IOError, "cannot create " & result & ": " & e.msg)

template writeClaimed(path: string; overwrite: bool; body: untyped) =
  ## Runs `body`, which writes `path`; a failure removes the empty file claimed for it.
  try:
    body
  except CatchableError:
    if not overwrite:
      try:
        removeFile(path)
      except OSError:
        discard # the first failure is the one to report
    raise

proc writeSegyTo*(s: VibShot; folder: string; serial: int64;
    opts = SegyOutputOptions(); vib = VibWriteOptions(); overwrite = false): string =
  ## `writeSegy` into `folder` (made when missing) under the name
  ## `vibFileStem(s, serial)` and `.sgy`; returns the path. The serial is the
  ## controller's: the file does not hold it, so the caller says it (and it goes into
  ## the text header). An existing file raises `VibWriteError` unless `overwrite`: the
  ## name is claimed exclusively (see `claimedPath`), so two writers after the same
  ## name cannot both succeed. While the file is being written an empty file stands at
  ## the name. A folder that cannot be made is an `IOError`.
  var v = vib
  v.controllerSerial = serial
  checkOptions(s, v, false, opts.revision.major >= 2)
  result = claimedPath(s, serial, folder, ".sgy", overwrite)
  writeClaimed(result, overwrite):
    s.writeSegy(result, opts, v)

proc writeSegdTo*(s: VibShot; folder: string; serial: int64; vib = VibWriteOptions();
    overwrite = false): string =
  ## `writeSegy`'s SEG-D twin: `writeSegd` into `folder` under `vibFileStem(s, serial)`
  ## and `.sgd`; returns the path. As `writeSegyTo`.
  checkOptions(s, vib, true)
  result = claimedPath(s, serial, folder, ".sgd", overwrite)
  writeClaimed(result, overwrite):
    s.writeSegd(result, vib)
