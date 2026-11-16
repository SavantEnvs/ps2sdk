#!/usr/bin/env bash
#
# mayhem/test.sh — known-answer tests of the host tools in tools/ (built with normal flags by mayhem/build.sh).
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

BIN="$SRC/build/tests"
FIX="$SRC/mayhem/tests/fixtures"
for t in bin2c adpenc romimg irxgen srxfixup; do
  [ -x "$BIN/$t" ] || { echo "missing $BIN/$t — mayhem/build.sh did not build it" >&2; exit 1; }
done
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cd "$W"

passed=0; failed=0
check() { # <name> <command...>: passes iff the command succeeds
  local name="$1"; shift
  if "$@" >"$W/check.log" 2>&1; then passed=$((passed+1)); echo "PASS $name"
  else failed=$((failed+1)); echo "FAIL $name"; sed 's/^/    /' "$W/check.log" | head -20; fi
}

# bin2c: C array dump of a 20-byte input (known answer written out by hand)
bin2c_dump() {
  "$BIN/bin2c" "$FIX/bytes20.bin" got.h testlabel >/dev/null
  printf '#ifndef __testlabel__\n#define __testlabel__\n\nunsigned int size_testlabel = 20;\nunsigned char testlabel[] __attribute__((aligned(16))) = {\n\t0x00, 0x01, 0x02, 0x03, 0x7f, 0x80, 0xff, 0x10, 0xaa, 0x55, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, \n\t0x05, 0x06, 0x07, 0x08, \n};\n\n#endif\n' > want.h
  cmp got.h want.h
}
check bin2c-array-dump bin2c_dump

# adpenc: WAV -> ADPCM. Header is "APCM", version 1, channels, pitch = rate*4096/48000 (22050 -> 0x759),
# sample count; the body is one 16-byte block per 28 samples per channel plus a 16-byte end block per channel.
adpenc_case() { # <name> <channels> <samples>
  local n="$1" ch="$2" len="$3"
  "$BIN/adpenc" "$FIX/$n.wav" "$n.sad" >/dev/null || return 1
  [ "$(head -c 4 "$n.sad")" = "APCM" ] || { echo "bad magic"; return 1; }
  [ "$(od -An -tu1 -j5 -N1 "$n.sad" | tr -d ' ')" = "$ch" ] || { echo "bad channel count"; return 1; }
  [ "$(od -An -tu4 -j8 -N4 "$n.sad" | tr -d ' ')" = "1881" ] || { echo "bad pitch"; return 1; }
  [ "$(od -An -tu4 -j12 -N4 "$n.sad" | tr -d ' ')" = "$len" ] || { echo "bad sample count"; return 1; }
  local want=$((16 + ch * (16 * ((len + 27) / 28) + 16)))
  [ "$(stat -c %s "$n.sad")" -eq "$want" ] || { echo "size $(stat -c %s "$n.sad") != $want"; return 1; }
  cmp "$n.sad" "$FIX/$n.sad.golden"
}
check adpenc-mono16   adpenc_case mono16 1 100
check adpenc-mono8    adpenc_case mono8 1 60
check adpenc-stereo16 adpenc_case stereo16 2 64

# romimg: build an image from two files, list it, extract one back byte-for-byte
printf 'first file contents\n' > FIRST.BIN
head -c 200 /dev/zero | tr '\0' 'Z' > SECOND.BIN
romimg_roundtrip() {
  "$BIN/romimg" -c test.img FIRST.BIN SECOND.BIN >/dev/null || return 1
  "$BIN/romimg" -l test.img > list.txt || return 1
  sed 's/\x1b\[[0-9;]*m//g' list.txt > list.plain
  grep -q '^RESET *	0$' list.plain && grep -q '^FIRST.BIN *	20$' list.plain \
    && grep -q '^SECOND.BI *	200$' list.plain && grep -q '^Total size: 220 bytes' list.plain \
    || { cat list.plain; return 1; }
  mkdir out && (cd out && "$BIN/romimg" -x ../test.img SECOND.BI >/dev/null) || return 1
  cmp out/SECOND.BI SECOND.BIN
}
check romimg-create-list-extract romimg_roundtrip

# srxfixup: relocatable MIPS object -> IRX; ELF type becomes 0xFF80 (ET_SCE_IOPRELEXEC)
srxfixup_irx() {
  "$BIN/srxfixup" --allow-zero-text --rb -m -o got.irx "$FIX/module.o" >/dev/null 2>&1 || return 1
  [ "$(od -An -tx1 -j16 -N2 got.irx | tr -d ' ')" = "80ff" ] || { echo "bad e_type"; return 1; }
  cmp got.irx "$FIX/module.irx.golden"
}
check srxfixup-rel-to-irx srxfixup_irx

# ps2-irxgen: linked MIPS ELF with .iopmod -> stripped IRX
irxgen_irx() {
  "$BIN/irxgen" "$FIX/module.elf" got2.irx >/dev/null 2>&1 || return 1
  cmp got2.irx "$FIX/module.elf.irx.golden"
}
check irxgen-elf-to-irx irxgen_irx

emit_ctrf "tools-known-answer" "$passed" "$failed" 0
