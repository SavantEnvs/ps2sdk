#!/usr/bin/env bash
# Builds the host-side ps2sdk tools (tools/{bin2c,adpenc,romimg,ps2-irxgen,srxfixup}) with the sanitizer flags,
# plus the adpcm_encode libFuzzer harness, and the same tools with normal flags for mayhem/test.sh.
# The tools' Makefiles need the PS2SDK cross environment, so each tool is compiled directly from its sources.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
T="$SRC/tools"
OBJ="$SRC/build/fuzz"
TESTBIN="$SRC/build/tests"
mkdir -p "$OBJ" "$TESTBIN"

# Leak detection off for every ASan binary (the tools never free their buffers).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ/lsan_off.o"

# 1) The tools themselves, sanitized + DWARF 3. Binary names are the Mayhem target names.
fuzz_tool() { # <out> <extra flags...> -- <sources...>
  local out="$1"; shift
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS "$@" "$OBJ/lsan_off.o" -o "$SRC/$out"
}
fuzz_tool bin2s    "$T/bin2c/src/bin2c.c"
# adpcm.c shifts a negative 8-bit sample left (`samples[i] <<= 8`); benign, fires on every 8-bit input.
fuzz_tool adpenc   -fno-sanitize=shift-base "$T"/adpenc/src/*.c -lm
# romimg casts byte-buffer offsets to structs (`(struct RomDirEntry *)ROMFS_start`): misaligned, benign on the host.
fuzz_tool romimg   -fno-sanitize=alignment "$T"/romimg/src/*.c
# types.h lw_le() assembles a word with `ptr[3] << 24` (uint8 promoted to int): shift-base on every high-bit byte.
fuzz_tool irxgen   -Wno-unused-result -fno-sanitize=shift-base "$T/ps2-irxgen/src/ps2-irxgen.c"
fuzz_tool srxfixup "$T"/srxfixup/src/*.c

# 2) libFuzzer harness over tools/adpenc/src/adpcm.c (the encoder is also linked into adpenc above).
#    Both objects get SanCov (fuzzer-no-link); the link line alone instruments nothing.
$CC $SANITIZER_FLAGS -fsanitize=fuzzer-no-link -fno-sanitize=shift-base $DEBUG_FLAGS -c "$T/adpenc/src/adpcm.c" -o "$OBJ/adpcm.o"
$CXX $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS -c "$SRC/mayhem/fuzz_pack.cpp" -o "$OBJ/fuzz_pack.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$OBJ/fuzz_pack.o" "$OBJ/adpcm.o" "$OBJ/lsan_off.o" -lm \
    -o "$SRC/fuzz_pack"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$OBJ/fuzz_pack.o" "$OBJ/adpcm.o" "$OBJ/standalone_main.o" "$OBJ/lsan_off.o" -lm \
    -o "$SRC/fuzz_pack-standalone"

# 3) The same tools with NORMAL flags, for mayhem/test.sh (an independent, unsanitized build).
test_tool() { # <out> <extra flags...>
  local out="$1"; shift
  $CC -O2 $COVERAGE_FLAGS "$@" -o "$TESTBIN/$out"
}
test_tool bin2c    "$T/bin2c/src/bin2c.c"
test_tool adpenc   "$T"/adpenc/src/*.c -lm
test_tool romimg   "$T"/romimg/src/*.c
test_tool irxgen   -Wno-unused-result "$T/ps2-irxgen/src/ps2-irxgen.c"
test_tool srxfixup "$T"/srxfixup/src/*.c
