# Zadanie 1: Gentoo na VM — dziennik poleceń

Kolejność zgodna z faktycznym przebiegiem instalacji (VirtualBox, UEFI, systemd).
Środowisko VM: 6 vCPU, 4 GB RAM, dysk 52 GB (`/dev/sda`), sieć NAT.

---

## 0. Przygotowanie VM (VirtualBox, ustawienia)

- Typ systemu: Linux → Gentoo (64-bit)
- System → Płyta główna → **Włącz EFI**
- Kontroler dysku: SATA/AHCI (domyślny) → dysk widoczny jako `/dev/sda`
- Płyta: Gentoo Minimal Installation CD (amd64)
- Sieć → Karta 1 → Zaawansowane → Przekierowanie portów: TCP, host `2222` → gość `22`

## 1. System live: weryfikacja i dostęp przez SSH

W oknie VM (wpisane ręcznie, bo konsola VirtualBox nie obsługuje schowka):

```bash
ls /sys/firmware/efi        # weryfikacja trybu UEFI (katalog musi istnieć)
ip a                        # czy jest adres IP
ping -c 3 gentoo.org        # czy jest internet
passwd                      # tymczasowe hasło roota w systemie live
rc-service sshd start       # system live używa OpenRC
```

Z hosta (Git Bash):

```bash
ssh -p 2222 root@127.0.0.1
```

## 2. Partycje (GPT, UEFI)

```bash
lsblk                       # dysk sda pusty, bez partycji
fdisk /dev/sda
```

Sekwencja w fdisk:

```
g                           # nowa tablica partycji GPT
n, Enter, Enter, +1G        # sda1: ESP
t, uefi                     # typ: EFI System
n, Enter, Enter, +4G        # sda2: swap
t, 2, swap                  # typ: Linux swap
n, Enter, Enter, Enter      # sda3: root (reszta dysku, typ Linux filesystem)
p                           # podgląd
w                           # zapis i wyjście
```

Układ:

| Partycja | Rozmiar | Typ | Przeznaczenie |
|---|---|---|---|
| /dev/sda1 | 1 GB | EFI System | ESP (`/efi`) |
| /dev/sda2 | 4 GB | Linux swap | swap |
| /dev/sda3 | ~47 GB | Linux filesystem | root (`/`) |

## 3. Systemy plików i montowanie

```bash
mkfs.vfat -F 32 /dev/sda1
mkswap /dev/sda2
swapon /dev/sda2
mkfs.ext4 /dev/sda3

mkdir --parents /mnt/gentoo
mount /dev/sda3 /mnt/gentoo
lsblk                       # sda3 → /mnt/gentoo (jeden wpis!), sda2 → [SWAP]
```

> Uwaga: podwójne `mount` daje dwa wpisy w `lsblk`. Naprawa: jednorazowe `umount /mnt/gentoo`.

## 4. Stage3 (systemd)

```bash
cd /mnt/gentoo
chronyd -q                  # synchronizacja zegara (ostrzeżenia o /run/chrony są niegroźne)

wget https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-systemd.txt
STAGE=$(grep 'tar.xz' latest-stage3-amd64-systemd.txt | awk '{print $1}')
echo $STAGE
wget https://distfiles.gentoo.org/releases/amd64/autobuilds/$STAGE
ls -lh stage3-*.tar.xz      # kontrola rozmiaru (kilkaset MB)

tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo
ls /mnt/gentoo
ls -l /mnt/gentoo/etc/portage/make.conf

rm /mnt/gentoo/stage3-*.tar.xz /mnt/gentoo/latest-stage3-amd64-systemd.txt
```

## 5. make.conf

```bash
nproc                       # 6
free -g                     # 4 GB
nano /mnt/gentoo/etc/portage/make.conf
```

Zmiany w pliku:

```bash
COMMON_FLAGS="-O2 -pipe -march=native"
MAKEOPTS="-j2 -l2"          # ograniczone przez RAM (~2 GB na zadanie), nie przez liczbę rdzeni
VIDEO_CARDS=""              # system bez grafiki
```

## 6. DNS dla chroota

```bash
rm -f /mnt/gentoo/etc/resolv.conf
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
cat /mnt/gentoo/etc/resolv.conf     # musi zawierać linię "nameserver ..."
```

> Bez tego kroku `emerge-webrsync` w chroocie kończy się błędem `unable to resolve host address`.

## 7. Chroot

