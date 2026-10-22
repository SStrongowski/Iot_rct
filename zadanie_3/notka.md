# Zadanie 3: Obsługa peryferiów — notatka projektowa

**Status:** wykonane w zakresie dostępnym na wirtualnej płytce ARM64 (QEMU `virt`); peryferia specyficzne dla Raspberry Pi 5 (WiFi 2.4/5 GHz, I2C, SPI, audio, HDMI) — do sprawdzenia na sprzęcie
**Artefakty:** `peryferia-test.sh`, `start-rpi.ps1` (z USB i parametrem `-Dtb`), `dt/virt-rtc-on.dts`, `dt/virt-rtc-off.dts`
**Dowody:** `peryferia.txt`, `sterowniki-dt.txt`, `rtc-on.txt`, `rtc-off.txt`, `rtc-dt.diff`

## Kryteria ukończenia i dowody

| Kryterium | Stan | Dowód |
| Lista peryferiów z dowodem działania każdego | ◐ wszystkie peryferia płytki QEMU ✔; peryferia RPi 5 ☐ | `peryferia.txt` (raport skryptu `peryferia-test.sh`) |
| Dla min. dwóch peryferiów: przez jaki sterownik i wpis w DT działają | ☑ | sekcja „Peryferia prześledzone”, `sterowniki-dt.txt` |
| Jedno peryferium wyłączone i włączone przez zmianę DT / konfiguracji kernela | ☑ (RTC PL031, zmiana DT) | `rtc-dt.diff`, `rtc-off.txt`, `rtc-on.txt` |

## Środowisko

QEMU `virt`, `cortex-a76`, 4 rdzenie, 2 GB RAM, kernel `gentoo-sources` 6.18.57 (arm64 defconfig + systemd), dodatkowo kontroler USB xHCI z klawiaturą i pendrive'em testowym (`usb.img`, 64 MB). Device tree generowany przez QEMU.

## Lista peryferiów

| # | Peryferium | Pochodzenie | Sterownik | Dowód działania |
| 1 | UART PL011 (`ttyAMA0`) | węzeł DT `/pl011@9000000`, magistrala AMBA | `uart-pl011` | zapis do `/dev/ttyAMA0` widoczny w konsoli QEMU; konsola systemu |
| 2 | RTC PL031 | węzeł DT `/pl031@9010000`, AMBA | `rtc-pl031` | odczyt czasu (`/sys/class/rtc/rtc0`, `hwclock -r`); ustawienie zegara przy starcie |
| 3 | GPIO PL061 | węzeł DT `/pl061@9030000`, AMBA | `pl061_gpio` | linie GPIO w debugfs, pin 3 zajęty przez przycisk |
| 4 | Przycisk zasilania | węzeł DT `/gpio-keys`, platform | `gpio-keys` | urządzenie wejściowe; `system_powerdown` → `Power key pressed` → poweroff |
| 5 | Kontroler PCIe | węzeł DT `pcie@10000000`, platform | `pci-host-generic` | wykryte karty PCI z identyfikatorami i sterownikami |
| 6 | Ethernet (virtio-net) | wykryty przez PCI (`0000:00:01.0`) | `virtio_net` | adres IP, DNS, połączenie HTTPS z `distfiles.gentoo.org` |
| 7 | Dysk (virtio-blk) | wykryty przez PCI (`0000:00:03.0`) | `virtio_blk` | partycje `vda1`/`vda2`, zamontowany root |
| 8 | Kontroler USB xHCI | wykryty przez PCI (`0000:00:02.0`), magistrale `usb1` (USB 2.0) i `usb2` (USB 3.0) | `xhci_hcd` | wykryte urządzenia USB |
| 9 | Klawiatura USB | wykryta przez USB (`1-1`, `0627:0001`) | interfejs `1-1:1.0` → `usbhid` | urządzenie wejściowe zarejestrowane |
| 10 | Pendrive USB | wykryty przez USB (`2-2`, `46f4:0001`) | interfejs `2-2:1.0` → `usb-storage` | `/dev/sda`; zapis i odczyt 1 MB, sumy zgodne |

