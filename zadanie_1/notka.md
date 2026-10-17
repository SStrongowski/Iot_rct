# Zadanie 1: Gentoo na VM — notatka projektowa

**Dziennik poleceń:** `dziennik_polecen.md`


## Kryteria ukończenia i dowody

| Kryterium | Stan | Dowód |
| System bootuje się z własnoręcznie skompilowanego kernela | ☑ | `uname -a`: `6.18.57-gentoo #1 SMP PREEMPT_DYNAMIC Sat Oct 17 15:36:49 CEST 2026`; `dowody/kernel-diff.txt` |
| Świadomy wybór profilu (umie uzasadnić) | ☑ | sekcja „Podjęte decyzje” |
| Świadomy wybór USE flags (umie uzasadnić) | ☑ | `artefakty/portage/make.conf`, `artefakty/portage/package.use/` |
| Notatka: source-based vs binarne, wnioski dla embedded | ☑ | sekcja source-based vs binarne |

Demo na żywo: start VM → GRUB → login → `uname -a`, `findmnt /`, `networkctl`, `systemctl --failed`.

## Środowisko

- VirtualBox, firmware UEFI, kontroler SATA/AHCI, sieć NAT (przekierowanie 2222 → 22)
- 6 vCPU, 4 GB RAM, dysk 52 GB
- Host: AMD Ryzen 7 3700X; gość widzi CPU bez `avx`/`avx2` (VirtualBox ich nie udostępnia)

## Podjęte decyzje

### Instalacja i Portage

- **UEFI + GPT:** nowoczesny standard; podstawa pod mierzony start (zadanie 4).
- **Partycje:** ESP 1 GB (FAT32, `/efi`), swap 4 GB (kompilacja przy 4 GB RAM), root ext4.
- **ext4:** dojrzały i prosty; migawki niepotrzebne.
- **Profil `default/linux/amd64/23.0/systemd` (stable):** systemd ze względu na `systemd-cryptenroll` w zadaniu 5 i znajomość z CentOS; bez *desktop* — system bez grafiki, mniej kodu i mniejsza powierzchnia ataku.
- **`COMMON_FLAGS="-O2 -pipe -march=native"`:** `-march=native` dopuszczalne, bo binaria nie opuszczają VM.
- **`MAKEOPTS="-j2 -l2"`:** dobrane do RAM (~2 GB na zadanie), nie do liczby rdzeni.
- **USE flags — globalnie minimum, reszta per paczka:** domyślne flagi profilu; `CPU_FLAGS_X86` z `cpuid2cpuflags` (m.in. `aes`, `pclmul` — sprzętowe AES dla LUKS w zadaniu 5); `VIDEO_CARDS=""`; świadomie zachowane `seccomp`, `pam`, `ssl`, `cet`.
- **Locale `en_US.UTF-8`:** łatwiejsza diagnoza komunikatów.

### Kernel (`gentoo-sources` 6.18.57)

- **Strategia: `x86_64 defconfig` + świadome zmiany.** Defconfig pokrywał już sprzęt VirtualBox (AHCI, `BLK_DEV_SD`, e1000, ext4, VFAT, EFI stub, GPT). Sprzęt rozpoznany przez `lspci -k` z kernela płyty live.
- **Bez initramfs:** sterowniki potrzebne do zamontowania root (AHCI, `BLK_DEV_SD`, ext4) wbudowane (`=y`). Konsekwencja: GRUB przekazuje `root=PARTUUID=…` (kernel bez initramfs nie rozwiązuje UUID systemu plików).
- **7 świadomych zmian względem defconfigu → 61 linii w `diffconfig`** (reszta to zależności):

