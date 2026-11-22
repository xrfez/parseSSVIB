## The package must be able to live in a repository of its own, and its decoder must
## need only the standard library: every module under `src/` imports only `std/...`
## and its own modules; parseSEG only in `toseg.nim`; `toseg.nim` only from the
## umbrella module `parseSSVIB.nim`; the umbrella module itself from nowhere in the
## package.
##
## Seen to fail: with `import ../ui/imgui/app` planted in `decode.nim`, or
## `import ./toseg` planted in `types.nim`, `packageImports` names it.

import std/[os, strutils, sequtils]

const
  srcDir = currentSourcePath().parentDir.parentDir / "src"
  segModule = "toseg.nim"     ## the one module that may import parseSEG
  umbrella = "parseSSVIB.nim" ## the one module that may import `toseg`

proc statements(text: string): seq[string] =
  ## The import, from and include statements of `text`, each on one line, with
  ## bracketed and comma-continued lists joined.
  var open = ""
  for raw in text.splitLines:
    let line = raw.split('#')[0].strip
    if open.len > 0:
      open.add " " & line
    elif line.startsWith("import ") or line.startsWith("from ") or
        line.startsWith("include ") or line in ["import", "include"]:
      open = line
    if open.len > 0 and open.count('[') <= open.count(']') and not open.endsWith(",") and
        open != "import" and open != "include":
      result.add open
      open = ""

proc moduleNames(text: string): seq[string] =
  ## Every module `text` imports, with `prefix/[a, b]` expanded to `prefix/a`,
  ## `prefix/b`. A `from m import x` names `m`.
  for st in statements(text):
    var body = st.split(' ', 1)[1]
    if st.startsWith("from "):
      body = body.split(" import ")[0]
    var depth = 0
    var item = ""
    var items: seq[string] = @[]
    for c in body:
      if c == '[': inc depth
      elif c == ']': dec depth
      if c == ',' and depth == 0:
        items.add item
        item = ""
      else:
        item.add c
    items.add item
    for it in items:
      let one = it.strip.replace("\"", "")
      let open = one.find('[')
      if open < 0:
        if one.len > 0: result.add one
      else:
        let prefix = one[0 ..< open]
        for inner in one[open + 1 ..< one.rfind(']')].split(','):
          if inner.strip.len > 0: result.add prefix & inner.strip

proc problems(file, text: string): seq[string] =
  ## The imports of module `file` (a file name) that the package's rules forbid.
  for imp in moduleNames(text):
    let name = imp.replace('\\', '/')
    let base = name.split('/')[^1]
    let own = name.startsWith("parseSSVIB/") or name.startsWith("./")
    let seg = name == "parseSEG" or name.startsWith("parseSEG/")
    var ok = own or name.startsWith("std/") or (seg and file == segModule)
    if base == "toseg" and file != umbrella:
      ok = false
    if name == "parseSSVIB" or name.endsWith("/parseSSVIB"):
      ok = false
    if not ok:
      result.add file & " imports " & imp

proc main*() =

  block packageImports:
    var found: seq[string] = @[]
    var count = 0
    for file in walkDirRec(srcDir):
      if file.endsWith(".nim"):
        inc count
        found.add problems(file.extractFilename, readFile(file))
    doAssert count >= 5, "the modules are not where this test looks"
    doAssert found.len == 0, "import rule broken:\n  " & found.join("\n  ")

  block checkerCatchesViolations:
    let bad = "import std/[os, strutils]\nimport ../ui/imgui/app, parseSEG/model/keytypes\n" &
      "import\n  ./types,\n  strutils,\n  imguin/cimgui\nfrom ../x import y\n"
    let found = problems("decode.nim", bad)
    doAssert found.len == 5, $found # ../ui, parseSEG here, strutils, imguin, ../x
    doAssert found.anyIt("parseSEG/model/keytypes" in it) and found.anyIt("strutils" in it)
    # parseSEG is for toseg.nim only; std groups and own modules are fine
    doAssert problems("toseg.nim", "import std/[math, strutils]\nimport parseSEG\n" &
      "import ./[decode, types], parseSSVIB/types\n").len == 0
    doAssert problems("decode.nim", "import parseSEG\n").len == 1
    doAssert problems("decode.nim", "from parseSEG/model/keytypes import TraceKeys\n").len == 1
    # toseg is imported by the umbrella module only
    doAssert problems("types.nim", "import ./toseg\n").len == 1
    doAssert problems("decode.nim", "import parseSSVIB/toseg\n").len == 1
    doAssert problems("decode.nim", "import ./[types, toseg]\n").len == 1
    doAssert problems("parseSSVIB.nim", "import parseSSVIB/[types, sweep, decode, units, toseg]\n" &
      "export types\n").len == 0
    # the umbrella module is imported by none of them
    doAssert problems("decode.nim", "import parseSSVIB\n").len == 1
    doAssert problems("decode.nim", "include ../parseSSVIB\n").len == 1
    doAssert moduleNames("import std/[a, b], ./c\nfrom d/e import f\n") ==
      @["std/a", "std/b", "./c", "d/e"]

when isMainModule:
  main()
