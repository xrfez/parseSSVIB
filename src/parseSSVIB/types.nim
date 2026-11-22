## The types of a decoded `.vib` signature file: the eleven channels, the header's
## numbers, the sweep fit and the errors the decoder raises.

type
  VibChannel* = enum
    ## The nine 16-bit channels, in file order (frame columns 0 to 8). The names are
    ## what the channels are most probably; the evidence is in the module docs of
    ## `parseSSVIB/decode`.
    vcReference = "reference"
    vcBaseplateA = "baseplate acceleration, set A"
    vcMassA = "reaction-mass acceleration, set A"
    vcBaseplateB = "baseplate acceleration, set B"
    vcMassB = "reaction-mass acceleration, set B"
    vcTorqueMotor = "torque-motor current"
    vcValve = "valve displacement"
    vcMassStroke = "mass displacement"
    vcDrive = "drive output (probable)"

  VibCycleValue* = enum
    ## The two float channels (frame columns 9 and 10), which the controller updates
    ## once per sweep cycle.
    vvDriveRatio = "per-cycle value 1 (tracks drive / ground force)"
    vvCycle2 = "per-cycle value 2 (meaning unknown)"

  VibSet* = enum
    ## The two accelerometer sets. Both sets are measurements of the vibrator's
    ## motion through two acquisition paths; which path runs through the controller's
    ## electronics is not known.
    vsA = "A" ## accelerometer set A: the set the controller's QC report follows (probable)
    vsB = "B" ## accelerometer set B: the set the `.dat` file records

  VibKind* = enum
    vkNotVib    ## not "VIB", or shorter than 4 bytes
    vkSignature ## byte 3 is 11: the record this library decodes
    vkOther     ## "VIB" with another byte 3 (6 is known): a different file, not decoded

  VibFormatError* = object of CatchableError
    ## Not a `.vib` signature record, or bytes that break the format. The message is
    ## plain words.
    offset*: int64 = -1 ## byte offset of the problem in the file; -1 if none

  VibIncompleteError* = object of VibFormatError
    ## A partial last frame (a copy cut short), a header cut short, or no frame at all.

  VibWriteError* = object of CatchableError
    ## A shot or an option that the SEG-Y or SEG-D writer cannot take.

  VibTime* = object
    ## A time of day, UTC. `nanosecond` is 0 for the header's start time, which is
    ## stored to the second.
    year*, month*, day*, hour*, minute*, second*: int
    nanosecond*: int

  VibHeader* = object
    ## The header's numbers as stored: `float32`, not checked (NaN stays NaN).
    channelsPerFrame*: int          ## byte 3: 11
    valveCal*, massCal*: float32    ## LVDT calibrations, bytes 4 to 11
    unknown12*, unknown16*: float32 ## bytes 12 to 19: meaning unknown
    holdDownLb*: float32            ## bytes 20 to 23: the hold-down weight, pounds
    sensitivity1*, sensitivity2*: float32
      ## bytes 24 to 31: the accelerometer sensitivity, twice; which sensor each
      ## belongs to is unknown (equal in every file seen)
    baseplateLb*, massLb*: float32 ## bytes 32 to 39: the baseplate and reaction-mass weights
    raw*: array[47, byte] ## the 47 header bytes

  VibSweep* = object
    ## The linear-sweep fit of the reference (`fitSweep`). `valid` is false for a
    ## pulse, a non-linear sweep, a reference with fewer than 200 zero crossings or a
    ## residual above 0.05 cycles; the numbers are then NaN.
    valid*: bool
    triggerFrame*: float64 = NaN ## fractional frame of the sweep's phase origin
    triggerSigmaFrames*: float64 = NaN
      ## The formal one-sigma uncertainty of `triggerFrame`, from the fit's residuals
      ## (frames). It leaves out errors of the model itself (a sweep that is not
      ## exactly linear).
    startHz*, rateHzPerS*: float64 = NaN
    residualCycles*: float64 = NaN ## the largest phase residual of any crossing
    rmsCycles*: float64 = NaN ## the rms of the phase residuals
    crossings*: int ## zero crossings found in the reference

  VibTriggerSource* = enum
    tsNone      ## no trigger frame
    tsEstimated ## from the reference (the sweep fit)
    tsGiven     ## set by the caller (`setTrigger`)

  VibInfo* = object of RootObj
    ## Everything but the samples: what a file list shows (`readVibInfo`).
    header*: VibHeader
    start*: VibTime         ## the second the recording began (not the trigger)
    frames*: int            ## whole frames present
    tailBytes*: int         ## bytes after the last whole frame (0 in every file seen)
    complete*: bool         ## `tailBytes` is 0
    incompleteWhy*: string  ## plain words when not `complete`
    sampleIntervalUs*: float64 = 500
      ## The interval of the frames. The file does not state it: this is what the
      ## caller said (500 by default).
    nameNumber*: int64 = -1 ## the digits of a `NNNN.VIB` file name (path readers only)

  VibShot* = object of VibInfo
    ## One decoded `.vib` file: its `VibInfo` and the samples.
    data*: array[VibChannel, seq[int16]]       ## equal lengths, raw counts as recorded
    cycle*: array[VibCycleValue, seq[float32]] ## as stored
    sweep*: VibSweep                           ## the fit of the reference (invalid when not run)
    triggerFrame*: float64 = NaN
      ## The trigger as a fractional frame: the sweep fit's estimate
      ## (`triggerSource` `tsEstimated`, its uncertainty in `triggerSigmaFrames`) or
      ## the caller's (`tsGiven`); NaN for `tsNone`.
    triggerSigmaFrames*: float64 = NaN ## NaN when the caller gave the frame
    triggerSource*: VibTriggerSource
    trigger*: VibTime ## UTC, valid only when `triggerKnown`
    triggerKnown*: bool ## the caller gave the trigger time (from a `.dat`)
    endsInSweep*: bool ## the record stops inside the sweep (a stopped recording)

  VibScale* = object
    ## The per-count constants of the external converter. There are no built-in
    ## values: the caller says them. NaN means not given; a value that needs it raises
    ## `ValueError`.
    accMvPerCount*: float64 = NaN ## `g = counts * this / sensitivity`
    torquePctPerCount*: float64 = NaN ## torque-motor current, percent per count
    lvdtFactor*: float64 = NaN ## valve and mass displacement: `% = counts * this / calibration`
    drivePerCount*: float64 = NaN ## the drive output, per count (its unit is unknown)

const
  VibHeaderBytes* = 47
  VibFrameBytes* = 26
  VibSignatureKind* = 11 ## the value of byte 3 of the records this library decodes
  MaxVibBytes* = 64 shl 20 ## larger files are refused before reading
