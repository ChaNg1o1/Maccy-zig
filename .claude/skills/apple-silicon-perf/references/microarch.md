# Apple Silicon microarchitecture facts

Cite these instead of x86 numbers. Applies to M1–M4 family unless noted.

## Cache and memory

- **Cache line: 128 bytes** — twice x86. All padding/alignment for
  false-sharing fixes must use 128, not 64. Zig: `align(128)`; Rust:
  `#[repr(align(128))]`; C/ObjC: `_Alignas(128)` / `alignas(128)`.
- L1D ~128KB (P-core) / 64KB (E-core); L2 shared per cluster (12–16MB on
  P-clusters); no L3 — the System Level Cache (SLC) backs everything.
- **Unified memory**: CPU and GPU share DRAM; very high bandwidth
  (~100–400GB/s depending on chip), and memory-bandwidth-bound loops are
  rarer than on commodity x86. Latency-bound pointer chasing still hurts.
- Page size is **16KB**, not 4KB. Allocation-heavy code amortizes
  differently; `mmap`-granularity tricks tuned for 4KB waste memory.

## Cores and scheduling

- Heterogeneous P-cores (wide, fast) and E-cores (efficient). The scheduler
  places work by **QoS class**: `background`/`utility` → E-cores,
  `user-interactive`/`user-initiated` → P-cores.
- Daemons and timers should declare low QoS and *let* themselves run on
  E-cores; forcing P-core residency wastes energy for invisible gains.
- Thread counts: "number of cores" is not uniform capacity. Scaling
  experiments should report the P/E split (`sysctl hw.perflevel0.physicalcpu
  hw.perflevel1.physicalcpu`).

## SIMD and ISA

- **NEON, 128-bit, no AVX equivalent.** Four 128-bit SIMD pipes per P-core,
  so peak FP throughput comes from 4-way independent NEON operations —
  unrolling with multiple accumulators matters more than vector width.
- Zig `@Vector(4, f32)` / Rust `std::simd` / auto-vectorization all emit
  NEON; there is no wider register to "upconvert" to (the x86 skill's SIMD
  upconversion pattern does not apply).
- M4 adds SME (Scalable Matrix Extension) for matrix workloads — niche;
  reach for the Accelerate framework (vDSP, BLAS, BNNS) before hand-rolling:
  it uses the undocumented AMX/SME units and is the sanctioned path.
- Hardware CRC32 and AES instructions exist (ARMv8 crypto extensions); Zig
  std.hash.crc and CommonCrypto already use them — do not hand-roll.

## Atomics and locks

- ARMv8.1 **LSE atomics** (ldadd, swp, cas) are available and used by Zig,
  Rust, and clang by default on Apple targets. Contended CAS loops still
  bounce the (128-byte) line exactly like x86.
- Prefer `os_unfair_lock` over pthread mutex for short critical sections in
  ObjC; Zig `std.Thread.Mutex` and Rust `parking_lot`/std are fine.
- The load-acquire/store-release model is weaker than x86-TSO: code that
  "worked" on x86 with relaxed ordering may be a data race here. Correctness
  first — never weaken orderings as an optimization without a proof.

## Branch/frontend

- Deep frontends with large branch predictors; mispredict penalty ~13–16
  cycles. Cold-path hints (`@branchHint(.unlikely)` in Zig, `#[cold]` in
  Rust, `__builtin_expect` in C/ObjC) still pay off in hot loops.
- Instruction cache is large (192KB L1I on P-cores) but inlining bloat in
  hot loops still evicts; keep error/logging paths out-of-line.
