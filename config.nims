# Build configuration and tasks of parseSSVIB.
import std/os

switch("outdir", "bin")
switch("path", thisDir() / "src") # the package itself, also where nim.cfg has no path line

const tester = "c -r --hints:off --warnings:off tests/tester.nim"

task test, "Run the tests: every tests/t*.nim, one process each":
  selfExec tester

task testRelease, "Run the tests in -d:release and -d:danger builds":
  selfExec tester & " -d:release"
  selfExec tester & " -d:danger"

task bench, "Files per second and MB/s of the decoder on synthetic files (release build)":
  ## `nim c -d:release -r bench/bench.nim <folder>` runs it over your own files.
  selfExec "c -d:release -r --hints:off --warnings:off bench/bench.nim"

task docs, "Generate HTML documentation into htmldocs/":
  selfExec "doc --project --outdir:htmldocs src/parseSSVIB.nim"

const depsTool = "r --hints:off --warnings:off tools/deps.nim "

task depsStatus, "Show each locked dependency: locked vs checked-out commit":
  selfExec depsTool & "status"

task depsSync, "Check out every dependency at its locked commit (no Atlas)":
  selfExec depsTool & "sync"

task depsCheck, "Verify atlas.lock, nim.cfg and deps/ agree":
  selfExec depsTool & "check"
