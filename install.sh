# Ensure system clock is accurate
timedatectl set-ntp true

# Format the disk, creating three partitions:
# EFI	/dev/sda1	512M	ef00
# Root	/dev/sda2	<FREE>	8309
gdisk /dev/sda

# Format ESP volume
mkfs.vfat -F32 -n EFI /dev/sda1

# Create an encrypted disk on /dev/sda2
cryptsetup luksFormat --type luks1 /dev/sda2
cryptsetup open /dev/sda2 cryptroot

# Create a filesystem on the encrypted root
mkfs.btrfs -L root /dev/mapper/cryptroot

# Mount encrypted root
mount /dev/mapper/cryptroot /mnt

# Create top-level subvolumes
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@swap

# Unmount encrypted root
umount /mnt

# Mount subvolumes
mount -o compress=lzo,subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/home
mount -o compress=lzo,subvol=@home /dev/mapper/cryptroot /mnt/home
mkdir -p /mnt/.snapshots
mount -o compress=lzo,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots

# Create subvolumes for directories to be excluded from snapshots
mkdir -p /mnt/var/cache/pacman
btrfs subvolume create /mnt/var/cache/pacman/pkg
btrfs subvolume create /mnt/var/abs
btrfs subvolume create /mnt/var/tmp
btrfs subvolume create /mnt/srv

# Create swapfile
mkdir -p /mnt/.swap
mount -o subvol=@swap /dev/mapper/cryptroot /mnt/.swap
touch /mnt/var/swap/swapfile
fallocate --length 16GiB /mnt/.swap/swapfile
chmod 600 /mnt/var/swap/swapfile
mkswap /mnt/var/swap/swapfile

# Enable swap (not necessary, but nice to test it works)
swapon /mnt/var/swap/swapfile

# Mount boot/ESP volume
mkdir -p /mnt/boot
mount /dev/sda1 /mnt/boot

# Bootstrap the new system
pacstrap /mnt base base-devel linux linux-lts linux-firmware btrfs-progs efibootmgr zsh neovim git man-db intel-ucode

# Generate fstab/crypttab files. Spot check this file to make sure it's correct
genfstab -U /mnt >> /mnt/etc/fstab

# Enter the new system
arch-chroot /mnt /bin/bash

# Set timezone
ln -s /usr/share/zoneinfo/America/Los_Angeles /etc/localtime
hwclock --systohc --utc

# Set hostname
echo coruscant > /etc/hostname

# Update hosts with hostname:
#
# ```
# 127.0.0.1	localhost
# ::1		localhost
# 127.0.1.1	myhostname.localdomain	myhostname
# ```
vim /etc/hosts

# Edit out any unwanted locales, generate, and set locale
vim /etc/locale.gen
locale-gen
localectl set-locale LANG=en_US.UTF-8
echo LANG=en_US.UTF-8 >> /etc/locale.conf

# Set console keymap
echo "KEYMAP=us" > /etc/vconsole.conf

# Regenerate initramfs with encryption modules
#
# ```
# BINARIES=(/usr/bin/btrfs)
# FILES=()
# HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block sd-encrypt filesystems resume fsck)
# ```
nvim /etc/mkinitcpio.conf
mkinitcpio -p linux
mkinitcpio -p linux-lts

# Install boot loader
bootctl --path=/boot install

# Write a boot configuration for the Linux kernel (substitute in the device UUID here)
tee /boot/loader/entries/linux.conf << 'EOF' > /dev/null
title Arch Linux
linux /vmlinuz-linux
initrd /intel-ucode.img
initrd /initramfs-linux.img
options rd.luks.name=<UUID>=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rd.luks.options=discard rw
EOF

tee /boot/loader/entries/linux-fallback.conf << 'EOF' > /dev/null
title Arch Linux (Fallback)
linux /vmlinuz-linux
initrd /intel-ucode.img
initrd /initramfs-linux-fallback.img
options rd.luks.name=<UUID>=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rd.luks.options=discard rw
EOF

# Write a boot configuration for the Linux LTS kernel (substitute in the device UUID here)
tee /boot/loader/entries/linux-lts.conf << 'EOF' > /dev/null
title Arch Linux LTS
linux /vmlinuz-linux-lts
initrd /intel-ucode.img
initrd /initramfs-linux-lts.img
options rd.luks.name=<UUID>=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rd.luks.options=discard rw
EOF

tee /boot/loader/entries/linux-lts-fallback.conf << 'EOF' > /dev/null
title Arch Linux LTS (Fallback)
linux /vmlinuz-linux-lts
initrd /intel-ucode.img
initrd /initramfs-linux-lts-fallback.img
options rd.luks.name=<UUID>=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rd.luks.options=discard rw
EOF

# Write the main boot configuration
tee /boot/loader/loader.conf << 'EOF' > /dev/null
default linux.conf
timeout 5
console-mode max
editor no
EOF

# Add a pacman hook to update the bootloader whenever systemd-boot is updated
sudo tee /etc/pacman.d/hooks/100-systemd-boot.hook << 'EOF' > /dev/null
[Trigger]
Type = Package
Operation = Upgrade
Target = systemd

[Action]
Description = Updating systemd-boot
When = PostTransaction
Exec = /usr/bin/bootctl update
EOF

# Optionally, mount a Windows boot partition and copy its bootloader into the /boot partition to allow
# systemd-boot to detect and boot Windows volumes:
mkdir -p /mnt/tmp
mount /dev/sdxY /mnt/tmp
cp -r /mnt/tmp/EFI/Microsoft /boot/EFI

# TODO: Enable secure boot

##
# Users
##

# Add wheel group to sudoers
# (Uncomment the %wheel line)
EDITOR=nvim visudo

# Create user
useradd -m -g users -G wheel -s /bin/zsh ndhoule
passwd ndhoule

##
# Security
##

# Disable root login
passwd ---lock root

# Add the following two lines to add a 5s delay between failed logins and
# lock a user out for 5m after 5 failed logins in a row:
#
# ```
# auth       optional   pam_faildelay.so delay=5000000
# auth       requisite  pam_faillock.so preauth deny=5 unlock_time=300
# ```
nvim /etc/pam.d/system-login

##
# Cleanup
##

# Exit chroot
exit

# Clean up and reboot into installation
swapoff -a
umount -R /mnt
reboot
