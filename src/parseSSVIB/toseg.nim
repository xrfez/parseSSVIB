## A decoded `.vib` shot as SEG-Y or SEG-D, through parseSEG's writers.
##
## `toTraceKeys` and `VibShot.samples` give the shape parseSEG's `writeTrace` takes;
## `writeSegyTraces` and `writeSegdTraces` hand every trace of a shot to an open
## writer, so several shots can go into one file, a record each. The `.vib` holds raw
## counts: the options of `VibWriteOptions` decide any scaling, mean removal and
## derived trace. Samples are written exactly as recorded and no option changes a
## sign.
##
## **Traces**, in `traceOrder` (default `voFile`): the chosen channels in file order,
## then the two per-cycle values (when asked), then the computed ground forces; or
## `voForces`, the roles in the `.dat` file's order (see `VibTraceOrder`). The set that
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
## **The shot block.** With `vendorLayout` (the default) every value of the record that
## is not a sample goes into the file too, as a 1280-byte block (`shotBlock`): in SEG-Y
## the binary stanza `parseSSVIB:Shot v1` of the extended textual header (card 37
## says so: `VibShotCardText`), in SEG-D the record's external header. It holds the
## decoded values (frame count, trigger and sweep fit, the time of t = 0), what the
## caller supplied (record, controller serial, paired `.dat` file number, trigger
## time), the options, a table of the traces written with the factor and mean that
## turn the counts into the samples, and the file's 47 header bytes verbatim. The vendor
## maps in `vendormaps/` decode it by field name through parseSEG. The traces are the
## same with the layout on or off; SEG-Y Rev 0 has no stanzas, so `writeSegy` refuses
## it with the layout. The block is big-endian, the header inside it the file's own
## bytes; polarity is as recorded. `addShotBlock` and `withVibShotCard` serve a writer
## of many shots.
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
  CodeGroundForce = 20'i16      ## the primary set's computed ground force
  CodeOtherBase = 256'i16       ## 256 + the column number for the other columns
  CodeGroundForceOther = 267'i16
  CardWidth = 76                ## parseSEG puts "C nn " before each textual header card of 80
  MaxSegdFileNumber = 16_777_215
  MaxSegyRecord = 2_147_483_647 ## the field is 32 bits
  MaxIntervalUs = 65535.0       ## the SEG-Y sample interval field is 16 bits
  ConverterCodes = [21'i16, 19, 18, 20, 29, 28, 30, 33, 34, 35, 36, 1, 1]
  ShotLayoutVersion = 1
  RecognitionCard = 37          ## the textual header card that names the shot stanza
  MaxTextCards = 38
  MaxTableTraces = 16           ## slots of the shot block's trace table
  TableAt = 320                 ## 0-based offset of the trace table
  TableEntryBytes = 48
  HeaderAt = 256                ## 0-based offset of the file's 47 header bytes
  WhyAt = 1088
  WhyBytes = 76
  None32 = 4_294_967_295'i64    ## the block's "none" for a 32-bit number

const
  VibShotCardText* = "PARSESSVIB SHOT STANZAS VERSION 1 (MAP PARSESSVIB-SEGY-1)"
    ## Card 37 of a SEG-Y file written with `vendorLayout`: what the vendor map
    ## `parseSSVIB-segy-1` recognises the file by.
  VibShotBlockBytes* = 1280 ## the size of the shot block (40 SEG-D blocks of 32 bytes)
  VibShotMagic* = "SSVIBSHT" ## its first eight bytes, which the SEG-D map recognises it by

type
  CloseDiagnostics = object of IOError
    ## The writer reported diagnostics when it closed: the file is complete.

  VibUnits* = enum
    vuCounts   ## raw counts, as recorded (default)
    vuPhysical ## pounds-force, g and percent, by `scaleOf` (needs `VibWriteOptions.scale`)

  VibTraceOrder* = enum
    voFile ## the channels in file order, then the per-cycle values, then the ground forces
    voForces
      ## by role: the reference; the primary set's reaction-mass acceleration, baseplate
      ## acceleration and ground force; the other set's the same three; torque motor,
      ## valve, mass displacement, drive; the per-cycle values. A trace that is not
      ## chosen is left out and the rest keep their order.

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
    traceOrder*: VibTraceOrder = voFile
      ## The order of the traces in the file. Trace codes, SEG-D channel numbers and
      ## samples follow their column; only the SEG-Y trace number (the position) moves.
      ## `externalConverter` has its own order and ignores this.
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
    vendorLayout*: bool = true
      ## Write every value of the record that is not a sample into the file as a shot
      ## block (`shotBlock`): in SEG-Y one binary stanza `parseSSVIB:Shot v1` in the
      ## extended textual header, found by card 37; in SEG-D the record's external
      ## header. False writes the plain file (the same traces). SEG-Y Rev 0 has no
      ## stanzas: `writeSegy` refuses it with `vendorLayout`.
    datFileNumber*: int64 = -1
      ## The file number of the `.dat` file of the same sweep, when the caller paired
      ## them: written into the block and the text header as given, never looked up.
      ## -1: not paired.

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

func statusOf(code: int16; major: int): TraceStatus =
  ## The status the SEG-Y writer keeps a code for: it writes a code only when it says
  ## what the status says (`segyStatus` of parseSEG). Rev 0 defines codes 1 to 8 only,
  ## so there every code but 1 stays unknown; from Rev 1 the codes 18 to 22 are
  ## auxiliary and the codes above 22 ("optional use") have no status. Unknown is what
  ## lets those codes reach the file.
  if major == 0:
    result = if code == 1: tsLive else: tsUnknown
  else:
    case code
    of 18 .. 22: result = tsAuxiliary
    of 1: result = tsLive
    else: result = tsUnknown

func toTraceKeys*(s: VibShot; code: int16; channel: int; opts = VibWriteOptions();
    firstFrame = 0; segyMajor = 1): TraceKeys =
  ## The keys of trace number `channel` (from 1) of `s` in parseSEG's shape: the record
  ## number, the trace `code`, its status for SEG-Y revision `segyMajor` (see `statusOf`: auxiliary for codes 18 to
  ## 22, unknown for the codes above 22, and in Rev 0 for every code but 1), the interval as `s` says, the
  ## time of sample `firstFrame` as `t0Ms` (see the module's text on the time axis)
  ## and the clock time of t = 0 as `time`. No position, line or station.
  result = initTraceKeys()
  result.record = float64(recordOf(s, opts))
  result.channel = float64(channel)
  result.traceCode = code
  result.status = statusOf(code, segyMajor)
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
    var channels: array[VibChannel, TracePlan]
    for c in VibChannel:
      channels[c] = TracePlan(kind: tkChannel, channel: c,
        code: segyTraceCode(c, opts.primary),
        segd: segdChannelType(c, opts.primary, opts.segdReference), name: $c)
    var cycles: seq[TracePlan] = @[]
    if opts.cycleValues:
      for v in VibCycleValue:
        cycles.add TracePlan(kind: tkCycle, cycle: v, code: segyTraceCode(v),
          segd: sctSourceOther, name: $v)
    var grounds: array[VibSet, TracePlan]
    for which in VibSet:
      grounds[which] = TracePlan(kind: tkGround, which: which,
        code: segyGroundForceCode(which, opts.primary),
        segd: (if which == opts.primary: sctSourceSigEstimated else: sctSourceOther),
        name: "ground force, estimated, from accelerometer set " & $which)
    let other = if opts.primary == vsA: vsB else: vsA
    case opts.traceOrder
    of voFile:
      for c in VibChannel:
        if c in opts.channels: result.add channels[c]
      result.add cycles
      for which in [opts.primary, other]:
        if which in opts.groundForce: result.add grounds[which]
    of voForces:
      if vcReference in opts.channels: result.add channels[vcReference]
      for which in [opts.primary, other]:
        let (bp, rm) = if which == vsA: (vcBaseplateA, vcMassA) else: (vcBaseplateB, vcMassB)
        if rm in opts.channels: result.add channels[rm]
        if bp in opts.channels: result.add channels[bp]
        if which in opts.groundForce: result.add grounds[which]
      for c in [vcTorqueMotor, vcValve, vcMassStroke, vcDrive]:
        if c in opts.channels: result.add channels[c]
      result.add cycles

type
  TraceUnit = enum
    tuCounts = "counts"
    tuPoundCounts = "pound-counts"
    tuLbf = "lbf"
    tuG = "g"
    tuPercent = "percent"
    tuAsStored = "as stored"
    tuUnknown = "unit unknown"

func unitOf(p: TracePlan; opts: VibWriteOptions): TraceUnit =
  let physical = opts.units == vuPhysical or opts.externalConverter
  if not physical:
    return (if p.kind == tkGround: tuPoundCounts else: tuCounts)
  case p.kind
  of tkCycle: tuAsStored
  of tkGround: tuLbf
  of tkChannel:
    case p.channel
    of vcReference: tuLbf
    of vcBaseplateA, vcMassA, vcBaseplateB, vcMassB:
      if opts.force or opts.externalConverter: tuLbf else: tuG
    of vcTorqueMotor, vcValve, vcMassStroke: tuPercent
    of vcDrive: tuUnknown

func columnsOf(p: TracePlan): tuple[a, b: VibChannel] =
  ## The baseplate and reaction-mass channels of a ground force trace.
  if p.which == vsA: (vcBaseplateA, vcMassA) else: (vcBaseplateB, vcMassB)

type Factors = tuple[f, m, f2, m2: float64]

proc factorsOf(s: VibShot; p: TracePlan; opts: VibWriteOptions): Factors =
  ## What turns the counts of trace `p` into its samples: `f * (c - m)` for a column
  ## `c`, `f * (bp - m) + f2 * (rm - m2)` for a ground force; `f2` and `m2` are NaN for a
  ## column.
  let first = if opts.externalConverter: opts.converterCut else: 0
  let removeMean = opts.removeMean or opts.externalConverter
  let physical = opts.units == vuPhysical or opts.externalConverter
  result = (1.0, 0.0, NaN, NaN)
  case p.kind
  of tkChannel:
    if removeMean: result.m = meanOf(s.data[p.channel], first)
    if physical:
      result.f = scaleOf(s, p.channel, opts.scale, opts.force or opts.externalConverter)
  of tkCycle:
    if removeMean: result.m = meanOf(s.cycle[p.cycle], first)
  of tkGround:
    let (bp, rm) = columnsOf(p)
    result.m = if removeMean: meanOf(s.data[bp], first) else: 0.0
    result.m2 = if removeMean: meanOf(s.data[rm], first) else: 0.0
    # the weights, in pounds-force per count when physical, else the plain weights
    result.f = if physical: scaleOf(s, bp, opts.scale, true) else: float64(s.header.baseplateLb)
    result.f2 = if physical: scaleOf(s, rm, opts.scale, true) else: float64(s.header.massLb)

func incompleteWords(why: string): string =
  ## `why` cut at the last space within 76 characters: the room the block has.
  if why.len <= WhyBytes:
    result = why
  else:
    let at = why.rfind(' ', 0, WhyBytes)
    result = if at > 0: why[0 ..< at] else: why[0 ..< WhyBytes]

proc checkBlockFields(s: VibShot; opts: VibWriteOptions) =
  ## The shot block holds 32-bit fields, a trigger time in bytes and a table of 16
  ## traces: refuse what does not fit, in words, rather than write a wrapped number.
  const hint = " (set vendorLayout to false to write the file without it)"
  for (name, v) in [("record number", recordOf(s, opts)), ("frame count", int64(s.len)),
      ("converter cut", int64(if opts.externalConverter: opts.converterCut else: 0)),
      ("tail", int64(s.tailBytes))]:
    if v < 0 or v > None32:
      fail(s, "the " & name & " " & $v & " does not fit the 32 bits of the shot block" & hint)
  for (name, v) in [("name number", s.nameNumber), ("controller serial", opts.controllerSerial),
      ("paired .dat file number", opts.datFileNumber)]:
    if v != -1 and (v < 0 or v >= None32):
      fail(s, "the " & name & " " & $v & " is not -1 or between 0 and " & $(None32 - 1) &
        ", which the shot block holds" & hint)
  if s.triggerKnown:
    let t = s.trigger
    if t.year notin 0 .. 65535 or t.month notin 0 .. 255 or t.day notin 0 .. 255 or
        t.hour notin 0 .. 255 or t.minute notin 0 .. 255 or t.second notin 0 .. 255 or
        t.nanosecond notin 0 .. 999_999_999:
      fail(s, "the trigger time " & $t & " does not fit the shot block" & hint)
  if plan(s, opts, false).len > MaxTableTraces:
    fail(s, "the shot block's trace table holds " & $MaxTableTraces & " traces" & hint)

proc checkOptions(s: VibShot; opts: VibWriteOptions; segd: bool; major = 1) =
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
  if opts.datFileNumber < -1:
    fail(s, "the paired .dat file number " & $opts.datFileNumber & " is negative")
  if s.hasTrigger and not (s.triggerFrame >= 0 and s.triggerFrame <= float64(s.len)):
    fail(s, "the trigger frame " & $s.triggerFrame & " is outside the shot's " &
      $s.len & " frames")
  if not s.triggerSigmaFrames.isNaN and not (s.triggerSigmaFrames >= 0 and
      s.triggerSigmaFrames <= 1e6):
    fail(s, "the trigger frame's uncertainty " & $s.triggerSigmaFrames &
      " is not between 0 and 1e6 frames")
  if s.sampleIntervalUs > MaxIntervalUs:
    fail(s, "the sample interval " & $s.sampleIntervalUs & " us is above " &
      $MaxIntervalUs & ", the most a SEG-Y interval field holds")
  if not segd and recordOf(s, opts) > MaxSegyRecord:
    fail(s, "the record number " & $recordOf(s, opts) & " is above " & $MaxSegyRecord &
      ", the most a SEG-Y field record number holds")
  if opts.externalConverter:
    if segd:
      fail(s, "the external converter's traces are SEG-Y Rev 1 only: its trace " &
        "codes mean something else in SEG-D")
    if major >= 2:
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
          "ground force of set " & $which & " cannot be computed (set groundForce = {} to " &
          "write without it)")
  if opts.units == vuPhysical and not opts.externalConverter and opts.groundForce != {}:
    try:
      for which in opts.groundForce:
        discard scaleOf(s, (if which == vsA: vcBaseplateA else: vcBaseplateB),
          opts.scale, true)
        discard scaleOf(s, (if which == vsA: vcMassA else: vcMassB), opts.scale, true)
    except ValueError as e:
      fail(s, e.msg & " (needed for the ground force in pounds-force; set groundForce = {} to write without it)")
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
  if opts.vendorLayout:
    checkBlockFields(s, opts)

