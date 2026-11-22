# parseSSVIB

Reads a vibrator controller's `.vib` signature files and writes them as SEG-Y or SEG-D
through [parseSEG](https://github.com/xrfez/parseSEG). MIT licence.

A signature file is a 47-byte header (the weights and calibrations of the vibrator, the
second the recording began) and then fixed 26-byte frames to its end, little-endian,
one frame per 0.5 ms: no blocks, no checksums, no sample count. A frame holds nine
16-bit channels and two `float32` values:

| channel | what it is | SEG-Y code | SEG-D type |
|---|---|---|---|
| `vcReference` | the reference (pilot) | 21 | 0x96 |
| `vcBaseplateA`, `vcMassA` | baseplate and reaction-mass acceleration, set A | 257, 258 (19, 18 if `primary = vsA`) | 0x97 (0x95, 0x99) |
| `vcBaseplateB`, `vcMassB` | the same, set B | 19, 18 (259, 260 if `primary = vsA`) | 0x95, 0x99 |
| `vcTorqueMotor` | torque-motor current | 261 | 0x97 |
| `vcValve` | valve displacement | 262 | 0x9B |
| `vcMassStroke` | mass displacement | 263 | 0x97 |
| `vcDrive` | drive output (probable) | 264 | 0x9A |
| `vvDriveRatio`, `vvCycle2` | two values the controller updates once per sweep cycle (optional) | 265, 266 | 0x97 |
| computed | ground force of a set: baseplate weight x baseplate + reaction-mass weight x reaction mass (an estimate) | 20 (the primary set's), 267 | 0x93, 0x97 |

The two accelerometer sets are two acquisition paths of the vibrator's motion; which
path runs through the controller's electronics is not known. Set A is the set the
controller's QC report follows (probable); set B is the set the `.dat` file of the
same sweep records, and is the default primary set. Codes above 22 have no status in
SEG-Y, so those traces carry status unknown (parseSEG then keeps the code).

**Polarity.** Samples and the computed ground force are written exactly as recorded:
no option flips or aligns a sign. A ground force here is computed, and is named as
computed and by its formula.

- `parseSSVIB/decode`, `types`, `sweep` and `units` need only the standard library.
  `parseSSVIB/toseg` is the only module that imports parseSEG.
- The decoder refuses any byte string that is not a signature record with a
  `VibFormatError` that says what is wrong. It never raises a `Defect`, never reads
  outside its input and sizes its allocation from the input's length: the file states no
  count.

## Example

```nim
import parseSSVIB

let shot = readVib("0001.VIB")       # VibFormatError, VibIncompleteError, IOError
echo shot.start, " (the second the recording began), ", shot.len, " frames"
echo shot.triggerSource, " ", shot.triggerFrame, " +- ", shot.triggerSigmaFrames
let reference = shot.samples(vcReference)  # seq[float32], exact for 16-bit counts
let gf = groundForce(shot)                 # set B, pound-counts: weights x counts

shot.writeSegy("shot.sgy")                 # trigger at t = 0, counts, codes above
shot.writeSegd("shot.sgd")
let path = shot.writeSegyTo("out", serial = 42)  # out/0042_20010203T040506Z_vib.sgy
```

## What the file does not say

| Choice | Default | Where to change it |
|---|---|---|
| Sample interval | 500 us: not in the file (every file seen) | `sampleIntervalUs` of the readers |
| Trigger | estimated from the reference (needs a linear sweep with its phase origin at the trigger; a pulse or a non-linear sweep gives none) | `findTrigger`, `setTrigger(shot, time, frame)` |
| Time axis | t = 0 at the trigger frame, pre-trigger negative | `VibWriteOptions.timeAxis = vaRecord`: all frames from the first, t = 0 at the first |
| Clock time | the second the recording began | `setTrigger` with the exact trigger time (from the `.dat` file of the sweep) |
| Controller serial | not in the file | `serial` of `writeSegyTo` / `writeSegdTo`, `VibWriteOptions.controllerSerial`; `serialFromPath` reads it from the folder layout `<serial>/<date>/NNNN.VIB` (a folder named by exactly four digits) |
| File stem | `0042_20010203T040506Z_vib` (the start second); with the exact trigger known `0042_20010203T040506.789000000Z_vib` (the `.dat` stem plus `_vib`) | `vibFileStem` |
| Units | raw counts | `VibWriteOptions.units = vuPhysical` with `scale` (all constants are the caller's) |
| External converter's 13 traces | off | `VibWriteOptions.externalConverter` with `scale` and `converterCut` (no built-in values; SEG-Y Rev 1 only) |

The time of sample 0 is minus the trigger frame times the interval. What a file holds
of it: SEG-Y Rev 1 and Rev 2 store it as a 16-bit delay with a scalar, in steps of
0.01 ms up to 327.67 ms of pre-trigger and 0.1 ms beyond (a trigger frame above 655 at
500 us), so the stored time is up to 0.05 ms (0.1 frame) off; Rev 0 stores whole
milliseconds (up to 0.5 ms off); SEG-D stores microseconds. The text header holds the
exact trigger frame (three decimals) and says where it came from. `triggerWindow` gives
the POSIX seconds a paired `.dat` file's trigger must lie in.

The trigger estimate comes with `triggerSigmaFrames`, the fit's formal error. It does not
include a constant offset of up to about 0.02 frames that a controller's reference can
have against the trigger: the scatter to expect is wider than the stated sigma. The fit
assumes a clean reference at full scale and a sweep of a few hundred crossings; a short
logarithmic sweep can pass its checks and still be a few frames off.

**SEG-Y Rev 0** knows trace codes 1 to 8 only. The writers keep the codes in the file
anyway (the traces' status is unknown, which parseSEG then writes together with the
code), but a reader that checks codes against Rev 0 sees codes above 8 as undefined; the
delay is whole milliseconds, and `externalConverter` is refused.

**SEG-D** writes one channel set per channel type, and several traces share a type
(0x97 is used for the second accelerometer set, torque motor, mass displacement and the
per-cycle values), so a reader that goes by sets sees the traces grouped by type. The
channel number of each trace (1, 2, ... in the order written) identifies the column.

## Many files

- `readVibInfo(path)` reads 47 bytes and gives a `VibInfo`: header, start time, frame
  count, complete or not. `parseVibInfo(head, fileSize)` does the same for bytes you hold.
- `readVibInto(path, shot, buffer)` and `decodeInto(shot, bytes)` decode into a shot and a
  buffer you keep: after the first files they allocate nothing. No global state: use
  them from several threads, each with its own shot and buffer.
- `looksLikeVib(first47Bytes)` and `vibKind(first4Bytes)` tell a signature record from
  another file; the one other kind seen (6 values per record) is `vkOther`.
- `writeSegyTo` and `writeSegdTo` claim the file name exclusively.

`nim bench` prints files per second and MB/s for the info, the decode and the decode
with the trigger fit.

## Errors

`VibFormatError` (and its child `VibIncompleteError`: a cut header, no frame, a partial
frame) for bad input, `IOError` for the file system, `ValueError` for an interval that is
not positive and finite or a constant that is missing, and `VibWriteError` for a shot or
an option a writer cannot take, in plain words.

## Developing

Dependencies are pinned in `atlas.lock`. Fill `deps/` with `atlas rep atlas.lock`, or
without Atlas with `nim depsSync`; `nim depsStatus` and `nim depsCheck` compare `deps/`,
`nim.cfg` and the lock. An existing working copy of parseSEG can be linked as `deps/parseSEG`.

```sh
nim test            # every tests/t*.nim, one process each (debug)
nim testRelease     # the same in -d:release and -d:danger
nim bench           # decoder speed on synthetic files
nim docs            # API docs into htmldocs/
```

The tests use synthetic files written by `tests/vibsynth.nim` with made-up numbers: the
library reads this format and does not write it. `tests/fuzz/fuzzparse.nim` is a
libFuzzer target for `parseVib`.
