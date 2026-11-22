# Changelog

## 0.1.0 - Unreleased

- Decoder for a vibrator controller's `.vib` signature files: `parseVib`, `readVib`,
  `decodeInto` and `readVibInto` (a shot and a buffer kept between files),
  `parseVibInfo` and `readVibInfo` (the header and the frame count from 47 bytes, for
  file lists), `vibKind`, `looksLikeVib`, `vibFileStem`, `serialFromPath`.
- Channels: reference, two accelerometer sets (baseplate and reaction mass), torque-motor
  current, valve and mass displacement, drive (raw counts) and the two per-cycle float
  values, exactly as recorded.
- Refuses every damaged file with `VibFormatError` or `VibIncompleteError`; empty files
  and the other kind of `.vib` file (6 values per record) are recognised and refused.
  A copy cut short can be read with `allowIncomplete`.
- The trigger estimated from the reference: `fitSweep` fits a linear sweep to its zero
  crossings and gives the trigger frame with its formal uncertainty, the start frequency
  and the rate; `endsInSweep` flags a stopped recording; `setTrigger` and
  `triggerWindow` take and give the numbers for pairing with the `.dat` file of the sweep.
- `scaleOf`, `physical` and `groundForce`: counts to pounds-force, g and percent from
  the header and constants the caller gives (no built-in constant), and the computed
  ground force of an accelerometer set.
- Writers for SEG-Y and SEG-D through parseSEG: `writeSegy`, `writeSegd`, `writeSegyTo`,
  `writeSegdTo`, `writeSegyTraces`, `writeSegdTraces`, with options for units, mean
  removal, channels, per-cycle values, ground forces, the time axis (trigger at t = 0,
  or all frames from the first) and the external converter's 13 traces.
- Samples and the computed ground force are written as recorded; no option changes a
  sign.
- Benchmark in `bench/`, a libFuzzer target in `tests/fuzz/`.