proc outTraces(s: VibShot; opts: VibWriteOptions; segd, exactTime: bool;
    major = 1): seq[OutTrace] =
  ## The traces to write: keys, samples and SEG-D channel type of each.
  result = @[]
  let first = if opts.externalConverter: opts.converterCut else: 0
  let n = s.len - first
  let clock = clockOfZero(s, opts)
  var number = 0
  for p in plan(s, opts, segd):
    inc number
    let (f, m, f2, m2) = factorsOf(s, p, opts)
    var v = newSeq[float32](n)
    case p.kind
    of tkChannel:
      for i in 0 ..< n:
        v[i] = float32(f * (float64(s.data[p.channel][first + i]) - m))
    of tkCycle:
      for i in 0 ..< n:
        v[i] = float32(f * (float64(s.cycle[p.cycle][first + i]) - m))
    of tkGround:
      let (bp, rm) = columnsOf(p)
      for i in 0 ..< n:
        v[i] = float32(f * (float64(s.data[bp][first + i]) - m) +
          f2 * (float64(s.data[rm][first + i]) - m2))
    var k = toTraceKeys(s, p.code, number, opts, first, major)
    if segd: k.status = tsAuxiliary
    if exactTime:
      k.time = float64(clock.seconds)
    result.add OutTrace(keys: k, samples: v, channelType: p.segd)