```bash
arch-chroot /mnt/gentoo
source /etc/profile         # komunikat "tty: ttyname error" jest niegroźny (SSH + chroot)
export PS1="(chroot) ${PS1}"
ls /mnt                     # pusty = jesteśmy w chroocie

mkdir -p /efi
mount /dev/sda1 /efi
ping -c 2 gentoo.org        # weryfikacja DNS
```

## 8. Repozytorium ebuildów i profil

```bash
emerge-webrsync
eselect profile list
eselect profile show        # default/linux/amd64/23.0/systemd (ustawiony przez stage3)
```

## 9. USE flags

```bash
portageq envvar USE | tr ' ' '\n'           # przegląd flag z profilu

emerge --ask --oneshot app-portage/cpuid2cpuflags
echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags
cat /etc/portage/package.use/00cpu-flags
# */* CPU_FLAGS_X86: aes bmi1 bmi2 mmx mmxext pclmul popcnt rdrand sse sse2 sse3 sse4_1 sse4_2 sse4a ssse3

grep -w '^seccomp' /var/db/repos/gentoo/profiles/use.desc   # sprawdzanie znaczenia flagi
```

## 10. Strefa czasowa i locale

```bash
ln -sf ../usr/share/zoneinfo/Europe/Warsaw /etc/localtime
nano /etc/locale.gen        # odkomentowane: en_US.UTF-8 UTF-8, pl_PL.UTF-8 UTF-8
locale-gen
eselect locale list
eselect locale set 4        # en_US.UTF-8
env-update && source /etc/profile && export PS1="(chroot) ${PS1}"
```

## 11. Przebudowa systemu

```bash
emerge --pretend --verbose --update --deep --changed-use @world   # podgląd planu
emerge --ask --verbose --update --deep --changed-use @world
```

```bash
eselect news read           # przegląd komunikatów Gentoo
emerge --pretend --depclean
emerge --ask --depclean     # usunięcie zbędnych paczek
```

## 12. Rozpoznanie sprzętu VM

```bash
emerge --ask sys-apps/pciutils
lspci -k                    # "Kernel driver in use" = lista potrzebnych sterowników
lsmod
```

Wynik (VirtualBox): AHCI → `ahci`, Intel PRO/1000 → `e1000`, USB OHCI/EHCI, PIIX4 IDE → `ata_piix`,
AC'97 → `snd_intel8x0` (pominięte), VMware SVGA II, VirtualBox Guest Service (pominięte).

## 13. Źródła i konfiguracja kernela

```bash
emerge --ask sys-kernel/gentoo-sources
eselect kernel list
eselect kernel set 1
ls -l /usr/src/linux

cd /usr/src/linux
make defconfig              # punkt wyjścia: x86_64 defconfig
make menuconfig             # własne zmiany (wyszukiwanie: "/", spacja przełącza [*]/[M]/[ ])
```

Opcje ustawione / zweryfikowane jako `=y` (bez initramfs, więc sterowniki bootu wbudowane):

```
SATA_AHCI  BLK_DEV_SD  E1000  EXT4_FS  VFAT_FS  NLS_CODEPAGE_437  NLS_ISO8859_1
EFI  EFI_STUB  EFI_PARTITION  DEVTMPFS  DEVTMPFS_MOUNT
SYSFB_SIMPLEFB  DRM_SIMPLEDRM  DRM_FBDEV_EMULATION  FRAMEBUFFER_CONSOLE
GENTOO_LINUX_INIT_SYSTEMD   (GENTOO_LINUX_INIT_SCRIPT wyłączone: to opcja dla OpenRC)
```

> `FRAMEBUFFER_CONSOLE` jest niewidoczna, dopóki nie włączy się `DRM_FBDEV_EMULATION`.

```bash
grep -E 'CONFIG_(SATA_AHCI|BLK_DEV_SD|E1000|EXT4_FS|VFAT_FS|EFI|EFI_STUB|EFI_PARTITION|DEVTMPFS|DEVTMPFS_MOUNT|SYSFB_SIMPLEFB|DRM_SIMPLEDRM|FRAMEBUFFER_CONSOLE|GENTOO_LINUX_INIT_SYSTEMD)=' .config
grep -E 'CONFIG_NLS_(CODEPAGE_437|ISO8859_1)=' .config
```

Porównanie z gotowcem (po kompilacji):

```bash
make KCONFIG_CONFIG=/root/config-defconfig defconfig
scripts/diffconfig /root/config-defconfig .config > /root/kernel-diff.txt
```

