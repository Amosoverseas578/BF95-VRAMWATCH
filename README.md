# BF95 VRAMWATCH

Compact terminal dashboards for monitoring ComfyUI workloads on Ubuntu/Linux with either AMD ROCm or NVIDIA CUDA GPUs.

The repository includes two platform-specific scripts:

| Script | Platform | GPU telemetry |
|---|---|---|
| `BF95-AMD-VRAMWATCH.sh` | AMD ROCm | `amd-smi` |
| `BF95-CUDA-VRAMWATCH.sh` | NVIDIA CUDA | `nvidia-smi` |

## Features

- GPU VRAM usage and free VRAM
- System RAM, available RAM, and swap usage
- ComfyUI process RSS, anonymous memory, swap, and total footprint
- Peak RSS, kernel `VmHWM`, lowest available RAM, and process uptime
- Short and long RSS trends to expose gradual memory accumulation
- Major page-fault rate, swap-in/out activity, and Linux PSI memory pressure
- GPU utilization and memory-controller activity
- GPU temperatures, cooling, power draw, and clock speeds
- Rolling 60-second memory guard with percentage-based warning thresholds
- Colour dashboard with ASCII and no-colour modes
- No sudo requirement and no continuous kernel-log scanning

## Requirements

### Common

- Ubuntu or another Linux distribution with `/proc`
- Bash
- Standard tools including `awk`, `grep`, `getconf`, and `ps`
- ComfyUI launched as a Python `main.py` process

### AMD version

- A supported AMD GPU and ROCm installation
- `amd-smi` available in `PATH`

### NVIDIA version

- A supported NVIDIA GPU and proprietary NVIDIA driver
- `nvidia-smi` available in `PATH`

Some NVIDIA telemetry, such as VRAM temperature, is hardware- and driver-dependent. Unsupported values are displayed as `N/A`.

## Installation

Clone or download the repository, then make the appropriate script executable:

```bash
chmod +x BF95-AMD-VRAMWATCH.sh
chmod +x BF95-CUDA-VRAMWATCH.sh
```

No Python packages or additional libraries are required.

## Usage

### AMD ROCm

```bash
./BF95-AMD-VRAMWATCH.sh
```

### NVIDIA CUDA

```bash
./BF95-CUDA-VRAMWATCH.sh
```

### Common options

```text
-g, --gpu ID          GPU index to watch (default: 0)
-i, --interval SEC    Refresh interval in seconds (default: 2)
-w, --width COLS      Meter width, 10-60 (default: 32)
-1, --once            Print one snapshot and exit
    --no-color        Disable ANSI colours
    --ascii           Use ASCII bar characters
-h, --help            Show help
```

Examples:

```bash
./BF95-AMD-VRAMWATCH.sh --gpu 0 --interval 1
./BF95-CUDA-VRAMWATCH.sh --once
NO_COLOR=1 ./BF95-AMD-VRAMWATCH.sh
```

## ComfyUI process detection

By default, the scripts look for a process matching:

```text
[p]ython.*main.py
```

Override the pattern when needed:

```bash
VRAMWATCH_COMFY_PATTERN='python.*main.py' ./BF95-AMD-VRAMWATCH.sh
```

## Memory guard

The memory guard uses a rolling 60-second average so normal short-lived render spikes do not immediately trigger a restart warning.

Default thresholds scale with installed system RAM:

- **Caution:** available RAM below 20%, ComfyUI RSS above 75%, or ComfyUI swap at or above 2 GiB
- **Critical:** available RAM below 10% or ComfyUI RSS above 85%

The thresholds and trend windows can be changed with environment variables. Run either script with `--help` to see the supported variables.

## Notes

- High VRAM use can be normal during image generation. Sustained low available system RAM, rising ComfyUI RSS, active swap I/O, and major page faults are stronger indicators of memory pressure.
- The AMD version uses the current `amd-smi` interface rather than the deprecated `rocm-smi` command.
- The CUDA version has been Bash syntax-tested and exercised with representative `nvidia-smi` output, but has not yet been validated by the author on physical NVIDIA hardware. Reports and fixes from NVIDIA users are welcome.

## License

MIT License. See `LICENSE`.
