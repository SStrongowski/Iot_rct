# Zadanie 2: Gentoo na Raspberry Pi (ARM64) — notatka projektowa

**Status:** wykonane w całości na wirtualnej płytce ARM64 (QEMU); do zrobienia: uruchomienie obrazu na fizycznym Raspberry Pi 5

**Artefakty:** `config-arm64`, `hello.c`, `hello-arm64`, konfiguracje płytki i sysrootu (`fstab`, `50-dhcp.network`, `binrepos.conf`, `make.conf` sysrootu, `package.use/sudo`)

## Kryteria ukończenia i dowody

| Kryterium | Stan | Dowód |

| System bootuje na płytce | ◐ QEMU (Cortex-A76, 2 GB) ✔, fizyczne RPi 5 ☐ | `dowody/qemu-boot.txt` (`uname -a`: aarch64, 6.18.57-gentoo) |
| Cross-kompilacja (crossdev / binhost) zamiast kompilowania na RPi — umie wyjaśnić dlaczego | ☑ | `dowody/toolchain.txt`, `dowody/crosscompile.txt`, `dowody/binhost-porownanie.txt`, `dowody/wlasny-binhost.txt`, sekcja „Dlaczego cross-kompilacja” |
| Dostęp po SSH | ☑ | logowanie kluczem na port 2223; screen root_ssh.png, użytkownik wpuszczony |
| Konto nie-root | ☑ | użytkownik w `wheel`, `sudo whoami` → `root` |
| Podstawowy porządek w systemie | ☑ | sekcja „Porządek w systemie” |


## Architektura rozwiązania

| Rola | Maszyna | Zadanie |
| Fabryka | Gentoo VM (x86_64, VirtualBox, 8 GB RAM, `-j4`) | crossdev, kernel ARM64, przygotowanie obrazu, binhost |
| Wirtualna płytka | QEMU `virt`, `cortex-a76`, 4 rdzenie, 2 GB RAM (Windows) | uruchomienie obrazu, testy |
| Płytka docelowa | Raspberry Pi 5 (2 GB) | ten sam obraz zapisany na kartę SD (do zrobienia) |

Obraz systemu powstaje w całości na fabryce, bez uruchamiania na niej ani jednego programu ARM64 — dokładnie tak, jak przygotowuje się kartę SD dla urządzenia.

## Podjęte decyzje

### Toolchain i kernel

- **crossdev, target `aarch64-unknown-linux-gnu`, `--stable`:** cross-kompilator x86_64 → ARM64 z glibc (jak na płytce); paczki toolchaina w osobnym repozytorium `crossdev`, nie w `gentoo`.
- **`-mcpu=cortex-a76` wskazany jawnie:** rdzeń RPi 5; `-march=native` oznaczałoby procesor fabryki (wniosek z zadania 1).
- **Kernel: `gentoo-sources` 6.18.57, osobna kopia źródeł** (`make mrproper`), `ARCH=arm64 CROSS_COMPILE=aarch64-unknown-linux-gnu-`.
- **Konfiguracja: `arm64 defconfig` + `scripts/config --enable GENTOO_LINUX_INIT_SYSTEMD` + `olddefconfig`:** bez menuconfig, więc konfigurację da się odtworzyć skryptem (krok w stronę powtarzalnych buildów w zadaniu 4). Defconfig obsługuje QEMU (virtio, PL011) i zawiera DTB dla RPi 5; odchudzanie odłożone do wersji na sprzęt.
- **Moduły instalowane do obrazu (`INSTALL_MOD_PATH=/mnt/arm64`),** nie do systemu fabryki.

### Obraz dysku

- **Plik raw 8 GB, tablica MBR:** p1 `BOOT` 512 MB FAT32 (typ `c`, wymagany przez firmware RPi), p2 `rootfs` ext4. Układ od razu zgodny z RPi; raw zamiast qcow2, bo ten sam plik trafi bajt w bajt na kartę SD.
- **Stage3 `arm64-systemd` z weryfikacją podpisu GPG** (`Good signature` od Gentoo Release Engineering) — luka z zadania 1 zamknięta.
- **`root=PARTUUID=…-02`:** kernel bez initramfs; przy MBR identyfikator pochodzi z tablicy partycji w obrazie, więc jest ten sam w QEMU (`/dev/vda2`) i na karcie SD (`/dev/mmcblk0p2`).
- **fstab przez PARTUUID, `/boot` z `nofail`:** partycja BOOT potrzebna tylko firmware RPi; jej brak nie może blokować startu.
- **Konfiguracja offline narzędziami fabryki:** `systemd-firstboot --root` (hostname, strefa, hash hasła z `openssl passwd -6`), `systemctl --root … enable`, klucz SSH w `authorized_keys`. Programy ARM64 nie mogą działać na x86_64, więc obraz się *przygotowuje*, a nie *instaluje*.
- **Pusty `machine-id` w obrazie:** każde urządzenie generuje własny przy pierwszym starcie (obraz przeznaczony na wiele płytek).
- **QEMU: bezpośredni start kernela (`-kernel Image`),** parametry w `-append` (odpowiednik `cmdline.txt`), konsola `ttyAMA0` (PL011 — ten sam typ portu co w RPi 5).