**Nieobecne na płytce QEMU `virt`:** WiFi 2.4/5 GHz, I2C, SPI, audio, HDMI — do sprawdzenia na Raspberry Pi 5 tym samym skryptem (do rozbudowy o te sekcje).

### Wniosek: kiedy potrzebny jest device tree

Urządzenia, które **nie potrafią się przedstawić** (UART, RTC, GPIO, przycisk, kontroler PCIe), muszą być opisane w device tree. Urządzenia na magistralach z **wykrywaniem** (PCI, USB) przedstawiają się same identyfikatorem producenta i modelu — device tree opisuje tylko ich kontroler. Widać to w ścieżkach w `/sys`: `platform/4010000000.pcie/pci0000:00/0000:00:01.0/virtio0` = kontroler z DT → magistrala PCI → karta wykryta automatycznie. Na RPi 5 proporcje są podobne: I2C, SPI, GPIO i WiFi opisuje DT, a NVMe (PCIe) i urządzenia USB wykrywają się same.

## Peryferia prześledzone: wpis w DT → sterownik → konfiguracja

### 1. gpio-keys — dopasowanie po `compatible`

| Ogniwo | Wartość |

| Węzeł DT | `gpio-keys { compatible = "gpio-keys"; poweroff { gpios = <0x8007 0x03 0x00>; linux,code = <0x74>; }; }` |
| Powiązanie z innym węzłem | `gpios = <0x8007 …>` → phandle kontrolera PL061 (`phandle = <0x8007>`), pin 3, flagi 0; dwie komórki zgodnie z `#gpio-cells = <2>` kontrolera |
| Tabela dopasowań | `drivers/input/keyboard/gpio_keys.c`: `of_device_id gpio_keys_of_match[] = { { .compatible = "gpio-keys" } }`, podpięta przez `.of_match_table` |
| Budowanie | `drivers/input/keyboard/Makefile`: `obj-$(CONFIG_KEYBOARD_GPIO) += gpio_keys.o` |
| Konfiguracja | `CONFIG_KEYBOARD_GPIO` — wbudowany |
| Dowód w systemie | `/sys/bus/platform/devices/gpio-keys/driver → drivers/gpio-keys`, `of_node → /sys/firmware/devicetree/base/gpio-keys`, `modalias = of:Ngpio-keysT(null)Cgpio-keys` |
| Działanie | `linux,code = 0x74` (116 = `KEY_POWER`): `system_powerdown` w QEMU → zmiana pinu 3 PL061 → przerwanie → zdarzenie `KEY_POWER` → systemd-logind → poweroff |

### 2. RTC PL031 — dopasowanie dwuetapowe (PrimeCell / AMBA)

| Ogniwo | Wartość |

| Węzeł DT | `pl031@9010000 { compatible = "arm,pl031", "arm,primecell"; reg = <0x00 0x9010000 0x00 0x1000>; interrupts = <0x00 0x02 0x04>; clocks = <0x8000>; }` |
| Etap 1 (DT) | `arm,primecell` → kernel tworzy urządzenie na magistrali **AMBA** (`drivers/of/platform.c`) zamiast platform |
| Etap 2 (sprzęt) | magistrala AMBA odczytuje identyfikator z rejestrów układu: `00141031` |
| Tabela dopasowań | `drivers/rtc/rtc-pl031.c`: `amba_id pl031_ids[] = { { .id = 0x00041031, .mask = 0x000fffff } }`; `00141031 & 000fffff = 00041031` — maska pomija pole rewizji, więc jeden sterownik obsługuje wszystkie rewizje (`031` = numer części, `41` = ARM, `1` = rewizja) |
| Budowanie | `drivers/rtc/Makefile`: `obj-$(CONFIG_RTC_DRV_PL031) += rtc-pl031.o` |
| Konfiguracja | `CONFIG_RTC_DRV_PL031` — wbudowany |
| Dowód w systemie | `/sys/bus/amba/devices/9010000.pl031`, `driver → drivers/rtc-pl031`, `id = 00141031`, `/sys/class/rtc/rtc0/name = rtc-pl031 9010000.pl031` |

