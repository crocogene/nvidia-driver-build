# NVIDIA Driver Kernel Module Builder

`nvidia-driver-build.sh` builds and installs NVIDIA GPU kernel modules for the
currently running kernel. It fetches available NVIDIA x86_64 driver releases,
lets you choose from the five newest versions, verifies the installer archive
with NVIDIA's published MD5 checksum, builds the modules, installs them, and
refreshes the initramfs for the next boot.

## Supported system

This script is intended **only for Chimera Linux**. It uses Chimera's `apk`
package manager to identify the installed kernel variant, Chimera's
`update-initramfs` workflow, and `doas` for privileged installation steps. It
has not been designed or tested for other Linux distributions.

The script downloads NVIDIA's x86_64 `.run` package, so the system must also be
x86_64 and the selected NVIDIA driver must support the GPU.

## Requirements

- A Chimera Linux x86_64 system with an NVIDIA GPU
- The kernel development package matching the running kernel, such as
  `linux-stable-devel` or `linux-lts-devel`
- `curl`, `md5sum`, `make`, `modinfo`, `doas`, `apk`, and `update-initramfs`
- Permission to run the installation commands through `doas`

For example, install stable-kernel development files with:

```sh
doas apk add linux-stable-devel
```

Use `linux-lts-devel` instead when running Chimera's LTS kernel. The headers
must match the kernel reported by `uname -r`.

## Usage

From the directory containing the script, run:

```sh
./nvidia-driver-build.sh
```

The script lists the five newest NVIDIA driver versions. Press Enter to select
the newest version, or enter another displayed choice.

The selected `.run` archive is stored beside the script and reused only when
its MD5 checksum matches NVIDIA's checksum file; otherwise, it is downloaded
again and verified. The archive is unpacked beside the script for the build,
then the extracted driver directory is removed after a successful installation.

The script builds the modules against the running kernel, copies all generated
`.ko` files into `/lib/modules/<kernel-release>/extra/nvidia`, runs `depmod`,
adds the modules to Chimera's initramfs module list, and updates the initramfs
for that kernel.

The script installs kernel modules only; it does not install or configure the
NVIDIA user-space driver components.
