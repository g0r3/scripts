#!/bin/bash

set -e
clear

print_header() {
    echo ""
    echo "********************************************************************************"
    echo "** $1"
    echo "********************************************************************************"
}

setup_fstab() {
    genfstab -pU /mnt >> /mnt/etc/fstab

    # Cleanup double subvol mount entries in fstab
    sed -ie 's;subvolid=[0-9][0-9]*,;;g' /mnt/etc/fstab
    sed -ie 's;subvol=/@,subvol=@;subvol=@;g' /mnt/etc/fstab
    sed -ie 's;subvol=/@home,subvol=@home;subvol=@home;g' /mnt/etc/fstab

    # Check if it was successfull
    if  [ "$(grep -o "@\s" /mnt/etc/fstab | wc -l)" != "1" ] || 
        [ "$(grep -o "subvolid" /mnt/etc/fstab | wc -l)" != "0" ] ||
        [ "$(grep -o "@home\s" /mnt/etc/fstab | wc -l)" != "1" ]; then
            echo "Looks like there is a problem with the btrfs mount points in /mnt/etc/fstab."
            echo "Please check this manually"
            echo "cat /mnt/etc/fstab:"
            cat /mnt/etc/fstab
            exit 1
    fi
}

ping 8.8.8.8 -c 1 > /dev/null

if [ $? -ne 0 ]; then
    echo "There seems to be a problem with the internet connection (Tested with ping 8.8.8.8)"
    exit 1
fi

if [ "$(mount | grep /mnt | wc -l)" -gt 0 ]; then
    echo "Looks like there is something mounted on /mnt. Please unmount and retry."
    exit 1
fi

print_header "Welcome to the Arch Linux installation script!"

# Disk and formating

echo "Available disks:"
lsblk -o NAME,SIZE
echo "Please provide the disk name for the drive to use"
read disk

while [ ! -e "/dev/$disk" ] || [ "$disk" == "" ]; do
    echo "/dev/$disk not found. Please speficy the disk to format: "
    read disk
done

echo "The chosen drive is $disk"
echo "Hit enter to continue..."

partprefix=""

if [[ $disk =~ ^nvme*  ]]; then
        partprefix="p"
fi

swapsize=$(printf "%.0f" $(grep MemTotal /proc/meminfo | awk '{print $2 / 1024^2}'))G
echo "The size of your swap partition will be $swapsize, same as your RAM"
echo "The new disk layout will be like follows:"
echo -e "PARTITION\t\t\tSIZE\t\t\tFSTYPE"
echo -e "/dev/${disk}${partprefix}1\t\t\t512M\t\t\tEFI"
echo -e "/dev/${disk}${partprefix}2\t\t\t${swapsize}\t\t\tSWAP"
echo -e "/dev/${disk}${partprefix}3\t\t\tfilldisk\t\tBTRFS"
echo "Hit enter to continue..."
read
clear


#Timezone and username

echo "Pease enter the desired timezone in the format Region/City"
echo "starting with uppercase, e.g. Europe/Berlin:"
read timezone

while [ ! -e "/usr/share/zoneinfo/$timezone" ] || [ "$timezone" == "" ]; do
    echo "Timezone does not seem to exist. Please try again: "
    read timezone
done
echo "Timezone will be set to $timezone"
echo "Hit enter to continue..."
read
clear

echo "Please enter a password for the root user:"
read -s rootpw

while [ "$rootpw" == "" ]; do
    echo "Password is empty. Please try again: "
    read -s rootpw
done

echo "Password was set. Hit enter to continue..."
read
clear

echo "Please enter a username for a new account:"
read username

while [[ ! "$username" =~ ^[a-z][-a-z0-9]*$ ]]; do
    echo "Wrong username format. Please try again:"
    read username
done
echo "Please enter a password for ${username}:"
read -s userpw

while [ "$userpw" == "" ]; do
    echo "Password is empty. Please try again: "
    read -s userpw
