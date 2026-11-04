# Retro OS USB persistence

## Create a persistent USB

Use a separate Linux computer to prepare the USB. Do not run this against the
computer's internal disk.

1. Download the Retro OS ISO and its adjacent `.sha256` file from the same
   trusted build/release.
2. Insert a USB drive with at least 1 GiB more capacity than the ISO.
3. Identify the whole-disk device with `lsblk` (for example, `/dev/sdb`).
   Never guess the device name.
4. Run:

   ```sh
   sudo /usr/local/sbin/retro-usb-maker \
     --iso /path/to/retro-os-v2.0-amd64.iso \
     --device /dev/sdX
   ```

5. Read the target model and size printed by the utility. It requires typing
   the exact device path before it writes anything.

**Important:** this utility erases the entire selected USB drive when it writes
the ISO. It refuses mounted devices, the running system disk, non-USB /
non-removable disks, missing checksum sidecars, and insufficient free GPT
space. It then adds an ext4 partition labelled `persistence` and writes
`/home union` to its `persistence.conf`.

## What is persistent

Only `/home` is persistent by default. User documents and desktop settings
survive reboots. Machine-specific system configuration, installed packages,
Wi-Fi credentials stored under `/etc`, and Bluetooth pairing state are not
persisted by this default profile.

The persistence filesystem is currently **not encrypted**. Do not store
sensitive information on a USB drive that may be lost or accessed by others.
LUKS support requires a separate design and boot-time unlock validation.

## Validation still required

After provisioning, boot the USB and explicitly choose the **Persistence**
entry in the BIOS/UEFI boot menu. Create a harmless test file under the user's
home directory, reboot, and confirm it remains. Repeat on a second PC to check
hardware portability. QEMU tests cannot prove physical Wi-Fi, Bluetooth,
audio, GPU, or USB-controller compatibility.
