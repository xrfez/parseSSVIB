## Runs every `t*.nim` file of this folder in a process of its own:
##   nim c -r tests/tester.nim [flags]
## Flags (`-d:release`, `-d:danger`, ...) go to the compiler. The package's `nimble
## test` / `nim test` task starts it.

import std/[os, strutils]

proc main() =
  let dir = currentSourcePath().parentDir
  var flags = ""
  for p in commandLineParams():
    flags.add " " & quoteShell(p)
  var failed: seq[string] = @[]
  for f in walkFiles(dir / "t*.nim"):
    let name = f.extractFilename
    if name != "tester.nim":
      echo "Running: ", name
      let exe = getTempDir() / ("ssvib-" & name.changeFileExt("") & "-" &
        $getCurrentProcessId())
      let cmd = quoteShell(getCurrentCompilerExe()) & " c -r --hints:off --warnings:off" &
        flags & " --nimcache:" & quoteShell(getTempDir() / "ssvib-nimcache-" &
        name.changeFileExt("")) & " -o:" & quoteShell(exe) & " " & quoteShell(f)
      let code = execShellCmd(cmd)
      removeFile(exe)
      if code != 0:
        failed.add name
  # the libFuzzer target is not a test, but it must keep compiling: build it as the
  # standalone replayer and run it on a few synthetic inputs
  let fuzzExe = getTempDir() / ("ssvib-fuzzparse-" & $getCurrentProcessId())
  echo "Running: fuzz/fuzzparse.nim (standalone)"
  let fuzzCmd = quoteShell(getCurrentCompilerExe()) & " c -r --hints:off --warnings:off" &
    flags & " -d:fuzzStandalone --panics:on --nimcache:" & quoteShell(getTempDir() /
    "ssvib-nimcache-fuzzparse") & " -o:" & quoteShell(fuzzExe) & " " &
    quoteShell(dir / "fuzz" / "fuzzparse.nim")
  if execShellCmd(fuzzCmd) != 0:
    failed.add "fuzz/fuzzparse.nim"
  removeFile(fuzzExe)
  if failed.len > 0:
    quit "FAILURE " & failed.join(", ")
  echo "All test files completed."

main()
