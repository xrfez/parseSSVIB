# Vendor maps of parseSSVIB

parseSEG's vendor maps that describe the shot block parseSSVIB writes into a SEG-Y or
SEG-D file (`VibWriteOptions.vendorLayout`, on by default). Put this folder on the search
path of a parseSEG program (`PARSESEG_VENDOR_PATH`, or load it with `loadVendorMaps`) and
the block decodes by field name.

| File | For |
|---|---|
| `parseSSVIB-segy-1.nif` | SEG-Y files: the block is the binary stanza `parseSSVIB:Shot v1` of the extended textual header; recognised by card 37, `PARSESSVIB SHOT STANZAS VERSION 1 (MAP PARSESSVIB-SEGY-1)` |
| `parseSSVIB-segd-1.nif` | SEG-D Rev 3 files: the block is the record's external header (40 blocks of 32 bytes); recognised by `SSVIBSHT` at its first byte |

Both hold the same fields: SEG-Y and SEG-D files written by parseSSVIB from a vibrator
controller's `.vib` signature record: the shot block (decoded fields, the options and
trace table, the file's header). The layout belongs to parseSSVIB, not to the
controller's maker; the maps carry no company name and the files hold no value that is
not in the `.vib` file or given by the caller.

The block is 1280 bytes, big-endian (every multi-byte field carries `(byteOrder big)`,
as parseSEG reads a stanza in the file's own byte order): 8 bytes `SSVIBSHT`, the layout
version and the block length, the decoded values, the options, the 47 header bytes of the
`.vib` file verbatim from byte 257 (little-endian, decoded in place), the trace table
from byte 321 (one 48-byte entry per trace written, `traces` of them: the column, the
codes, the unit and the factor and mean that turn the counts into the written samples) and
`incompleteWhy` from byte 1089. Unused bytes are 0. An integer that is not known is
0xFFFFFFFF (the map's sentinel leaves it out), a float is NaN, and the trigger date and time
are left out when `triggerKnown` is 0. The samples are not in it, and neither is a flipped
sign: the ground forces are as recorded.
