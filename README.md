# `omega-cpu-x86` — Pure-Omega Intel & AMD x86-64 CPU Optimizer Engine

Pure seeded `.om` (OM-2) CPU optimization engine, unified `TargetDesc` multi-ISA backend, register-allocated x86-64 ELF emitter (`oir_x64` / `isel` / `crystallize`), and native x86-64 Linux qualification suite—compiled deterministically by the pinned seeded Omega compiler (`omc`) with zero C/LLVM runtime dependencies.

## Pinned Omega Core Lock (`OMEGA_CORE.lock`)

- Reference repository: `https://github.com/drakestapleton/omega-mv`
- Reference commit: `5132074dcc8a4a55e7acaa06be9d9b8698ead402`
- Seeded compiler (`seed/out/omc`) SHA-256: `85b84c6de85083e4d9d2368015c1ddcab3d863aada922be0e63d774dddf23134`

## Silicon Profiles (`om/x86_engine.om`)

| Profile ID | Silicon | ISA Features | Vector | L1D | L2 | L3 | Topology Notes |
|---|---|---|---|---|---|---|---|
| `0` | Intel Core Ultra (Arrow Lake / Lunar Lake) | `AVX2`, `FMA`, `BMI2`, `AES`, `SHA` | 256-bit | 48 KiB | 3 MiB | 36 MiB | Client hybrid; refuses `AVX-512` & `AMX` |
| `1` | Intel Xeon Scalable (AVX-512 + AMX) | `AVX2`, `AVX512`, `FMA`, `BMI2`, `AMX`, `AES`, `SHA` | 512-bit | 48 KiB | 2 MiB | 105 MiB | Full AVX-512 + AMX tile support |
| `2` | AMD Zen 4 (Ryzen 7000 / EPYC Genoa) | `AVX2`, `AVX512`, `FMA`, `BMI2`, `AES`, `SHA` | 512-bit | 32 KiB | 1 MiB | 32 MiB | Double-pumped 256b AVX-512; refuses `AMX` |
| `3` | AMD Zen 5 (Ryzen 9000 / EPYC Turin) | `AVX2`, `AVX512`, `FMA`, `BMI2`, `AES`, `SHA` | 512-bit | 48 KiB | 1 MiB | 32 MiB | Full 512-bit datapath; refuses `AMX` |
| `4` | AMD Ryzen X3D (7950X3D / 9950X3D) | `AVX2`, `AVX512`, `FMA`, `BMI2`, `AES`, `SHA` | 512-bit | 48 KiB | 1 MiB | 96 MiB / 32 MiB | Dual-CCD asymmetric L3: **CCD0 96 MiB 3D V-Cache** vs **CCD1 32 MiB** |
| `5` | Valve Steam Deck AMD Zen 2 (Van Gogh / Sephiroth) | `AVX2`, `FMA`, `BMI2`, `AES`, `SHA` | 256-bit | 32 KiB | 512 KiB | 4 MiB | Tight 4 MiB unified CCX L3; refuses `AVX-512` & `AMX` |

### Capabilities of `om/x86_engine.om`
- **Dual-target pure OM-2**: compiles cleanly to both static **x86-64 Linux ELF** (`target x86linux`) and static **AArch64 Linux ELF** (`om2`).
- **Live `/proc/cpuinfo` probe (`probe`)**: read-only host detection of vendor, model, cache size, logical CPUs, ISA flags (`AVX2`/`AVX512`/`FMA`/`BMI2`/`AMX`/`AES`/`SHA`), and honest VM (`hypervisor`) vs bare-metal classification.
- **Cache-aware tile planner (`plan`)**: derives `(MC, KC, NC, L3_NC, VEC_ELEMS)` per silicon profile, explicitly differentiating Ryzen X3D CCD0 (96 MiB 3D V-Cache) from CCD1 (32 MiB standard L3) and Steam Deck Zen 2 (4 MiB L3).
- **Physical feature contract validator (`check <profile_id> <req_feat_mask>`)**: fail-closed refusal controls for unsupported `AVX2`, `AVX512`, `FMA`, `BMI2`, `AMX`, vector width, L1D, or L3 budgets.
- **Deterministic micro-kernel self-check (`selftest`)**: exact bit-level verification (`bitcast uint`) across 4-way unrolled integer dot-product, IEEE-754 FP32 dot-product (`318.0 = 0x439F0000`), 4x4 cache-blocked FP32 GEMV (`640.0 = 0x44200000`), and integer + FP32 inclusive prefix-sum reductions (`2080`, `264.0 = 0x43840000`), plus 7 built-in negative contract controls.

