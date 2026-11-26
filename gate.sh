#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# gate.sh: Fail-closed verification gate for drakestapleton/omega-cpu-x86.
# Auto-detects host architecture (x86_64 vs aarch64), verifies pinned omc SHA-256
# against OMEGA_CORE.lock, checks deterministic bit-identical compilation, and
# runs native x86-64 verification (x86_engine, ng target gate + crystallized cx64
# ELF, and x86linux_qual) plus negative contract refusal controls.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
LOCK="$ROOT/OMEGA_CORE.lock"
if [ ! -f "$LOCK" ]; then
    echo "OMEGA-CPU-X86 GATE FAIL: missing $LOCK" >&2
    exit 1
fi

LOCK_OMC_PATH=$(awk -F= '/^OMC_PATH=/{print $2; exit}' "$LOCK")
LOCK_OMC_SHA=$(awk -F= '/^OMC_SHA256=/{print $2; exit}' "$LOCK")
OMC=${OMC:-"$ROOT/../omega-mv/${LOCK_OMC_PATH:-seed/out/omc}"}

if [ ! -x "$OMC" ]; then
    echo "OMEGA-CPU-X86 NOT_RUN: compiler missing at $OMC (set OMC=/path/to/omc)" >&2
    exit 3
fi

GOT_SHA=$(sha256sum "$OMC" | awk '{print $1}')
if [ "$GOT_SHA" != "$LOCK_OMC_SHA" ]; then
    echo "OMEGA-CPU-X86 REFUSED: omc sha256 $GOT_SHA != $LOCK_OMC_SHA (OMEGA_CORE.lock)" >&2
    exit 69
fi

HOST_ARCH=$(uname -m)
RUN_OMC=""
if [ "$HOST_ARCH" = "aarch64" ]; then
    RUN_OMC="$OMC"
elif [ "$HOST_ARCH" = "x86_64" ]; then
    if command -v qemu-aarch64-static >/dev/null 2>&1; then
        RUN_OMC="qemu-aarch64-static $OMC"
    elif command -v qemu-aarch64 >/dev/null 2>&1; then
        RUN_OMC="qemu-aarch64 $OMC"
    else
        echo "OMEGA-CPU-X86 NOT_RUN: x86_64 host requires qemu-aarch64-static or qemu-aarch64 to run AArch64 omc" >&2
        exit 3
    fi
else
    echo "OMEGA-CPU-X86 NOT_RUN: unsupported host arch $HOST_ARCH" >&2
    exit 3
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/omega-cpu-x86-gate.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

echo "=== OMEGA-CPU-X86 VERIFICATION GATE ==="
echo "HOST_ARCH=$HOST_ARCH"
echo "OMC_SHA256=$GOT_SHA (LOCK VERIFIED)"

# Helper: compile stdin with omc, failing closed on any stderr or non-zero exit
compile_omc() {
    out_bin="$1"
    err_file="$2"
    # shellcheck disable=SC2086
    $RUN_OMC > "$out_bin" 2> "$err_file"
    if [ -s "$err_file" ]; then
        cat "$err_file" >&2
        exit 1
    fi
    if [ ! -s "$out_bin" ]; then
        echo "FAIL: empty compiler output $out_bin" >&2
        exit 1
    fi
    chmod 700 "$out_bin"
}

# ---------------------------------------------------------------------------
# 1. om/x86_engine.om: dual-target compile + 2x deterministic x86linux build
# ---------------------------------------------------------------------------
echo "--- [1/4] Compiling om/x86_engine.om (2x target x86linux + AArch64) ---"
{ printf 'target x86linux\nom2\n'; grep -v '^om2$' "$ROOT/om/x86_engine.om"; } \
    | compile_omc "$WORK/x86_engine.x64.1" "$WORK/x86_1.err"
{ printf 'target x86linux\nom2\n'; grep -v '^om2$' "$ROOT/om/x86_engine.om"; } \
    | compile_omc "$WORK/x86_engine.x64.2" "$WORK/x86_2.err"
cmp "$WORK/x86_engine.x64.1" "$WORK/x86_engine.x64.2" \
    || { echo "FAIL: non-deterministic x86_engine x86linux build" >&2; exit 1; }