proc putBe(b: var seq[byte]; at, width: int; v: uint64) =
  for i in 0 ..< width:
    b[at + i] = byte((v shr (8 * (width - 1 - i))) and 0xFF)

proc putFloat(b: var seq[byte]; at: int; v: float64) =
  putBe(b, at, 8, cast[uint64](v))

proc putId(b: var seq[byte]; at: int; v: int64) =
  ## A 32-bit number the caller may leave out: -1 is the block's "none".
  putBe(b, at, 4, if v < 0: uint64(None32) else: uint64(v))

proc buildBlock(s: VibShot; opts: VibWriteOptions): seq[byte] =
  ## The shot block's bytes, nothing checked (`checkOptions` and `checkBlockFields` did).
  result = newSeq[byte](VibShotBlockBytes)
  let first = if opts.externalConverter: opts.converterCut else: 0
  for i, c in VibShotMagic:
    result[i] = byte(c)
  putBe(result, 8, 2, ShotLayoutVersion)
  putBe(result, 10, 2, VibShotBlockBytes)
  putBe(result, 12, 4, uint64(recordOf(s, opts)))
  putId(result, 16, s.nameNumber)
  putId(result, 20, opts.controllerSerial)
  putId(result, 24, opts.datFileNumber)
  result[28] = byte(ord(s.complete))
  result[29] = byte(ord(s.endsInSweep))
  let plans = plan(s, opts, false)
  result[30] = byte(plans.len)
  result[31] = 0 # polarity: always as recorded
  putBe(result, 32, 4, uint64(s.len))
  putBe(result, 36, 4, uint64(first))
  putBe(result, 40, 4, uint64(s.len - first))
  putBe(result, 44, 4, uint64(s.tailBytes))
  putFloat(result, 48, s.sampleIntervalUs)
  putFloat(result, 56, (float64(first) - originFrame(s, opts)) * s.sampleIntervalUs / 1000)
  let clock = clockOfZero(s, opts)
  putBe(result, 64, 8, cast[uint64](clock.seconds))
  putBe(result, 72, 4, uint64(clock.nanosecond))
  result[76] = byte(ord(opts.timeAxis))
  result[77] = byte(if opts.timeAxis == vaTrigger and s.hasTrigger: 0 else: 1)
  result[78] = byte(ord(s.triggerSource))
  result[79] = byte(ord(s.triggerKnown))
  putFloat(result, 80, s.triggerFrame)
  putFloat(result, 88, s.triggerSigmaFrames)
  if s.triggerKnown:
    let t = s.trigger
    putBe(result, 96, 2, uint64(t.year))
    result[98] = byte(t.month)
    result[99] = byte(t.day)
    result[100] = byte(t.hour)
    result[101] = byte(t.minute)
    result[102] = byte(t.second)
    putBe(result, 104, 4, uint64(t.nanosecond))
  let w = s.sweep
  result[112] = byte(ord(w.valid))
  putBe(result, 116, 4, uint64(max(0, min(w.crossings, int(None32)))))
  putFloat(result, 120, w.triggerFrame)
  putFloat(result, 128, w.triggerSigmaFrames)
  putFloat(result, 136, w.startHz)
  putFloat(result, 144, w.rateHzPerS)
  putFloat(result, 152, w.residualCycles)
  putFloat(result, 160, w.rmsCycles)
  result[168] = byte(ord(opts.units))
  result[169] = byte(ord(opts.force))
  result[170] = byte(ord(opts.removeMean))
  result[171] = byte(ord(opts.cycleValues))
  for which in opts.groundForce:
    result[172] = result[172] or byte(1 shl ord(which))
  result[173] = byte(ord(opts.primary))
  result[174] = byte(ord(opts.traceOrder))
  result[175] = byte(ord(opts.externalConverter))
  result[176] = byte(ord(opts.segdReference))
  var bits = 0'u64
  for c in opts.channels:
    bits = bits or (1'u64 shl ord(c))
  putBe(result, 178, 2, bits)
  putFloat(result, 180, opts.scale.accMvPerCount)
  putFloat(result, 188, opts.scale.torquePctPerCount)
  putFloat(result, 196, opts.scale.lvdtFactor)
  putFloat(result, 204, opts.scale.drivePerCount)
  for i, v in s.header.raw:
    result[HeaderAt + i] = v
  for i, p in plans:
    let at = TableAt + TableEntryBytes * i
    let (f, m, f2, m2) = factorsOf(s, p, opts)
    result[at] = byte(i + 1)
    result[at + 1] = byte(case p.kind
      of tkChannel: ord(p.channel)
      of tkCycle: 9 + ord(p.cycle)
      of tkGround: 11 + ord(p.which))
    putBe(result, at + 2, 2, uint64(cast[uint16](p.code)))
    result[at + 4] = byte(ord(p.segd))
    result[at + 5] = byte(ord(unitOf(p, opts)))
    putFloat(result, at + 8, f)
    putFloat(result, at + 16, m)
    putFloat(result, at + 24, f2)
    putFloat(result, at + 32, m2)
  let why = incompleteWords(s.incompleteWhy)
  for i in 0 ..< WhyBytes: # blanks, so that the map's `(trim right)` gives the words alone
    result[WhyAt + i] = if i < why.len: byte(why[i]) else: 0x20

proc shotBlock*(s: VibShot; opts: VibWriteOptions): seq[byte] =
  ## The 1280-byte shot block of `s` written with `opts`: every value of the record that
  ## is not a sample (the decoded frame count, trigger and sweep fit, the caller's record
  ## number, serial and `.dat` file number, the options), a table of the traces written
  ## (what each is, its codes, unit, factor and mean) and the file's 47 header bytes,
  ## verbatim. Big-endian, laid out as the vendor maps in `vendormaps/` say (byte 1
  ## `VibShotMagic`, layout version 1, block length 1280). An integer that is not known
  ## is 0xFFFFFFFF, a float NaN, the trigger time zeros (with `triggerKnown` 0); unused
  ## bytes are 0, and the 76 of `incompleteWhy` are blanks after the words, cut at the
  ## last space. The samples are not in it, and no sign is changed anywhere. Raises
  ## `VibWriteError` for options `writeSegy` refuses or a value the block cannot hold.
  checkOptions(s, opts, false)
  checkBlockFields(s, opts)
  buildBlock(s, opts)

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
    extHeader = false; major = 1) =
  ## Appends the traces of `s` to the open SEG-Y writer `w`: one record. `major` is the
  ## writer's SEG-Y revision (0, 1 or 2; `extHeader` means 2): Rev 0 knows trace codes 1
  ## to 8 only, and the traces' status is set so that parseSEG still keeps the codes.
  ## `extHeader`
  ## must be set only for a Rev 2 or later writer (the default, false, suits every
  ## revision): the time's nanoseconds then go exactly into Trace Header Extension 1,
  ## which a Rev 1 or Rev 0 writer has not got (it would refuse them). Without it the
  ## time goes in as seconds with a fraction, as far as the format and the writer
  ## keep one. `writeSegy` sets it from its options. Raises `VibWriteError` (see the
  ## module's text), also for `externalConverter` with `extHeader` (Rev 2).
  let rev = if extHeader: max(major, 2) else: major
  checkOptions(s, opts, false, rev)
  var overrides: seq[HeaderOverride] = @[]
  if extHeader:
    overrides.add headerOverride("ext1.nanoseconds", clockOfZero(s, opts).nanosecond)
  for t in outTraces(s, opts, false, extHeader, rev):
    translating(s, "SEG-Y"):
      w.writeTrace(t.keys, t.samples, overrides, t.channelType)