### Porządek w systemie

- **SSH tylko kluczem:** `PermitRootLogin no`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no` w `sshd_config.d/10-hardening.conf` (aktualizacja OpenSSH nie nadpisze); `sshd -t` przed restartem; test z drugiej sesji przed zamknięciem pierwszej.
- **Konto nie-root w `wheel`, sudo dla `%wheel`** (edycja przez `visudo`).
- **Locale `en_US.UTF-8`, `systemd-timesyncd`:** RPi 5 bez baterii RTC traci czas po odłączeniu zasilania; bez synchronizacji przestają działać m.in. certyfikaty TLS.
- **journald `SystemMaxUse=50M`:** ograniczenie zapisów na kartę SD.
- **sudo z `-sendmail`:** domyślna flaga dociągała serwer pocztowy (`nullmailer`, `virtual/mta`, konta systemowe) — zbędny na urządzeniu IoT, mniejsza powierzchnia ataku.

### Binhost

- **Oficjalny binhost Gentoo** (prekonfigurowany w stage3, `FEATURES="getbinpkg"`): szybkie wyposażenie płytki, ale tylko dla domyślnych USE flags — przy `-sendmail` sudo wraca do `[ebuild]` (`--binpkg-respect-use`).
- **Własny binhost dla paczek z własnymi flagami:**
  - sysroot crossdeva wypełniony **kopią stage3 arm64** (replika systemu płytki) — zależności już „zainstalowane”, cross-kompilacja obejmuje tylko sudo;
  - ustawienia sysrootu zgodne z płytką: profil `default/linux/arm64/23.0/systemd`, USE z profilu, `ACCEPT_KEYWORDS="${ARCH}"` (tylko stabilne), `FEATURES` z `buildpkg`;
  - serwer: `python3 -m http.server 8080` w PKGDIR; ścieżka: płytka → `10.0.2.2:8080` (Windows) → przekierowanie VirtualBox → fabryka;
  - `binrepos.conf`: `[gentoo-vm]`, `priority = 10000` (wyżej niż oficjalny 9999).
- **Repozytorium płytki synchronizowane z fabryki (`rsync` przez SSH),** a nie z serwerów Gentoo: paczka binarna jest przypięta do wersji ebuilda, więc fabryka dyktuje stan repozytorium.

## Dlaczego cross-kompilacja zamiast kompilowania na RPi

| Operacja | Gdzie | Czas (`real`) | Uwagi |
| Kernel ARM64 (`Image modules dtbs`) | fabryka, 4 vCPU | 42 min | 127 min `user` + 34 min `sys` ≈ 2,7 h pracy CPU; wszystkie rdzenie zajęte |
| sudo (cross-kompilacja) | fabryka | 1 min 50 s | |
| sudo (instalacja gotowej paczki z binhosta) | płytka, QEMU | 1 min 56 s | samo ustalanie zależności (Portage w Pythonie, w emulacji) trwało 15 s |

1. **Moc obliczeniowa:** rdzeń Cortex-A76 jest wolniejszy od rdzenia PC; kernel, który na fabryce wymaga ~2,7 h pracy CPU, na RPi trwałby kilka godzin, a w emulacji QEMU — wielokrotnie dłużej. Kernel kompiluje się przy każdej zmianie konfiguracji.
2. **Pamięć:** 2 GB RAM pozwala najwyżej na `-j2` (~2 GB na zadanie kompilacji, wniosek z zadania 1); większe paczki groziłyby OOM.
3. **Zużycie karty SD:** kompilacja to tysiące plików tymczasowych zapisywanych na nośnik o ograniczonej liczbie zapisów.
4. **Powtarzalność i skala:** jeden build na fabryce → ta sama paczka/obraz dla wielu urządzeń; urządzenie tylko instaluje.

Wniosek: *source-based w czasie budowania, binarny w czasie wdrożenia.* Nawet instalacja gotowej paczki jest na słabym urządzeniu zauważalna — tym bardziej warto przenieść na nie jak najmniej pracy.

## Rozważone alternatywy

- **Instalacja z płyty arm64 w QEMU** — odrzucona: kompilacja na (emulowanym) celu, przeciwieństwo kryterium.
- **Raspberry Pi OS (dystrybucja binarna)** — szybki start, ale bez kontroli nad flagami i kernelem; dobra do prototypu, nie do tego zadania.
- **Pusty sysroot crossdeva** — odrzucony po próbie: cykle zależności (`systemd ↔ pam`, `util-linux ↔ systemd`), budowanie całego systemu bazowego od zera.
- **Tylko oficjalny binhost** — wystarcza przy domyślnych flagach, nie pozwala na własne decyzje (`-sendmail`).
- **GPT zamiast MBR** — obsługiwany przez EEPROM RPi 5, MBR wybrany jako standard obrazów RPi.
- **qcow2 zamiast raw** — mniejszy plik, ale nie nadaje się do bezpośredniego zapisu na kartę.
- **U-Boot/UEFI w QEMU** zamiast `-kernel` — bliżej realnego łańcucha startu; wróci w zadaniu 4 (measured boot).
- **Podpisywanie własnych paczek binarnych kluczem GPG** — następny krok w realnym wdrożeniu.

## Mini threat-model (3 zdania)

1. **Co chronię:** integralność oprogramowania trafiającego na urządzenie oraz zdalny dostęp do niego.
2. **Przed czym:** podmienionym stage3, snapshotem repozytorium i paczkami z oficjalnego binhosta (wszystkie weryfikowane podpisem GPG) oraz zgadywaniem haseł po SSH (tylko klucze, brak logowania roota).
3. **Czego to NIE chroni:** paczki z własnego binhosta są niepodpisane i przesyłane zwykłym HTTP, więc atakujący w tej samej sieci mógłby je podmienić; na płytce w QEMU wyłączone jest odświeżanie kluczy OpenPGP (`sync-openpgp-key-refresh = no`), a urządzenie nie ma secure boot ani szyfrowania (zadania 4 i 5).

## Problemy i rozwiązania

| Problem | Przyczyna | Rozwiązanie |

| `loop0p2` miała ~1 MB | fdisk zaproponował jako pierwszy sektor wolny skrawek przed p1 | partycja 2 z ręcznie podanym pierwszym sektorem; zawsze `p` przed `w` |
| Dwa urządzenia loop na jeden plik | nieudane `losetup -d` (zamontowana partycja) | odmontowanie, odłączenie wszystkich, jedno urządzenie |
| `hello-arm64`: `Permission denied` | NTFS Windowsa gubi bit wykonywalności | `chmod +x` po stronie płytki |
| `emerge` na płytce: brak profilu i repozytorium | stage3 nie zawiera drzewa ebuildów | `emerge-webrsync`, później rsync z fabryki |
| `OpenPGP keyring refresh failed` | brak dostępu do serwera kluczy z sieci QEMU | `sync-openpgp-key-refresh = no` (podpis nadal weryfikowany) |
| `Error fetching binhost … Name or service not known` → kompilacja zamiast `[binary]` | niestabilny DNS w sieci QEMU (IPv6) | `DNS=10.0.2.3`, `IPv6AcceptRA=no` w `50-dhcp.network` |
| Cykl `systemd ↔ pam`, potem `util-linux ↔ systemd`; w sysroocie pojawił się openrc | pusty sysroot; `USE="-systemd"` w środowisku objęło wszystkie paczki wywołania | zmiana podejścia: sysroot = kopia stage3 |
| Płytka widzi `sudo-1.9.17_p2`, fabryka zbudowała `sudo-1.9.17_p2-r1` | crossdev ustawił `ACCEPT_KEYWORDS="${ARCH} ~${ARCH}"` (wersje testowe) | `ACCEPT_KEYWORDS="${ARCH}"`, przebudowa |

## Do zrobienia na fizycznym Raspberry Pi 5

- Kernel dla BCM2712 (mainline z DTB `bcm2712-rpi-5-b.dtb` lub drzewo Raspberry Pi Foundation) — cross-kompilacja jak wyżej.
- Partycja BOOT: firmware RPi, `config.txt`, `cmdline.txt` z tym samym `root=PARTUUID=…-02`, kernel i DTB.
- Zapis obrazu na kartę SD, start, te same testy (`uname -a`, `hello-arm64`, SSH, sudo).
- Repozytorium i binhost: adres fabryki w sieci lokalnej zamiast `10.0.2.2`; przywrócenie odświeżania kluczy OpenPGP.