done

echo "Will create account '$username' with specified password"
echo "Hit enter to continue..."
read
clear


echo "All information needed for installation was collected. Do you want to procced [y/n]?"
echo "Warning: If accepting, all data on the target drive will be lost!"
read proceed

while [ "$proceed" != "y"  ] &&
      [ "$proceed" != "n"  ]; do
        echo "Please enter y or n"
        read proceed
done

if [ "$proceed" == "n" ]; then
        echo "No changes have been applied."
        exit 0
fi
clear



print_header "Partitioning disk..."

disk="/dev/$disk"

echo "Current state of disk is:"
lsblk -o NAME,FSTYPE,SIZE $disk

wipefs -af $disk
sgdisk --delete $disk

sgdisk -n 1:2MiB:+512MiB -t 1:ef00 -c 1:EFI $disk
sgdisk -n 2:0:+$swapsize -t 2:8200 -c 2:SWAP $disk
sgdisk -n 3:0:0 -t 2:8300 -c 3:ARCH $disk

echo "Formating finished. New disk layout this:"
lsblk -o NAME,FSTYPE,SIZE $disk



print_header "Creating Filesystems..."

mkfs.vfat -F32 -n EFI ${disk}${partprefix}1
mkswap -L SWAP ${disk}${partprefix}2
swapon ${disk}${partprefix}2
mkfs.btrfs -fL ARCH ${disk}${partprefix}3



print_header "Creating BTRFS subvolumes..."

mount -o defaults,noatime,discard,ssd,nodev ${disk}${partprefix}3 /mnt
cd /mnt
btrfs subvolume create @
btrfs subvolume create @home
cd /
umount /mnt
mount -o defaults,noatime,discard,ssd,nodev,compress=lzo,autodefrag,subvol=@ ${disk}${partprefix}3 /mnt
mkdir -p /mnt/home
mount -o defaults,noatime,discard,ssd,nodev,compress=lzo,autodefrag,subvol=@home ${disk}${partprefix}3 /mnt/home



print_header "Installing base system..."

microcode=$(cat /proc/cpuinfo | grep -m 1 "GenuineIntel" > /dev/null && echo "intel-ucode")

pacman -Sy
pacman -S --noconfirm pacman-contrib
#echo "Determining fastest mirrors..."
#cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup
#sed -i 's/^#Server/Server/' /etc/pacman.d/mirrorlist.backup
#rankmirrors -n 10 /etc/pacman.d/mirrorlist.backup /etc/pacman.d/mirrorlist
#curl -s "https://www.archlinux.org/mirrorlist/?country=DE&country=FR&country=GB&protocol=https&use_mirror_status=on" | sed -e 's/^#Server/Server/' -e '/^#/d' | rankmirrors -n 10 - >> /etc/pacman.d/mirrorlist
#pacstrap /mnt base base-devel linux-zen linux-firmware mlocate mkinitcpio ntfs-3g efibootmgr grub-efi-x86_64 btrfs-progs neovim openssh wpa_supplicant networkmanager git sudo zsh $microcode
pacstrap /mnt base base-devel linux-zen linux-firmware mlocate mkinitcpio ntfs-3g dmidecode efibootmgr refind-efi btrfs-progs neovim openssh wpa_supplicant networkmanager git sudo zsh $microcode

cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist

print_header "Configuring base system..."

# Setup Refind boot manager
PARTUUID=$(ls -lah /dev/disk/by-partuuid | grep $(basename ${disk}${partprefix}3) | awk '{print $9}')
arch-chroot /mnt /bin/bash <<EOF
/usr/bin/mkdir -p /boot/efi
/usr/bin/mount ${disk}${partprefix}1 /boot/efi
/usr/bin/refind-install
/usr/bin/echo '"Boot using standard options"  "root=PARTUUID='${PARTUUID}' rw rootflags=subvol=@ quiet splash loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0 net.ifnames=0"' > /boot/refind_linux.conf
/usr/bin/sed -i '/^#also_scan_dirs.*/c\also_scan_dirs @/boot' /boot/efi/EFI/refind/refind.conf
/usr/bin/sed -i '/^timeout.*/c\timeout 3' /boot/efi/EFI/refind/refind.conf
EOF