| Decyzja | Bezpośrednie zmiany | Pociągnięte przez zależności |
|---|---|---|
| Obraz na konsoli przy UEFI | `SYSFB_SIMPLEFB`, `DRM_SIMPLEDRM`, `DRM_FBDEV_EMULATION`, `FRAMEBUFFER_CONSOLE` → y | `SYSFB`, `DRM_SYSFB_HELPER`, `DRM_CLIENT*`, `FB_CORE` i pomocnicze `FB_*`, `VT_HW_CONSOLE_BINDING`, `BOOT_VESA_SUPPORT`, `FONT_8x8`; nowe pytania z domyślnymi `n`: `LOGO`, `FB_DEVICE`, `FONTS`, opcje rotacji/akceleracji konsoli; znikają alternatywy `DRM_EFIDRM`, `DRM_VESADRM`, `VGA_SWITCHEROO`, `FONT_AUTOSELECT` |
| Init system: systemd | `GENTOO_LINUX_INIT_SYSTEMD` → y | `BPF_SYSCALL`, `CGROUP_BPF`, `FANOTIFY` (wymagania systemd); dalej z BPF: `BPF_EVENTS`, `NET_SOCK_MSG`, `NETFILTER_BPF_LINK`, `PAGE_POOL`, `NET_DEVMEM`, `IO_URING_ZCRX`; `BPF_UNPRIV_DEFAULT_OFF=y` (nieuprzywilejowany BPF domyślnie wyłączony — plus dla bezpieczeństwa) |
| Bez OpenRC | `GENTOO_LINUX_INIT_SCRIPT` y → n | — |
| Bez zbędnego sprzętu | `ATA_PIIX` y → n (wirtualny napęd CD/IDE) | — (konsekwencja: brak dostępu do płyty z poziomu systemu) |

- **Świadomie pominięte sterowniki** wykryte przez `lspci -k`: AC'97 (`snd_intel8x0`), VirtualBox Guest Service (`vboxguest`), PIIX4 SMBus (`i2c_piix4`), VMware SVGA (`vmwgfx` — obraz zapewnia `simpledrm`).
- **Kandydaci do kolejnej iteracji odchudzania:** `IPV6_SIT` (zbędny interfejs `sit0`), `DEBUG_STACK_USAGE` (komunikaty `kworker … stack depth`).

### Bootloader i system

- **GRUB (UEFI, `--removable`):** znany z CentOS; instalacja w ścieżce zapasowej `EFI/BOOT/BOOTX64.EFI`, bo VirtualBox gubi wpisy NVRAM. `/boot` na ext4 (GRUB czyta ext4), na ESP tylko plik startowy.
- **fstab przez PARTUUID:** spójne z `root=PARTUUID=` w GRUB; identyfikator partycji GPT nie zmienia się przy ponownym formatowaniu.
- **systemd-networkd + systemd-resolved:** natywne dla wybranego init systemu; DHCP dla interfejsów `en*`.
- **Konto nie-root w grupie `wheel`:** domyślny sshd nie pozwala na logowanie roota hasłem.

## Rozważone alternatywy

- **OpenRC** — odrzucony ze względu na zadanie 5.
- **Profile *hardened*, *musl*, *no-multilib*** — odpowiednio: komplikuje naukę; wymaga łatek części oprogramowania; wymaga innego stage3.
- **Oficjalny binhost Gentoo** — odrzucony, celem jest podejście source-based.
- **`gentoo-kernel` / `gentoo-kernel-bin`** (kernel dystrybucyjny) — odrzucony, kryterium wymaga własnej konfiguracji.
- **`make localmodconfig`** (z modułów kernela live) — mniejszy, ale łatwo pominąć sterownik; **`make allnoconfig`** — maksymalnie chudy, zbyt czasochłonny na etapie nauki.
- **initramfs (dracut)** — niepotrzebny przy znanym sprzęcie i nieszyfrowanym root; wróci przy LUKS (zadanie 5).
- **systemd-boot / bezpośredni EFI stub** — prostsze od GRUB, `EFI_STUB` jest włączony; GRUB wybrany ze względu na znajomość i automatyczne wykrywanie kerneli.
- **QEMU zamiast VirtualBox** — dla x86 VirtualBox wystarcza; QEMU na zadania 2 i 4 (ARM64, wirtualny TPM).

## Mini threat-model (3 zdania)