> Potwierdzenie wartości w konfiguracji: `grep -E 'CONFIG_(KEYBOARD_GPIO|RTC_DRV_PL031)=' /var/tmp/rpi/linux-arm64/.config`

## Wyłączenie i włączenie peryferium przez zmianę DT (RTC PL031)

Dwa pliki DTS różniące się jedną linią (`rtc-dt.diff`): w `virt-rtc-off.dts` węzeł `pl031@9010000` dostaje `status = "disabled";`. Oba skompilowane `dtc -I dts -O dtb`, podawane QEMU przez `-dtb` (parametry `-smp`, `-m` i urządzenia zgodne z tymi przy `dumpdtb`).

| Sprawdzenie | `virt-rtc-off.dtb` | `virt-rtc-on.dtb` |
| węzeł w `/proc/device-tree` | jest, `status = disabled` | jest, bez właściwości `status` (= włączony) |
| `/sys/bus/amba/devices/` | tylko `pl011`, `pl061` | także `9010000.pl031` |
| `/sys/class/rtc/`, `/dev/rtc0` | brak | `rtc0`, `/dev/rtc → rtc0` |
| `dmesg` | brak wpisów pl031 | `registered as rtc0` |
| `timedatectl` | `RTC time: n/a` | czas z RTC |

Wniosek: `status = "disabled"` nie usuwa opisu urządzenia, lecz sprawia, że kernel nie tworzy z węzła urządzenia — sterownik nie ma czego obsłużyć. Alternatywą jest wyłączenie sterownika w konfiguracji kernela (`=n`): wtedy urządzenie powstaje, ale pozostaje bez sterownika (widoczne w `/sys` bez dowiązania `driver`).

**Na Raspberry Pi 5** ta sama operacja: własny overlay (`/plugin/; &<etykieta-węzła> { status = "disabled"; };`, kompilacja `dtc -@` do `.dtbo`, wpis `dtoverlay=` w `config.txt`) albo gotowe parametry (`dtparam=…`, `dtoverlay=disable-…`) — wszystkie to zmiany DT, nie `raspi-config`.

## Jak kernel łączy urządzenia ze sterownikami (podsumowanie)

1. Firmware/QEMU przekazuje kernelowi DTB; kernel buduje z niego drzewo węzłów (`/proc/device-tree`).
2. Wbudowane sterowniki rejestrują się w magistralach razem z tabelami dopasowań.
3. Z węzłów z `compatible` (i bez `status = "disabled"`) powstają urządzenia: `arm,primecell` → AMBA, pozostałe → platform. Urządzenia PCI/USB wykrywa ich kontroler.
4. Magistrala dopasowuje urządzenie do sterownika (napis `compatible` albo identyfikator sprzętowy) i wywołuje `probe()`: zasoby z DT (`reg`, `interrupts`, `clocks`), utworzenie interfejsu (`/dev/rtc0`, urządzenie wejściowe). Zależności między węzłami (gpio-keys → PL061) rozwiązuje odroczone `probe` (`-EPROBE_DEFER`).
5. Urządzenia bez wbudowanego sterownika: zdarzenie z `modalias` → udev → `modprobe` → dopasowanie → `probe()`. Sterowniki potrzebne do zamontowania root muszą być wbudowane.

Urządzenie działa, gdy: jest opisane (DT) lub wykrywalne (PCI/USB), sterownik istnieje (`=y`/`=m`), klucz dopasowania się zgadza, a `probe()` się udaje (zasoby, zależności, ewentualnie pliki firmware — np. WiFi `brcmfmac` na RPi 5).

## Podjęte decyzje