proc writeSegdTraces*(w: var SeismicWriter; s: VibShot; opts = VibWriteOptions()) =
  ## Appends the traces of `s` to the open SEG-D Rev 3 writer `w`, one record numbered
  ## by `opts.record` (records must not go backwards: sort shots by number). The time
  ## is kept to the microsecond, the resolution of SEG-D's timestamps. With
  ## `vendorLayout` the first trace of the record carries the shot block as the
  ## record's external header. The writer makes one
  ## channel set per channel type, so the file's trace order is by type, not the order
  ## written. Raises
  ## `VibWriteError` (see the module's text), also for `externalConverter`.
  checkOptions(s, opts, true)
  var block0: seq[byte] = @[]
  if opts.vendorLayout:
    block0 = buildBlock(s, opts)
  var first = true
  for t in outTraces(s, opts, true, false):
    translating(s, "SEG-D"):
      w.writeTrace(t.keys, t.samples, [], t.channelType,
        externalHeader = (if first: block0 else: @[]))
    first = false

func wrapped(cards: var seq[string]; text: string) =
  ## Adds `text` as cards of at most `CardWidth` characters, broken at spaces.
  var rest = text
  while rest.len > CardWidth:
    var at = rest.rfind(' ', 0, CardWidth)
    if at <= 2: at = CardWidth # no space, or only the continuation's own
    cards.add rest[0 ..< at]
    rest = "  " & rest[at .. ^1].strip(trailing = false)
  cards.add rest

