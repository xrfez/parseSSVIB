## libFuzzer target for `parseVib` (not part of the test run).
##
## Build (clang with libFuzzer), from the package folder:
##   nim c --cc:clang --panics:on -d:release -d:useMalloc -g --noMain:on \
##     --passC:"-fsanitize=fuzzer,address" --passL:"-fsanitize=fuzzer,address" \
##     -o:fuzzparse tests/fuzz/fuzzparse.nim
##   mkdir corpus   # and put in it files that `synthVib` (tests/vibsynth.nim) writes
##   ./fuzzparse -max_len=131072 corpus
## Without libFuzzer, replay files: `nim c -d:fuzzStandalone tests/fuzz/fuzzparse.nim`
## then `./fuzzparse input...` (with none, it replays a few synthetic files). The test
## runner builds and runs it that way, so it cannot stop compiling unnoticed. Seed the
## corpus with files `synthVib` writes.

import parseSSVIB/[decode, types, sweep]

var reused: VibShot ## one shot decodes every input, as a caller that keeps one does

proc initialize(): cint {.cdecl, exportc: "LLVMFuzzerInitialize".} =
  {.emit: "N_CDECL(void, NimMain)(void); NimMain();".}

proc testOneInput(data: ptr UncheckedArray[byte], len: int): cint {.
    cdecl, exportc: "LLVMFuzzerTestOneInput", raises: [].} =
  result = 0
  if len > 0:
    for allow in [false, true]:
      try:
        discard parseVib(data.toOpenArray(0, len - 1), allow)
        decodeInto(reused, data.toOpenArray(0, len - 1), allow)
      except VibFormatError:
        discard # the expected refusal; any other failure is a finding
      except ValueError:
        discard # the interval check: never raised for the default interval
    try:
      discard parseVibInfo(data.toOpenArray(0, len - 1))
    except VibFormatError:
      discard
    except ValueError:
      discard
    # the sweep fit takes any 16-bit channel: feed it the input as samples
    if len >= 2:
      var x = newSeq[int16](len div 2)
      for i in 0 ..< x.len:
        x[i] = cast[int16](uint16(data[2 * i]) or (uint16(data[2 * i + 1]) shl 8))
      discard fitSweep(x)
      discard endsInSweep(x)

when defined(fuzzStandalone):
  import std/[cmdline, syncio]
  import ../vibsynth

  proc replay(buf: string) =
    if buf.len > 0:
      discard testOneInput(cast[ptr UncheckedArray[byte]](cstring(buf)), buf.len)

  stderr.write "StandaloneFuzzTarget: running " & $paramCount() & " inputs\n"
  if paramCount() == 0: # no files: a few synthetic ones, so the target is exercised
    for after in [1, 40, 2000]:
      replay cast[string](synthVib(SynthVib(afterTrigger: after, preTrigger: 10.5)))
    replay cast[string](synthVib(SynthVib(afterTrigger: 200, tailBytes: 5)))
    replay cast[string](synthOtherKind(20))
  for i in 1 .. paramCount():
    replay readFile(paramStr(i))