Kopia do repozytorium (na HOŚCIE, w katalogu repo — nie w VM):

```bash
scp -P 2222 root@127.0.0.1:/mnt/gentoo/usr/src/linux/.config zadanie-1-gentoo-vm/kernel/config
scp -P 2222 root@127.0.0.1:/mnt/gentoo/root/config-defconfig zadanie-1-gentoo-vm/kernel/config-defconfig
scp -P 2222 root@127.0.0.1:/mnt/gentoo/root/kernel-diff.txt docs/zadanie-1/dowody/kernel-diff.txt
```

## 14. Kompilacja i instalacja kernela

```bash
make -j2
make modules_install
emerge --ask sys-kernel/installkernel
make install
ls -l /boot                 # kernel-6.18.57-gentoo
```

## 15. fstab

```bash
blkid
nano /etc/fstab
```

Wersja końcowa (PARTUUID — identyfikator partycji GPT):

```
PARTUUID=bf4072c6-7b0f-4872-9e8a-65bc4dc820de   /efi   vfat   umask=0077         0 2
PARTUUID=8d725be8-a1e2-479f-a497-eeeb2638cb68   none   swap   sw                 0 0
PARTUUID=0e7fe9d7-7c6e-4c27-bb66-518a6cdc80b5   /      ext4   defaults,noatime   0 1
```

> Błędy z pierwszego startu: (1) wartości PARTUUID wpisane jako `UUID=` → systemd czeka 90 s na
> nieistniejące urządzenie → emergency mode, root zostaje `ro`; (2) brak `/` w linii root →
> `Mount point ext4 is not a valid path`.

## 16. Tożsamość, konta, usługi, sieć

```bash
echo gentoo-vm > /etc/hostname
passwd                                      # hasło roota nowego systemu
useradd -m -G wheel -s /bin/bash <login>
passwd <login>

systemd-machine-id-setup
systemctl preset-all --preset-mode=enable-only
systemctl enable sshd

nano /etc/systemd/network/50-dhcp.network
```

```ini
[Match]
Name=en*

[Network]
DHCP=yes
```

```bash
systemctl enable systemd-networkd systemd-resolved
```

## 17. GRUB (UEFI)

```bash
echo 'GRUB_PLATFORMS="efi-64"' >> /etc/portage/make.conf
emerge --ask sys-boot/grub
grub-install --efi-directory=/efi --removable   # ścieżka zapasowa EFI/BOOT/BOOTX64.EFI (VirtualBox gubi wpisy NVRAM)
grub-mkconfig -o /boot/grub/grub.cfg
grep -E '^\s*linux\s' /boot/grub/grub.cfg        # root=PARTUUID=... (nie UUID= — brak initramfs)
```

## 18. Wyjście z chroota i pierwszy start

```bash
exit
ln -snf /run/systemd/resolve/resolv.conf /mnt/gentoo/etc/resolv.conf   # poza chrootem (w chroocie plik jest bind-mountem)
cd /
fuser -vm /mnt/gentoo       # kto blokuje odmontowanie (u mnie: zawieszony vim → kill -9 <PID>)
umount -R /mnt/gentoo       # awaryjnie: sync && umount -R -l /mnt/gentoo
poweroff
```

VirtualBox: Ustawienia → Pamięć → usunięcie płyty z napędu → start VM.

Naprawa fstab w emergency mode:

```bash
mount -o remount,rw /
sed -i 's/^UUID=/PARTUUID=/' /etc/fstab
nano /etc/fstab             # dopisanie brakującego "/" w linii root
systemctl daemon-reload
mount -a
findmnt /efi
swapon --show
reboot
```

## 19. Dowody (system uruchomiony z własnego kernela)

```bash
uname -a                    # 6.18.57-gentoo + data kompilacji
findmnt /                   # rw
systemctl --failed
ip a
ping -c 2 gentoo.org
```

---

## Powrót do pracy po restarcie VM / zerwaniu SSH (dotyczy etapu instalacji z płyty)

W oknie VM:

```bash
passwd
rc-service sshd start
```

Z hosta (Git Bash):

```bash
ssh -p 2222 root@127.0.0.1
mount /dev/sda3 /mnt/gentoo
swapon /dev/sda2
arch-chroot /mnt/gentoo
source /etc/profile
export PS1="(chroot) ${PS1}"
mount /dev/sda1 /efi
```

(Po samym zerwaniu SSH, bez restartu VM, wystarczą `ssh`, `arch-chroot` i `source`; montowania zostają.)