## Honest Verification Status

Recorded from `sh gate.sh` on Linux `x86_64` (`GenuineIntel` Intel(R) Xeon(R) CPU @ 2.30GHz, 2 logical CPUs, flags `avx2 fma bmi2 aes`, `hypervisor` flag present):

| Component | Execution Mode | Status | Observed Result |
|---|---|---|---|
| Seeded compiler `seed/out/omc` (AArch64 ELF) | **Emulated** (`qemu-aarch64-static` on `x86_64`) | `PASS` (emulated host) | SHA-256 verified against `OMEGA_CORE.lock`; 2x builds bit-identical via `cmp` |
| `om/x86_engine.om` (`target x86linux`) | **NATIVE Linux `x86_64`** (VM) | `PASS` | `DETERMINISTIC_CMP=PASS`, `probe` live `/proc/cpuinfo`, `plan`, `X86-ENGINE-SELFTEST PASS checks=21 controls=7`, CLI negative controls (`check 5 2` exit 3 `MISSING_AVX512`, `check 4 16` exit 6 `MISSING_AMX`) |
| `om/x86_engine.om` (AArch64 `om2`) | **Cross-compiled** (`qemu-aarch64-static`) | `PASS` (compile) | Static AArch64 ELF built cleanly from identical source |
| `om/target/gate.om` (`target x86linux`) | **NATIVE Linux `x86_64`** (VM) | `PASS` | `DETERMINISTIC_CMP=PASS`, `NG-TARGET-GATE PASS checks=73 controls=10` |
| Crystallized x86-64 ELF (`ng_target_gate cx64`) | **NATIVE Linux `x86_64`** (VM) | `PASS` | Emitted 152-byte static register-allocated x86-64 ELF executed natively: `CRYST_X64_NATIVE_EXIT=36` |
| `om/qual/x86linux_qual.om` (`target x86linux`) | **NATIVE Linux `x86_64`** (VM) | `PASS` | `DETERMINISTIC_CMP=PASS`, `EXEC_CLASS=PHYSICAL_X86_64` (native x86-64 kernel, no QEMU), `VERDICT=PASS checks=12 traps=4/4` |
| Bare-metal client/server silicon (Intel Core Ultra, Xeon AMX, AMD Zen 4/5, Ryzen X3D, Steam Deck Zen 2) | Physical bare-metal hardware | `NOT_RUN` | Cloud VM exposes `hypervisor` and lacks AVX-512/AMX; bare-metal qualification requires target physical silicon |

## Repository Layout

```text
OMEGA_CORE.lock              # Pinned omega-mv commit & omc SHA-256
LICENSE                      # Apache-2.0
gate.sh                      # Fail-closed verification gate (x86_64 & aarch64)
docs/
  TARGET-DESC.md             # Unified 24-field TargetDesc & multi-ISA backend spec
om/
  x86_engine.om              # Pure-Omega Intel & AMD x86-64 optimizer engine
  target/                    # Unified TargetDesc, regalloc, isel, oir_x64, sm121_pe, fabric, crystallize, gate
  qual/
    x86linux_qual.om         # Standalone x86-64 Linux hardware qualification binary
    sha256.om                # Pure-Omega FIPS 180-4 SHA-256 for qualification receipts
```

## Usage

Requires a sibling `../omega-mv` checkout containing `seed/out/omc` (or pass `OMC=/path/to/omc`). On `x86_64` Linux hosts, `qemu-aarch64-static` (or `qemu-aarch64`) is used only to run the AArch64 `omc` compiler; all emitted `target x86linux` binaries execute natively on the x86-64 CPU.

```sh
sh gate.sh
```