1. **Co chronię:** integralność i minimalność systemu — kernel zawiera tylko sterowniki potrzebnego sprzętu (bez audio, dodatków VirtualBox, IDE), co zmniejsza powierzchnię ataku.
2. **Przed czym:** podatnościami w nieużywanym kodzie oraz podmienionymi źródłami — przy czym podpis GPG stage3 nie został zweryfikowany (do poprawy na RPi).
3. **Czego to NIE chroni:** systemu przed hostem/hiperwizorem ani przed podmianą kernela w `/boot` przez kogoś z dostępem do dysku VM — brak secure/measured boot i szyfrowania to temat zadań 4 i 5.

## Problemy i rozwiązania

| Problem | Przyczyna | Rozwiązanie |
|---|---|---|
| Brak partycji na dysku | pominięty krok fdisk | ponowne partycjonowanie (`lsblk` jako kontrola) |
| Podwójny montaż `/mnt/gentoo` | dwukrotne `mount` | `umount /mnt/gentoo` |
| Brak schowka w konsoli VirtualBox | brak Guest Additions w systemie live | praca przez SSH (Git Bash) z przekierowaniem portu |
| `emerge-webrsync`: `unable to resolve host address` | brak `/etc/resolv.conf` w chroocie | `cp --dereference /etc/resolv.conf /mnt/gentoo/etc/` |
| `scp` z wnętrza VM: `Connection refused` | `127.0.0.1` w VM wskazuje na VM | `scp` uruchamiany na hoście |
| `FRAMEBUFFER_CONSOLE` niewidoczna w menuconfig | niespełniona zależność | włączenie `DRM_FBDEV_EMULATION` |
| `ln`: `/etc/resolv.conf` — *Device or resource busy* | `arch-chroot` bind-mountuje plik | dowiązanie utworzone po wyjściu z chroota |
| `umount`: *target is busy* | zawieszony proces vim | `fuser -vm`, `kill -9` |
| Emergency mode, root `ro` | wartości PARTUUID wpisane jako `UUID=` w fstab | zamiana na `PARTUUID=` |
| `Mount point ext4 is not a valid path` | brak `/` w linii root fstab | uzupełnienie kolumny |
| `enp0s3` — `unmanaged`, brak IP | `[MATCH]` zamiast `[Match]` (systemd rozróżnia wielkość liter) | poprawka sekcji, `networkctl reload`; diagnoza: `journalctl -u systemd-networkd -b` |

## Source-based vs dystrybucje binarne

### Na czym polega różnica

Dystrybucja binarna (CentOS, Debian, Raspberry Pi OS) dostarcza paczki skompilowane wcześniej przez dostawcę, raz, dla wszystkich użytkowników. Dystrybucja source-based (Gentoo) dostarcza przepisy (ebuildy), a kompilacja odbywa się u użytkownika, z jego ustawieniami.

| Aspekt | Binarna (np. CentOS) | Source-based (Gentoo) |
|---|---|---|
| Kto kompiluje | dostawca, raz dla wszystkich | użytkownik, na swojej maszynie |
| Wybór funkcji | na poziomie całych paczek (`foo`, `foo-devel`); funkcje wkompilowane „na zapas” | na poziomie funkcji w paczce (USE flags) i opcji kernela |
| Optymalizacja | pod ogólny procesor (np. bazowe x86-64), żeby działało wszędzie | pod konkretny procesor (`-march`, `CPU_FLAGS_X86`) |
| Kernel | jeden ogólny, ze sterownikami do „wszystkiego” + initramfs | własna konfiguracja: tylko potrzebny sprzęt, możliwy start bez initramfs |
| Czas instalacji / aktualizacji | minuty | godziny (kompilacja), zależnie od CPU i RAM |
| Wymagania wobec maszyny | minimalne | mocny CPU i dużo RAM do kompilacji |
| Aktualizacje bezpieczeństwa | dostawca przebudowuje i publikuje paczkę | użytkownik sam przebudowuje każdą zmienioną paczkę |
| Powtarzalność | zależy od wersji repozytorium dostawcy | wynika z artefaktów: `make.conf`, `package.use`, `.config`, profil |

### Co pokazało to zadanie

