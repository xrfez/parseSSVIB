## The default output of the writers does not change: the files written for several
## synthetic shots (SEG-Y Rev 1 and Rev 2, SEG-D, several channel choices) are the same
## bytes as those the first release of the writers wrote. Each file is held as its length
## and a 64-bit FNV-1a hash of its bytes, taken from the writers before `traceOrder` existed.
##
## Seen to fail: with the order of the default plan changed (cycle values before the
## channels), the hashes differ.
##
## `-d:printGolden` prints the table instead of checking it.

import std/[os, strutils]
import parseSEG
import parseSSVIB
import vibsynth

proc fnv(data: string): uint64 =
  result = 14695981039346656037'u64
  for c in data:
    result = (result xor uint64(ord(c))) * 1099511628211'u64

type Case = tuple[name: string; vib: VibWriteOptions; segd: bool; major: uint8]

proc shots(): seq[VibShot] =
  result = @[]
  for syn in [SynthVib(preTrigger: 40.25, afterTrigger: 260, taperFrames: 20),
      SynthVib(preTrigger: 600.37, afterTrigger: 700, startHz: 8.0, rateHzPerS: 12.0),
      SynthVib(preTrigger: 12.5, afterTrigger: 90, tailBytes: 0, amplitude: 9000)]:
    var s = parseVib(synthVib(syn))
    s.triggerFrame = syn.preTrigger
    s.triggerSource = tsGiven
    result.add s

proc cases(): seq[Case] =
  result = @[]
  for (segd, major) in [(false, 2'u8), (false, 1'u8), (true, 2'u8)]:
    let kind = (if segd: "segd" else: "segy" & $major)
    result.add (kind & " default", VibWriteOptions(), segd, major)
    result.add (kind & " cycle+both", VibWriteOptions(cycleValues: true,
      groundForce: {vsA, vsB}), segd, major)
    result.add (kind & " primaryA", VibWriteOptions(primary: vsA, groundForce: {vsA, vsB}),
      segd, major)
    result.add (kind & " subset", VibWriteOptions(channels: {vcReference, vcMassB,
      vcBaseplateB, vcDrive}, groundForce: {}), segd, major)
    result.add (kind & " record axis", VibWriteOptions(timeAxis: vaRecord, removeMean: true),
      segd, major)

const golden = [
  ("segy2 default shot 0", 23640, 6813297215970912801'u64),
  ("segy2 cycle+both shot 0", 28692, 4773115360187923045'u64),
  ("segy2 primaryA shot 0", 25324, 10377809134356948785'u64),
  ("segy2 subset shot 0", 13536, 14674500851477580081'u64),
  ("segy2 record axis shot 0", 23640, 4170449075350596990'u64),
  ("segy1 default shot 0", 18040, 5179693590917082162'u64),
  ("segy1 cycle+both shot 0", 22372, 14591779942064621990'u64),
  ("segy1 primaryA shot 0", 19484, 2814975607575970830'u64),
  ("segy1 subset shot 0", 9376, 13538269902556693770'u64),
  ("segy1 record axis shot 0", 18040, 10774226263085368089'u64),
  ("segd default shot 0", 13712, 4273619516867876381'u64),
  ("segd cycle+both shot 0", 17576, 9304401670352367873'u64),
  ("segd primaryA shot 0", 15000, 15570245251553677071'u64),
  ("segd subset shot 0", 5696, 1963178770606506477'u64),
  ("segd record axis shot 0", 13712, 9819835869654378405'u64),
  ("segy2 default shot 1", 63640, 12519962357537522639'u64),
  ("segy2 cycle+both shot 1", 80692, 4130647036059895952'u64),
  ("segy2 primaryA shot 1", 69324, 13897954697444011020'u64),
  ("segy2 subset shot 1", 29536, 15323570399393145437'u64),
  ("segy2 record axis shot 1", 63640, 12095082964976818589'u64),
  ("segy1 default shot 1", 58040, 13837162160489645392'u64),
  ("segy1 cycle+both shot 1", 74372, 14064525244358334763'u64),
  ("segy1 primaryA shot 1", 63484, 1560790882194428171'u64),
  ("segy1 subset shot 1", 25376, 9321173214010457826'u64),
  ("segy1 record axis shot 1", 58040, 1624183926545717694'u64),
  ("segd default shot 1", 53712, 1860028854505053249'u64),
  ("segd cycle+both shot 1", 69576, 8112681603105258522'u64),
  ("segd primaryA shot 1", 59000, 7492901181302162332'u64),
  ("segd subset shot 1", 21696, 14763087780254467340'u64),
  ("segd record axis shot 1", 53712, 18122938200981045316'u64),
  ("segy2 default shot 2", 15720, 12813096772948813577'u64),
  ("segy2 cycle+both shot 2", 18396, 8089549183707560030'u64),
  ("segy2 primaryA shot 2", 16612, 7876331024410956710'u64),
  ("segy2 subset shot 2", 10368, 12320219046618013367'u64),
  ("segy2 record axis shot 2", 15720, 16175030142445757944'u64),
  ("segy1 default shot 2", 10120, 26866021460598914'u64),
  ("segy1 cycle+both shot 2", 12076, 11048990940315030741'u64),
  ("segy1 primaryA shot 2", 10772, 17381728809542818561'u64),
  ("segy1 subset shot 2", 6208, 8549630052364794964'u64),
  ("segy1 record axis shot 2", 10120, 14266750560688508479'u64),
  ("segd default shot 2", 5792, 3744690524074427786'u64),
  ("segd cycle+both shot 2", 7280, 17597068038394733268'u64),
  ("segd primaryA shot 2", 6288, 10201260169512463482'u64),
  ("segd subset shot 2", 2528, 9875232295010981591'u64),
  ("segd record axis shot 2", 5792, 5856020077881205704'u64)]

proc main*() =
  let dir = getTempDir() / ("ssvib-tgolden-" & $getCurrentProcessId())
  createDir(dir)
  defer: removeDir(dir)
  var rows: seq[(string, int, uint64)] = @[]
  var k = 0
  for si, s in shots():
    for c in cases():
      let p = dir / "g.out"
      var vib = c.vib
      vib.vendorLayout = false # the hashes pin the traces of the first release
      if c.segd:
        s.writeSegd(p, vib)
      else:
        s.writeSegy(p, SegyOutputOptions(revision: SegyRevision(major: c.major, minor: 0)),
          vib)
      let data = readFile(p)
      rows.add (c.name & " shot " & $si, data.len, fnv(data))
  when defined(printGolden):
    for r in rows:
      echo "  (", r[0].escape, ", ", r[1], ", ", r[2], "'u64),"
  else:
    doAssert rows.len == golden.len, $(rows.len, golden.len)
    for i, r in rows:
      doAssert r == golden[i], "output changed: " & r[0] & " " & $r[1] & " " & $r[2]

when isMainModule:
  main()