X86_ENG_SHA=$(sha256sum "$WORK/x86_engine.x64.1" | awk '{print $1}')
echo "x86_engine.x64 DETERMINISTIC_CMP=PASS sha256=$X86_ENG_SHA"

compile_omc "$WORK/x86_engine.a64" "$WORK/a64.err" < "$ROOT/om/x86_engine.om"
A64_ENG_SHA=$(sha256sum "$WORK/x86_engine.a64" | awk '{print $1}')
echo "x86_engine.a64 COMPILE=PASS sha256=$A64_ENG_SHA"

if [ "$HOST_ARCH" = "x86_64" ]; then
    ENG_BIN="$WORK/x86_engine.x64.1"
    EXEC_MODE="NATIVE_X86_64"
else
    ENG_BIN="$WORK/x86_engine.a64"
    EXEC_MODE="NATIVE_AARCH64"
fi

echo "--- [1b] Running x86_engine ($EXEC_MODE): probe, plan, selftest, negative controls ---"
"$ENG_BIN" probe > "$WORK/probe.out"
cat "$WORK/probe.out"
grep -q 'OMEGA-CPU-X86 LIVE /proc/cpuinfo PROBE' "$WORK/probe.out"

"$ENG_BIN" plan > "$WORK/plan.out"
cat "$WORK/plan.out"
grep -q 'AMD Ryzen X3D' "$WORK/plan.out"
grep -q 'CCD0(V-Cache)' "$WORK/plan.out"
grep -q 'CCD1(Std-L3)' "$WORK/plan.out"
grep -q 'Steam Deck AMD Zen 2' "$WORK/plan.out"

"$ENG_BIN" selftest > "$WORK/selftest.out"
cat "$WORK/selftest.out"
grep -q 'X86-ENGINE-SELFTEST PASS checks=21 controls=7' "$WORK/selftest.out"

# CLI negative contract refusal controls (MUST refuse invalid ISA requirements!)
rc=0
"$ENG_BIN" check 5 2 > "$WORK/neg1.out" || rc=$?
cat "$WORK/neg1.out"
[ "$rc" -eq 3 ] || { echo "FAIL: Steam Deck AVX-512 negative control returned $rc, expected 3" >&2; exit 1; }
grep -q 'CONTRACT_REFUSED profile=5 code=3 reason=MISSING_AVX512' "$WORK/neg1.out"

rc=0
"$ENG_BIN" check 4 16 > "$WORK/neg2.out" || rc=$?
cat "$WORK/neg2.out"
[ "$rc" -eq 6 ] || { echo "FAIL: Ryzen X3D AMX negative control returned $rc, expected 6" >&2; exit 1; }
grep -q 'CONTRACT_REFUSED profile=4 code=6 reason=MISSING_AMX' "$WORK/neg2.out"

# CLI positive control: Intel Xeon AMX accepts AVX2|AVX512|FMA|BMI2|AMX (mask 31)
"$ENG_BIN" check 1 31 > "$WORK/pos1.out"
cat "$WORK/pos1.out"
grep -q 'CONTRACT_OK profile=1' "$WORK/pos1.out"

# ---------------------------------------------------------------------------
# 2. om/target/gate.om: Unified TargetDesc + Multi-ISA Backend + Crystallizer
# ---------------------------------------------------------------------------
echo "--- [2/4] Compiling & running om/target/gate.om ($EXEC_MODE) ---"
TARGET_UNITS="
$ROOT/om/target/target_desc.om
$ROOT/om/target/regalloc.om
$ROOT/om/target/isel.om
$ROOT/om/target/sm121_pe.om
$ROOT/om/target/fabric.om
$ROOT/om/target/crystallize.om
$ROOT/om/target/gate.om
"

if [ "$HOST_ARCH" = "x86_64" ]; then
    # shellcheck disable=SC2086
    { printf 'target x86linux\nom2\n'; cat $TARGET_UNITS; } \
        | compile_omc "$WORK/ng_target_gate.1" "$WORK/ng1.err"
    # shellcheck disable=SC2086
    { printf 'target x86linux\nom2\n'; cat $TARGET_UNITS; } \
        | compile_omc "$WORK/ng_target_gate.2" "$WORK/ng2.err"
    cmp "$WORK/ng_target_gate.1" "$WORK/ng_target_gate.2" \
        || { echo "FAIL: non-deterministic ng_target_gate x86linux build" >&2; exit 1; }
    NG_BIN="$WORK/ng_target_gate.1"
