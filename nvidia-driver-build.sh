#!/usr/bin/env bash

set -euo pipefail

index_url="https://download.nvidia.com/XFree86/Linux-x86_64/"
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

for command in apk curl md5sum make modinfo doas update-initramfs; do
    command -v "$command" >/dev/null 2>&1 || {
        printf 'Required command not found: %s\n' "$command" >&2
        exit 1
    }
done

kernel_release=$(uname -r)
kernel_build_dir="/lib/modules/$kernel_release/build"
if [[ ! -f "$kernel_build_dir/Makefile" || ! -f "$kernel_build_dir/.config" ]]; then
    printf 'Kernel headers for %s are not installed.\n' "$kernel_release" >&2
    kernel_devel_package=$(apk list --installed | awk -v release="$kernel_release" '
        $1 ~ /^linux-(stable|lts)-[0-9]/ {
            name = $1
            sub(/^linux-/, "", name)
            split(name, parts, "-")
            if (index(release, parts[2] "-") == 1) {
                print "linux-" parts[1] "-devel"
                exit
            }
        }
    ')
    if [[ -n $kernel_devel_package ]]; then
        printf 'Detected kernel variant; install its headers with: doas apk add %s\n' \
            "$kernel_devel_package" >&2
    else
        printf 'Could not identify the matching kernel package via apk list --installed.\n' >&2
        printf 'Install the matching linux-stable-devel or linux-lts-devel package.\n' >&2
    fi
    printf 'If the package updates the kernel, reboot into that kernel before retrying.\n' >&2
    exit 1
fi

printf 'Fetching NVIDIA driver versions...\n'
index_html=$(curl --fail --location --silent --show-error "$index_url")
mapfile -t versions < <(
    printf '%s\n' "$index_html" \
        | grep -oE "href=['\"][0-9]+(\\.[0-9]+)+/['\"]" \
        | sed -E "s/^href=['\"]//; s/['\"]$//; s|/$||" \
        | sort -Vru \
        | sed -n '1,5p'
)

(( ${#versions[@]} > 0 )) || {
    printf 'No NVIDIA driver versions found at %s\n' "$index_url" >&2
    exit 1
}

printf '\nAvailable NVIDIA driver versions (latest first):\n'
for i in "${!versions[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "${versions[$i]}"
done

while true; do
    printf 'Choose a version [1]: '
    IFS= read -r choice || choice=''
    choice=${choice:-1}

    if [[ $choice =~ ^[1-5]$ ]] && (( choice <= ${#versions[@]} )); then
        break
    fi
    printf 'Please enter a number from 1 to %d.\n' "${#versions[@]}" >&2
done

version=${versions[$((choice - 1))]}
archive_name="NVIDIA-Linux-x86_64-$version.run"
archive_path="$script_dir/$archive_name"
source_dir="$script_dir/NVIDIA-Linux-x86_64-$version"
archive_url="$index_url$version/$archive_name"
checksum_url="$archive_url.md5sum"

printf '\nFetching checksum for %s...\n' "$archive_name"
expected_md5=$(curl --fail --location --silent --show-error "$checksum_url" | awk 'NF {print $1; exit}')
[[ $expected_md5 =~ ^[[:xdigit:]]{32}$ ]] || {
    printf 'Could not read a valid MD5 checksum from %s\n' "$checksum_url" >&2
    exit 1
}
expected_md5=${expected_md5,,}

download_archive=false
if [[ -s $archive_path ]]; then
    actual_md5=$(md5sum "$archive_path" | awk '{print $1}')
    if [[ ${actual_md5,,} == "$expected_md5" ]]; then
        printf 'Existing archive checksum is valid; skipping download.\n'
    else
        printf 'Existing archive checksum mismatch; downloading a fresh copy.\n' >&2
        download_archive=true
    fi
else
    download_archive=true
fi

if [[ $download_archive == true ]]; then
    temporary_archive="$archive_path.part"
    rm -f "$temporary_archive"
    printf 'Downloading %s...\n' "$archive_name"
    curl --fail --location --retry 3 --output "$temporary_archive" "$archive_url"

    actual_md5=$(md5sum "$temporary_archive" | awk '{print $1}')
    if [[ ${actual_md5,,} != "$expected_md5" ]]; then
        rm -f "$temporary_archive"
        printf 'Downloaded archive MD5 mismatch for %s\n' "$archive_name" >&2
        exit 1
    fi

    mv -f "$temporary_archive" "$archive_path"
    printf 'Downloaded archive checksum verified.\n'
fi

if [[ -f "$source_dir/kernel/Makefile" ]]; then
    printf 'Using already-unpacked NVIDIA driver %s\n' "$version"
elif [[ -e $source_dir ]]; then
    printf 'Incomplete NVIDIA source directory exists: %s\n' "$source_dir" >&2
    printf 'Remove it before retrying extraction.\n' >&2
    exit 1
else
    printf '\nUnpacking NVIDIA driver %s...\n' "$version"
    (cd "$script_dir" && sh "$archive_path" --extract-only)
fi

cd "$source_dir/kernel" || {
    printf 'Cannot enter NVIDIA kernel source directory: %s/kernel\n' "$source_dir" >&2
    exit 1
}
[[ -f Makefile ]] || {
    printf 'Makefile not found in %s\n' "$PWD" >&2
    exit 1
}

printf '\nBuilding NVIDIA kernel modules...\n'
make

[[ -f nvidia.ko ]] || {
    printf 'nvidia.ko not found after build\n' >&2
    exit 1
}

ver=$(modinfo -F vermagic nvidia.ko | awk '{print $1}')
[[ -n $ver ]] || {
    printf 'Cannot determine kernel version from nvidia.ko\n' >&2
    exit 1
}

shopt -s nullglob
modules=( *.ko )
(( ${#modules[@]} > 0 )) || {
    printf 'No NVIDIA kernel modules found after build\n' >&2
    exit 1
}

dst="/lib/modules/$ver/extra/nvidia"
doas mkdir -p "$dst"

for module in "${modules[@]}"; do
    printf 'Copying %s -> %s/%s\n' "$PWD/$module" "$dst" "$module"
    doas cp -v "$module" "$dst/"
done

doas depmod "$ver"

initramfs_modules=/etc/initramfs-tools/modules
doas mkdir -p "${initramfs_modules%/*}"
doas touch "$initramfs_modules"
for module in "${modules[@]}"; do
    module_name=${module%.ko}
    if ! doas grep -Fxq "$module_name" "$initramfs_modules"; then
        printf '%s\n' "$module_name" | doas tee -a "$initramfs_modules" >/dev/null
    fi
done

doas update-initramfs -u -k "$ver"

cd "$script_dir"
rm -rf -- "$source_dir"

printf '\nDone for NVIDIA driver %s and kernel %s\n' "$version" "$ver"