- **Kontrola:** kernel z 7 świadomymi zmianami względem defconfigu, bez audio, dodatków VirtualBox i IDE; system bez grafiki dzięki profilowi i `VIDEO_CARDS=""`. W dystrybucji binarnej ten sam efekt wymagałby budowania kernela poza menedżerem paczek.
- **Koszt:** każdy krok instalacji to kompilacja; przy 4 GB RAM wydajność ogranicza pamięć (`-j2` mimo 6 rdzeni), nie procesor.
- **Pułapka „native”:** optymalizacja pod CPU widziany przez VM, nie fizyczny (brak AVX2) — kompilator optymalizuje pod to, co *widzi*, więc cel trzeba znać i nazwać.
- **Artefakty zamiast stanu:** system jest opisany kilkoma plikami w repo, z których można go odtworzyć; w dystrybucji binarnej opisem jest raczej lista zainstalowanych paczek.

### Wnioski dla embedded

1. **Embedded potrzebuje kontroli z podejścia source-based, ale nie kompilacji na urządzeniu.** Płytka ma mało RAM i słaby CPU (RPi 5: 2 GB), a kompilacja na niej byłaby wolna lub niemożliwa. Rozwiązanie: budować na mocnym hoście (cross-kompilacja), a na urządzenie wgrywać gotowe binaria. To model Yocto i Buildroot: *source-based w czasie budowania, binarny w czasie wdrożenia*. Gentoo na RPi przez `crossdev`/binhost (zadanie 2) realizuje tę samą ideę.
2. **Mniej kodu = mniej zagrożeń i mniej miejsca.** USE flags i konfiguracja kernela usuwają nieużywane funkcje: mniejszy obraz (ograniczona pamięć flash/SD) i mniejsza powierzchnia ataku (podatności w niewkompilowanym kodzie nie dotyczą urządzenia).
3. **Sprzęt jest znany z góry, więc można go wykorzystać w pełni** — ale cel trzeba wskazać jawnie (dla RPi 5: Cortex-A76, np. `-mcpu=cortex-a76`), bo `-march=native` na hoście oznaczałoby procesor hosta.
4. **Kernel i device tree pod konkretną płytkę.** Na ARM sprzęt opisuje device tree, a nie wykrywanie jak na PC; własna konfiguracja kernela (często bez initramfs, jak tutaj) to w embedded norma, nie wyjątek.
5. **Powtarzalność i audyt.** Konfiguracja w repozytorium pozwala zbudować identyczny obraz dla tysięcy urządzeń i odtworzyć go po latach; źródła ułatwiają też spełnienie wymogów licencyjnych (GPL) i przygotowanie listy komponentów (SBOM).
6. **Cena: odpowiedzialność za aktualizacje.** Nikt nie opublikuje gotowej poprawki — trzeba mieć własny proces budowania i dystrybucji. W embedded aktualizuje się zwykle całym obrazem (np. schemat A/B), nie pojedynczymi paczkami; to wiąże się bezpośrednio z zadaniem 5 (nowy obraz → nowe wartości PCR → ponowne zapieczętowanie klucza).

### Kiedy co wybrać

- **Dystrybucja binarna** (np. Raspberry Pi OS, Debian): prototyp, szybkie sprawdzenie sprzętu, gdy rozmiar i kontrola nie są krytyczne.
- **Budowanie ze źródeł** (Yocto, Buildroot, Gentoo z cross-kompilacją): produkt — urządzenia wdrażane seryjnie, z wymaganiami co do rozmiaru, bezpieczeństwa, powtarzalności i długiego wsparcia.

## Wnioski na kolejne zadania

- `-march=native` i `cpuid2cpuflags` widzą CPU udostępniony przez VM, nie fizyczny (Ryzen 3700X ma AVX2, gość nie). W cross-kompilacji dla RPi docelowy procesor trzeba wskazać jawnie.
- Ograniczenie RAM (4 GB → `-j2`) zapowiada problem RPi z 2 GB: argument za cross-kompilacją/binhostem w zadaniu 2.
- Defconfig włącza rzeczy niepotrzebne (`sit0`, debug stosu) — na urządzeniu embedded konfiguracja powinna być przeglądana opcja po opcji.
- Kernel bez initramfs wymaga `root=PARTUUID=` — ta sama zasada obowiązuje na płytkach ARM bez initramfs.
- Weryfikować podpisy pobieranych obrazów od początku.
