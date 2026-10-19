# Retro OS v2.0 — source scaffold

Ubuntu 24.04 Noble / amd64, modular stages, minimal Wayland session and local Bujji CLI.

## Verify
```bash
bash scripts/verify.sh
```

## Build
Use a disposable Ubuntu 24.04 amd64 build host or VM with internet access:
```bash
sudo bash scripts/build.sh
```
Output is placed in `out/`. Building requires significant disk space and time.

## Important release gates
This repository is an initial functional engineering scaffold, not a certified production OS image.
Before installing on physical hardware:
1. Audit every stage script and package source.
2. Test live boot in both BIOS and UEFI VMs.
3. Complete and test a rootfs-copy + bootloader installation path. The installer currently lays out partitions and Btrfs subvolumes but intentionally does not pretend to install an OS payload.
4. Test Btrfs root layout, fstab, initramfs, GRUB, rollback, and recovery from a separate live environment.
5. Review nftables policy, USBGuard rules and Tor application routing for your deployment.
6. Benchmark idle RAM on the target hardware.
7. Do not claim guaranteed RAM zeroization: Linux cannot guarantee clearing all volatile memory through a userspace command.

## Notes
- `metasploit-framework` and `rustscan` are not silently fetched from unverified sources. The security stage installs them only if enabled APT repositories offer the package.
- The Tor controller manages the Tor daemon only; it cannot guarantee that all applications route through Tor.
- tty1 autologin is not enabled by default because it weakens physical-access security.