func withVibShotCard*(cards: seq[string]): seq[string] =
  ## `cards` as the first 36 cards (blank ones added, those beyond the 36th dropped)
  ## and card 37 `VibShotCardText`, which a SEG-Y file with shot stanzas must carry.
  result = cards
  if result.len > RecognitionCard - 1:
    result.setLen(RecognitionCard - 1)
  while result.len < RecognitionCard - 1:
    result.add ""
  result.add VibShotCardText

proc textCards*(s: VibShot; opts: VibWriteOptions): seq[string] =
  ## The textual header cards of a SEG-Y file written from `s`: each at most 76
  ## characters (parseSEG adds a card number), longer lines continued on the next
  ## card, at most 38 cards; with `vendorLayout` the first 36 and card 37
  ## (`withVibShotCard`). Raises `VibWriteError` for options `writeSegy` would refuse.
  checkOptions(s, opts, false)
  var cards: seq[string] = @[]
  cards.wrapped "vibrator controller .vib signature record"
  if opts.controllerSerial >= 0:
    cards.wrapped "controller serial " & $opts.controllerSerial &
      " (given by the caller, not in the file)"
  if opts.datFileNumber >= 0:
    cards.wrapped "paired with .dat file number " & $opts.datFileNumber &
      " (given by the caller)"
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
    cards.wrapped "trace " & $number & " " & p.name & " (" & $unitOf(p, opts) & ")"
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
  if cards.len > MaxTextCards: cards.setLen(MaxTextCards)
  if opts.vendorLayout:
    cards = withVibShotCard(cards)
  cards