else
    # shellcheck disable=SC2086
    { printf 'om2\n'; cat $TARGET_UNITS; } \
        | compile_omc "$WORK/ng_target_gate.1" "$WORK/ng1.err"
    NG_BIN="$WORK/ng_target_gate.1"
fi

"$NG_BIN" > "$WORK/ng_gate.out"
cat "$WORK/ng_gate.out"
grep -q 'NG-TARGET-GATE PASS checks=73 controls=10' "$WORK/ng_gate.out"

# Crystallized ELF live execution check
echo "--- [3/4] Running crystallized ELF emitted by om/target/gate.om ($EXEC_MODE) ---"
if [ "$HOST_ARCH" = "x86_64" ]; then
    "$NG_BIN" cx64 > "$WORK/cryst_x64.elf"
    chmod 700 "$WORK/cryst_x64.elf"
    rc=0
    "$WORK/cryst_x64.elf" || rc=$?
    echo "CRYST_X64_NATIVE_EXIT=$rc (expected 36)"
    [ "$rc" -eq 36 ] || { echo "FAIL: crystallized x86-64 ELF exited $rc, expected 36" >&2; exit 1; }
else
    "$NG_BIN" ca64 > "$WORK/cryst_a64.elf"
    chmod 700 "$WORK/cryst_a64.elf"
    rc=0
    "$WORK/cryst_a64.elf" || rc=$?
    echo "CRYST_A64_NATIVE_EXIT=$rc (expected 36)"
    [ "$rc" -eq 36 ] || { echo "FAIL: crystallized AArch64 ELF exited $rc, expected 36" >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# 3. om/qual/x86linux_qual.om: Pure-Omega x86-64 Linux Qualification Binary
# ---------------------------------------------------------------------------
echo "--- [4/4] Compiling & running om/qual/x86linux_qual.om (2x deterministic) ---"
{ printf 'target x86linux\nom2\n'; cat "$ROOT/om/qual/sha256.om"; grep -v '^target x86linux$' "$ROOT/om/qual/x86linux_qual.om" | grep -v '^om2$'; } \
    | compile_omc "$WORK/x86linux_qual.1" "$WORK/qual1.err"
{ printf 'target x86linux\nom2\n'; cat "$ROOT/om/qual/sha256.om"; grep -v '^target x86linux$' "$ROOT/om/qual/x86linux_qual.om" | grep -v '^om2$'; } \
    | compile_omc "$WORK/x86linux_qual.2" "$WORK/qual2.err"
cmp "$WORK/x86linux_qual.1" "$WORK/x86linux_qual.2" \
    || { echo "FAIL: non-deterministic x86linux_qual build" >&2; exit 1; }
QUAL_SHA=$(sha256sum "$WORK/x86linux_qual.1" | awk '{print $1}')
echo "x86linux_qual DETERMINISTIC_CMP=PASS sha256=$QUAL_SHA"

if [ "$HOST_ARCH" = "x86_64" ]; then
    "$WORK/x86linux_qual.1" > "$WORK/qual.out"
    cat "$WORK/qual.out"
    grep -q 'EXEC_CLASS=PHYSICAL_X86_64' "$WORK/qual.out"
    grep -q 'VERDICT=PASS checks=12 traps=4/4' "$WORK/qual.out"
elif command -v qemu-x86_64 >/dev/null 2>&1; then
    rc=0
    qemu-x86_64 "$WORK/x86linux_qual.1" > "$WORK/qual_def.out" || rc=$?
    [ "$rc" -eq 3 ] || { echo "FAIL: x86linux_qual under QEMU returned $rc, expected 3" >&2; exit 1; }
    grep -q 'VERDICT=BLOCKED_HARDWARE' "$WORK/qual_def.out"
    qemu-x86_64 "$WORK/x86linux_qual.1" --allow-emulated-selftest > "$WORK/qual_emu.out"
    cat "$WORK/qual_emu.out"
    grep -q 'VERDICT=EMULATED_SELFTEST_PASS' "$WORK/qual_emu.out"
else
    echo "x86linux_qual: compiled deterministically; runtime execution NOT_RUN on $HOST_ARCH without qemu-x86_64"
fi

echo "OMEGA-CPU-X86 GATE PASS"