setup_fstab

# Add btrfs tools to initramfs
arch-chroot /mnt /bin/bash <<EOF
/usr/bin/sed -i 's,BINARIES=(),BINARIES=(/usr/bin/btrfsck),g' /etc/mkinitcpio.conf
/usr/bin/ln -s /usr/bin/nvim /usr/bin/vim
EOF

# Locale and keyboard
arch-chroot /mnt /bin/bash <<EOF
/usr/bin/echo "KEYMAP=de-latin1" > /etc/vconsole.conf
/usr/bin/echo "desktop" > /etc/hostname
/usr/bin/echo "LANG=en_US.UTF-8" > /etc/locale.conf
/usr/bin/hwclock --systohc --utc
/usr/bin/sed -i '/^#en_US.UTF-8/s/^#//' /etc/locale.gen
/usr/bin/sed -i '/^#de_DE.UTF-8/s/^#//' /etc/locale.gen
/usr/bin/locale-gen
localedef -i de_DE -f UTF-8 en_DE.UTF-8
/usr/bin/ln -s /usr/share/zoneinfo/$timezone /etc/localtime
/usr/bin/mkinitcpio -p linux-zen
EOF


print_header "Installing and configuring daemons..."

arch-chroot /mnt /bin/bash <<EOF
/usr/bin/sed -i 's/^#\[multilib\]/\[multilib\]\nInclude = \/etc\/pacman.d\/mirrorlist/g' /etc/pacman.conf
/usr/bin/pacman -Syu
/usr/bin/pacman -S --noconfirm acpid dbus cups cronie dhcpcd
/usr/bin/systemctl enable acpid
/usr/bin/systemctl enable org.cups.cupsd.service
/usr/bin/systemctl enable cronie
/usr/bin/systemctl enable NetworkManager.service
/usr/bin/systemctl enable dhcpcd
EOF


print_header "Setting up user account..."

# Setup users and sudo
arch-chroot /mnt /bin/bash <<EOF
/usr/bin/echo "root:$rootpw" | /usr/bin/chpasswd
useradd -m -g users -s /bin/zsh $username
/usr/bin/echo "$username:$userpw" | /usr/bin/chpasswd
/usr/bin/sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/g' /etc/sudoers
/usr/bin/gpasswd -a $username wheel
/usr/bin/gpasswd -a $username uucp #For Arduino IDE tty access
/usr/bin/gpasswd -a $username cups #Allow him to change printer settings
EOF


print_header "Installing X-Server ..."

arch-chroot /mnt /bin/bash <<EOF
/usr/bin/pacman -S --noconfirm xorg-server xorg-xinit
EOF
#

print_header "Installing common graphics acceleration packages..."

arch-chroot /mnt /bin/bash <<EOF
/usr/bin/pacman -S --noconfirm mesa vulkan-mesa-layer lib32-mesa
EOF


if [ $(lspci | grep "3D\|VGA" | grep -o "Intel Corporation UHD Graphics" | wc -l) -ge 1 ]; then
    print_header "Installing Intel specific graphics driver..."
    initcpiodrivers="i915 "
    arch-chroot /mnt /bin/bash <<EOF
    /usr/bin/pacman -S --noconfirm xf86-video-intel vulkan-intel
    /usr/bin/sed -i 's,MODULES=(),MODULES=(i915),g' /etc/mkinitcpio.conf
EOF
fi