proc finish(w: var SeismicWriter) =
  ## Closes the writer; its diagnostics, if any, become an `IOError`.
  var problems: seq[string] = @[]
  for d in w.close():
    problems.add d.msg
  if problems.len > 0:
    raise newException(CloseDiagnostics, problems.join("; "))

proc addShotBlock*(w: var SeismicWriter; s: VibShot; opts = VibWriteOptions()) =
  ## Adds the shot block of `s` to the open SEG-Y writer `w` as the stanza
  ## `parseSSVIB:Shot v1`. Call it for every shot to go into the file, before the first
  ## trace of any (parseSEG takes stanzas only then), and open the writer with a text
  ## header that holds card 37 (`withVibShotCard`, which `textCards` applies with
  ## `vendorLayout`). `writeSegy` does all of it for one shot. Raises `VibWriteError`,
  ## also for parseSEG's refusals (after the first trace, a SEG-D writer, Rev 0).
  let block0 = shotBlock(s, opts)
  translating(s, "SEG-Y"):
    w.addStanza("parseSSVIB", "Shot v1", block0)

proc writeSegy*(s: VibShot; path: string; opts = SegyOutputOptions();
    vib = VibWriteOptions()) =
  ## Writes `s` as a SEG-Y file at `path`, replacing a file there: one record and the
  ## traces `vib` chooses (see the module's text). When `opts.text` is empty the
  ## textual header names the file, the time axis, the traces and the units. Raises
  ## `VibWriteError` (an `externalConverter` shot needs a Rev 1 `opts.revision`), and
  ## `IOError` with the writer's diagnostics when it reports any.
  checkOptions(s, vib, false, int(opts.revision.major))
  if vib.externalConverter and opts.revision.major != 1:
    fail(s, "the external converter's traces are SEG-Y Rev 1 only, not Rev " &
      $opts.revision.major)
  if vib.vendorLayout and opts.revision.major < 1:
    fail(s, "the vendor layout needs SEG-Y Rev 1 or later (Rev 0 has no extended " &
      "textual header): choose a later revision or set vendorLayout to false")
  var o = opts
  if o.text.len == 0:
    o.text = textCards(s, vib)
  elif vib.vendorLayout:
    o.text = withVibShotCard(o.text)
  var w: SeismicWriter
  translating(s, "SEG-Y"):
    w = openSeismicWriter(path, o)
  if vib.vendorLayout:
    w.addShotBlock(s, vib)
  w.writeSegyTraces(s, vib, opts.revision.major >= 2, int(opts.revision.major))
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
  except CloseDiagnostics:
    raise # the finished file stands: only a failed write leaves nothing behind
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
  checkOptions(s, v, false, int(opts.revision.major))
  result = claimedPath(s, serial, folder, ".sgy", overwrite)
  writeClaimed(result, overwrite):
    s.writeSegy(result, opts, v)

proc writeSegdTo*(s: VibShot; folder: string; serial: int64; vib = VibWriteOptions();
    overwrite = false): string =
  ## `writeSegy`'s SEG-D twin: `writeSegd` into `folder` under `vibFileStem(s, serial)`
  ## and `.sgd`; returns the path. As `writeSegyTo`.
  var v = vib
  v.controllerSerial = serial
  checkOptions(s, v, true)
  result = claimedPath(s, serial, folder, ".sgd", overwrite)
  writeClaimed(result, overwrite):
    s.writeSegd(result, v)
