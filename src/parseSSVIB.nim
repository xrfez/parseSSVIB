## parseSSVIB reads a vibrator controller's `.vib` signature files and writes them as
## SEG-Y or SEG-D through parseSEG.
##
## `readVib` and `parseVib` decode a file into a `VibShot`: the nine 16-bit channels
## of raw counts (reference, two accelerometer sets, torque-motor current, valve and
## mass displacement, drive), the two per-cycle float channels, the start time and
## the numbers of the header. The trigger is estimated from the reference
## (`fitSweep`). `looksLikeVib` and `vibKind` tell such a file from another by its
## first bytes. `writeSegy`, `writeSegd` and the `To` forms hand the shot to
## parseSEG's writers; `scaleOf`, `physical` and `groundForce` turn counts into
## physical values with constants the caller gives.
##
## The decoder (`parseSSVIB/decode`, `types`, `sweep`, `units`) needs only the
## standard library; only `parseSSVIB/toseg` imports parseSEG.

import parseSSVIB/[types, sweep, decode, units, toseg]
export types, sweep, decode, units, toseg
