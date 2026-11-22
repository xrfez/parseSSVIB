## Benchmark of the decoder: files per second and MB per second for reading the info of
## a file (`readVibInfo`: 47 bytes), for decoding all of it without the sweep fit
## (`readVibInto` with one shot and one buffer kept between files, `findTrigger =
## false`) and with it (the trigger estimated from the reference).
##
##   nim c -d:release -r bench/bench.nim                 # synthetic files, 400 of them
##   nim c -d:release -r bench/bench.nim 2000            # this many synthetic files
##   nim c -d:release -r bench/bench.nim <folder>...     # every .vib below the folders
##
## Each pass runs twice and the second is reported, so the files are in the system's
## cache and the numbers are the decoder's, not the disk's. MB/s counts the size of the
## files, whether or not the pass reads all of it. Prints counts and rates only.

import std/[algorithm, monotimes, os, strutils, times]
import parseSSVIB/[decode, types]
import ../tests/vibsynth

proc megabytes(bytes: int64): float64 =
  float64(bytes) / 1e6

proc rate(what: string; files, refused: int; bytes: int64; took: Duration) =
  let s = max(float64(took.inNanoseconds) / 1e9, 1e-9)
  echo what.alignLeft(22), files, " files in ", formatFloat(s, ffDecimal, 3), " s: ",
    formatFloat(float64(files) / s, ffDecimal, 0), " files/s, ",
    formatFloat(megabytes(bytes) / s, ffDecimal, 0), " MB/s", (if refused > 0:
    ", " & $refused & " refused" else: "")

proc run(paths: seq[string]) =
  var bytes = 0'i64
  for p in paths:
    bytes += getFileSize(p)
  var shot: VibShot
  var buffer: seq[byte] = @[]
  for pass in 1 .. 2:
    var refused = 0
    var t = getMonoTime()
    for p in paths:
      try:
        discard readVibInfo(p)
      except VibFormatError:
        inc refused
    if pass == 2: rate("info only", paths.len, refused, bytes, getMonoTime() - t)
    for find in [false, true]:
      refused = 0
      var frames = 0
      t = getMonoTime()
      for p in paths:
        try:
          readVibInto(p, shot, buffer, allowIncomplete = true, findTrigger = find)
          frames += shot.len
        except VibFormatError:
          inc refused
      if pass == 2:
        rate(if find: "decode + trigger fit" else: "decode", paths.len, refused, bytes,
          getMonoTime() - t)
        if find: echo "                  ", frames, " frames"

proc main() =
  let args = commandLineParams()
  var paths: seq[string] = @[]
  var made = ""
  if args.len == 0 or args[0].allCharsInSet(Digits):
    let count = if args.len > 0: parseInt(args[0]) else: 400
    made = getTempDir() / ("ssvib-bench-" & $getCurrentProcessId())
    createDir(made)
    for i in 0 ..< count:
      let after = if i mod 8 == 7: 8000 else: 24000 # a 12 s sweep; one 4 s record in eight
      let name = made / (intToStr(i, 4) & ".VIB")
      writeFile(name, synthVib(SynthVib(afterTrigger: after,
        preTrigger: 600.37 + float64(i mod 97), startHz: 6.0, rateHzPerS: 8.0 +
        float64(i mod 5))))
      paths.add name
  else:
    for dir in args:
      for f in walkDirRec(dir):
        if f.toLowerAscii.endsWith(".vib"):
          paths.add f
    paths.sort()
  try:
    echo "files: ", paths.len
    run(paths)
  finally:
    if made.len > 0:
      removeDir(made)

main()
