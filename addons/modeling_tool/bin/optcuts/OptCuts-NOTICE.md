# OptCuts build and license notice

TopoPPI uses a pinned, residue-aware build of [OptCuts](https://github.com/liminchen/OptCuts) for topology editing and UV optimization. This directory includes the Linux x86-64 executable used by source checkouts. Release installers carry a native executable for their target platform.

## Provenance

| Item | Value |
| --- | --- |
| Upstream commit | `cd2302671af7954f263b0ea93d8419aa943d54be` |
| Linux format | ELF 64-bit PIE, x86-64, dynamically linked |
| Linux compatibility baseline | glibc 2.17, GCC 12.4 toolchain |
| Image helper | Statically linked vendored code |
| Linux release artifact | `OptCuts_bin-linux-x86_64` |
| Windows release artifact | `OptCuts_bin-windows-x86_64.exe` |
| Linux SHA-256 | `d7990fc4f1ca46e0ba06b70801b64701dfdeb795f7efee6f7b9f197aa3b426eb` |
| Python distribution contents | Python code and build instructions; native executables use platform artifacts |

The pinned source and patch set build both the complete residue-aware objective and its weight-zero geometry ablation. The integration provides:

- residue-footprint fragmentation energy supplied through a versioned sidecar;
- validated topology candidates and deterministic candidate-level TBB parallelism;
- sparse local split and merge solves;
- accelerated confirmed A-B-A-B topology cycles through OptCuts' critical-lambda query;
- topology identity based on face-corner connectivity and cohesive-edge state; and
- round-trip `double` precision for mesh coordinates.

The release build defines `EIGEN_MPL2_ONLY`. OptCuts and libigl quadratic solves use Eigen SparseLU, which keeps Eigen's LGPL-gated sparse Cholesky implementation out of the executable. The build fails if an LGPL-gated Eigen header is included.

The complete objective and geometry ablation share the same candidate policy. See the [residue-aware integration guide](./residue_aware/README.md) for the sidecar and state engine, and the [benchmark evidence schema](../../docs/benchmark_schema.md#residue-footprint-fragmentation) for reported measurements.

## Platform artifacts

The `Windows Installer` workflow builds the pinned source for Windows x86-64, embeds it in `TopoPPI-<version>-windows-x86_64-setup.exe`, and passes the standalone executable and its `.sha256` file to the central publication workflow.

The `macOS App` workflow builds the same source natively for Apple Silicon and Intel. Each architecture-matched disk image contains its OptCuts executable.

## License

Upstream OptCuts includes MIT License text without a copyright notice line. [`LICENSE.txt`](./LICENSE.txt) is copied from that upstream file and accompanies the build provenance in source archives and separately published binaries.

The executable also contains statically linked code from TBB, libigl, Eigen, GLFW, Triangle, stb, glad, and the Khronos platform header. Their full notices are in [`THIRD_PARTY_LICENSES.txt`](./THIRD_PARTY_LICENSES.txt) and accompany every standalone executable and installer.

Triangle 1.6 permits redistribution when no compensation is received. Commercial-system distribution requires direct arrangement with its author. This condition applies to the bundled OptCuts executable.

The corresponding source is available from the pinned [OptCuts commit](https://github.com/liminchen/OptCuts/tree/cd2302671af7954f263b0ea93d8419aa943d54be), its vendored libigl and Eigen trees, the pinned [TBB commit](https://github.com/wjakob/tbb/tree/344fa84f34089681732a54f5def93a30a3056ab9), and the patches in this directory.