- **Płytka QEMU `virt` zamiast czekania na sprzęt:** mechanizmy (DT, dopasowanie, `probe`, `status`) są te same; urządzenia PL011/PL031/PL061 to prawdziwe sterowniki kernela.
- **Dwa peryferia o różnych mechanizmach dopasowania** (gpio-keys: `compatible`; PL031: AMBA + identyfikator z maską) zamiast dwóch podobnych.
- **RTC jako peryferium do wyłączenia:** niekrytyczne dla startu, efekt łatwy do sprawdzenia (`/dev/rtc0`, `timedatectl`).
- **Własne pliki DTB dla obu stanów** (także „włączonego”) zamiast DT generowanego przez QEMU: oba stany różnią się wyłącznie jedną linią.
- **USB dodane przez kontroler xHCI na PCIe:** nie zmienia device tree, więc pliki DTB pozostają zgodne.
- **Skrypt `peryferia-test.sh`:** powtarzalny raport (sterownik, pochodzenie, test) zamiast ręcznych zrzutów; na RPi 5 do uruchomienia po dodaniu sekcji WiFi/I2C/SPI/audio/HDMI.

## Rozważone alternatywy

- **Czekanie na Raspberry Pi 5** — odłożone; mechanizmy przećwiczone w QEMU, na sprzęcie zostaje lista peryferiów RPi i powtórka wyłączenia przez overlay.
- **Model `raspi4b` w QEMU** — bliżej Raspberry Pi, ale niepełna emulacja peryferiów i brak modelu RPi 5; `virt` daje stabilne, dobrze opisane urządzenia.
- **Wyłączenie RTC przez `CONFIG_RTC_DRV_PL031=n`** — drugi dopuszczalny sposób; wybrano zmianę DT, bo nie wymaga przebudowy kernela i pokazuje rolę `status`..

## Mini threat-model (3 zdania)

1. **Co chronię:** przewidywalność sprzętu, z którym komunikuje się system — kernel obsługuje tylko urządzenia opisane w DT lub wykryte przez znane magistrale.
2. **Przed czym:** zbędnymi interfejsami — urządzenie wyłączone w DT (`status = "disabled"`) nie ma w systemie urządzenia ani interfejsu `/dev`, więc nie stanowi powierzchni ataku; to ten sam mechanizm, którym na RPi wyłącza się np. nieużywane WiFi czy Bluetooth.
3. **Czego to NIE chroni:** magistrale z wykrywaniem (USB, PCI) przyjmują każde podłączone urządzenie (np. złośliwy pendrive lub klawiatura „BadUSB”), a device tree na partycji BOOT można podmienić bez wiedzy systemu — ochronę integralności DT zapewnia dopiero measured/secure boot (zadanie 4).

## Problemy i rozwiązania

| Problem | Przyczyna | Rozwiązanie |

| `Waiting for root device PARTUUID=…` | obraz `gentoo-arm64.img` miał 0 B — „Discard Changes” w VS Code przywrócił pustą wersję pliku z Gita | odtworzenie obrazu z fabryki, konfiguracja skryptem `provision-rpi.sh`; obrazy wyłączone z repo (`.gitignore`), kopie zapasowe `*.img.gz` |
| `cp: cannot stat '/tmp/virt.dts'` | `/tmp` czyszczony przy restarcie VM | pliki DT w trwałym katalogu `~/dt` |
| `[FAIL]` połączenia HTTPS w raporcie | zbyt krótki limit czasu przy wolnym TLS w emulacji, brak diagnostyki | osobny test DNS, limit 30 s, log `wget` w raporcie |

## Do zrobienia na Raspberry Pi 5

- Kernel dla BCM2712 (drzewo Raspberry Pi Foundation lub mainline z `bcm2712-rpi-5-b.dtb`), firmware WiFi w `/lib/firmware`.
- Rozbudowa `peryferia-test.sh` o: WiFi 2.4 i 5 GHz (`iw`, połączenie w obu pasmach, regulatory domain `PL`), Ethernet 1 Gb/s (`ethtool`), GPIO (libgpiod, dioda), I2C (`i2cdetect`, czujnik), SPI (moduł TPM SLB 9670), PCIe (NVMe, `lspci`), audio/HDMI (`aplay -l`, `speaker-test`, DRM/KMS).
- Prześledzenie dwóch peryferiów RPi (np. I2C `brcm,…-i2c` i WiFi `brcmfmac`) tak jak gpio-keys i PL031.
- Wyłączenie i włączenie peryferium własnym overlayem w `config.txt`.