if [ $(lspci | grep "3D\|VGA" | grep -o "Advanced Micro Devices, Inc" | wc -l) -ge 1 ]; then
    print_header "Installing AMD specific graphics driver..."
    initcpiodrivers=$initcpiodrivers"amdgpu "
    arch-chroot /mnt /bin/bash <<EOF
    /usr/bin/pacman -S --noconfirm amdvlk clang llvm-libs vulkan-radeon xf86-video-amdgpu lib32-vulkan-radeon lib32-llvm
    /usr/bin/sed -i 's,MODULES=(),MODULES=(amdgpu),g' /etc/mkinitcpio.conf
EOF
fi

if [ $(lspci | grep "3D\|VGA" | grep -o "NVIDIA Corporation" | wc -l) -ge 1 ]; then
    print_header "Installing Nvidia specific graphics driver..."
    initcpiodrivers=$initcpiodrivers"nvidia "
    arch-chroot /mnt /bin/bash <<EOF
    /usr/bin/pacman -S --noconfirm nvidia lib32-nvidia-utils
EOF
fi

if [ -z "$initcpiodrivers" ]; then
    arch-chroot /mnt /bin/bash <<EOF
    /usr/bin/sed -i 's,MODULES=(),MODULES=($initcpiodrivers),g' /etc/mkinitcpio.conf
EOF
fi


if [ "$(/mnt/usr/bin/dmidecode -s system-product-name)" == "MACH-WX9" ]; then
    print_header "Matebook Pro X specific config..."

    arch-chroot /mnt /bin/bash <<EOF
    /usr/bin/pacman -S --noconfirm tlp tlp-rdw ethtool lsb-release smartmontools
    /usr/bin/systemctl enable tlp.service
    /usr/bin/systemctl enable tlp-sleep.service
    /usr/bin/systemctl mask systemd-rfkill.service
    /usr/bin/systemctl mask systemd-rfkill.socket
    /usr/bin/sed -i '/^#CPU_SCALING_GOVERNOR_ON_BAT=powersave/c\CPU_SCALING_GOVERNOR_ON_BAT=performance' /etc/tlp.conf
    /usr/bin/sed -i '/^#CPU_SCALING_GOVERNOR_ON_AC=powersave/c\CPU_SCALING_GOVERNOR_ON_AC=performance' /etc/tlp.conf
    /usr/bin/systemctl enable NetworkManager-dispatcher.service
EOF
fi

print_header "Adding pamac for AUR support..."

arch-chroot /mnt /bin/bash <<EOF
/usr/bin/pacman -S --noconfirm itstool vala vte3 appstream-glib meson ninja gobject-introspection
/usr/bin/git clone https://aur.archlinux.org/pamac-aur.git /tmp/pamac-aur
chown nobody /tmp/pamac-aur
cd /tmp/pamac-aur
sudo -u nobody makepkg
/usr/bin/pacman -U *.tar.xz --noconfirm
rm -rf /tmp/pamac
EOF


print_header "Installing KDE Desktop and setting it up..."

arch-chroot /mnt /bin/bash <<EOF
/usr/bin/pacman -S --noconfirm plasma gnome-disk-utility okular dolphin system-config-printer alsa-utils korganizer konsole gnome-calculator gwenview qt5-imageformats kimageformats simple-scan geary kaddressbook partitionmanager kdf ark filelight latte-dock spectacle appmenu-gtk-module lib32-libdbusmenu-glib lib32-libdbusmenu-gtk2 lib32-libdbusmenu-gtk3 libdbusmenu-glib libdbusmenu-gtk2 libdbusmenu-gtk3 libdbusmenu-qt5 kwallet-pam kwalletmanager elisa print-manager
/usr/bin/systemctl enable sddm
#/usr/bin/localectl set-x11-keymap de
EOF


print_header "Installing other stuff..."

arch-chroot /mnt /bin/bash <<EOF
/usr/bin/pacman -S --noconfirm nfs-utils libreoffice keepassxc
EOF
