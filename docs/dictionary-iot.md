# Słowniczek pojęć: projekt IoT (Gentoo → Raspberry Pi → Yocto → TPM/TEE → LUKS)

Pojęcia są ułożone w kolejności zadań, więc każda sekcja przyda się wtedy, gdy do niej dojdziesz. Tam, gdzie to pomaga, jest odniesienie do świata CentOS/RHEL, który już znasz.

---

## Zadanie 1: Gentoo na VM

**Dystrybucja binarna vs source-based**
CentOS to dystrybucja binarna: `dnf install` pobiera gotowe, skompilowane paczki, zbudowane „pod wszystkich”. Gentoo jest *source-based*: pobiera kod źródłowy i kompiluje go na Twojej maszynie, z Twoimi opcjami. Efekt: dokładnie te funkcje, których potrzebujesz, i nic więcej. Koszt: długi czas kompilacji. Dla embedded to ważne, bo mały system to mniejsza powierzchnia ataku, mniej miejsca i pełna kontrola nad tym, co trafia na urządzenie (dlatego Yocto działa w podobny sposób).

**Portage / emerge / ebuild**
Portage to menedżer pakietów Gentoo (odpowiednik dnf/rpm). `emerge` to polecenie, którego używasz (`emerge --ask app-editors/vim`). *Ebuild* to przepis na zbudowanie jednej paczki, coś jak plik `.spec` w RPM.

**Stage3**
Archiwum z minimalnym, gotowym systemem bazowym, od którego zaczynasz instalację. Rozpakowujesz je na dysk, wchodzisz do środka (chroot) i dalej budujesz system sam.

**chroot**
„Wejście” do innego katalogu tak, jakby był głównym systemem plików. Podczas instalacji Gentoo pracujesz z płyty live, ale chrootujesz się do nowego systemu na dysku i konfigurujesz go od środka.

**Profil**
Zestaw domyślnych ustawień systemu wybierany przez `eselect profile`, np. `default/linux/amd64/23.0/systemd`. Profil określa m.in. init system (systemd czy OpenRC) i domyślne USE flags. Kryterium zadania wymaga, żebyś umiał uzasadnić wybór, np. „systemd, bo w zadaniu 5 użyję `systemd-cryptenroll` do LUKS + TPM”.

**USE flags**
Przełączniki funkcji kompilowanych do paczek. Np. `USE="-X bluetooth"` oznacza: nie buduj obsługi środowiska graficznego, buduj obsługę Bluetooth. Ustawiane globalnie w `make.conf` lub per paczka w `/etc/portage/package.use/`. To jest sedno „świadomego wyboru” z kryteriów.

**make.conf**
Główny plik konfiguracyjny Portage (`/etc/portage/make.conf`): flagi kompilatora (`COMMON_FLAGS`, np. `-O2 -march=native`), globalne USE flags, liczba równoległych zadań kompilacji (`MAKEOPTS="-j4"`).

**Konfiguracja kernela**
Kernel kompilujesz sam ze źródeł (`sys-kernel/gentoo-sources`). Konfigurujesz go przez `make menuconfig`, a wynik ląduje w pliku `.config`. Każda opcja może być:
- `=y`: wkompilowana na stałe w kernel,
- `=m`: zbudowana jako moduł ładowany na żądanie (`modprobe`),
- wyłączona.
Typowa pułapka na VM: sterownik dysku (np. virtio) lub systemu plików ustawiony jako moduł bez initramfs, a kernel nie widzi wtedy dysku przy starcie.

**initramfs**
Mały, tymczasowy system plików ładowany razem z kernelem, który przygotowuje montowanie właściwego systemu (ładuje moduły, odblokowuje szyfrowane partycje). Na CentOS generuje go `dracut` i tego samego narzędzia możesz użyć w Gentoo. W zadaniu 5 będzie kluczowy.

**Bootloader (GRUB / systemd-boot)**
Program uruchamiający kernel. Na VM najczęściej GRUB, znany z CentOS.

**OpenRC vs systemd**
Dwa systemy init, czyli pierwszy proces uruchamiający usługi. systemd znasz z CentOS 7+. OpenRC jest prostszy i lżejszy. Oba są w porządku; systemd ułatwia zadanie 5.

---

## Zadanie 2: Gentoo na Raspberry Pi

**ARM64 / aarch64**
64-bitowa architektura procesorów ARM, używana przez Raspberry Pi 5. Dwie nazwy oznaczają to samo. Programy skompilowane dla x86_64 (Twój PC) na niej nie działają.

**Cross-kompilacja**
Kompilowanie programów na jednej architekturze (szybki PC x86_64) dla innej (ARM64). Powód: RPi z 2 GB RAM kompilowałoby duże paczki godzinami lub dniami, a niektórym zabrakłoby pamięci. Twój PC zrobi to wielokrotnie szybciej.

**Toolchain**
Zestaw narzędzi do budowania: kompilator (gcc), linker, biblioteka C (glibc/musl). Cross-toolchain to taki, który działa na x86_64, a produkuje kod dla ARM64.

**crossdev**
Narzędzie Gentoo, które jednym poleceniem buduje cross-toolchain, np. `crossdev --target aarch64-unknown-linux-gnu`.

**Binhost / binpkg**
Alternatywa dla crossdev: drugie środowisko Gentoo dla ARM64 (np. w chroot z emulacją QEMU na PC lub na mocniejszej maszynie) buduje gotowe paczki binarne, a RPi tylko je pobiera i instaluje (`emerge --getbinpkg`). To w praktyce Twoje prywatne repozytorium binarne.

**QEMU user-mode + binfmt_misc**
Emulacja pozwalająca uruchamiać programy ARM64 na PC. Dzięki niej możesz zrobić chroot do systemu ARM64 na swoim komputerze. Działa wolniej niż natywnie, ale wygodnie.

**Boot na Raspberry Pi**
RPi nie używa BIOS/UEFI. Bootloader siedzi w pamięci EEPROM na płytce, czyta partycję FAT z karty SD i z niej plik `config.txt` (ustawienia sprzętu i bootu) oraz `cmdline.txt` (parametry kernela). Dopiero potem startuje kernel. To ważne dla zadań 3 i 4.

**SoC**
*System on Chip*: jeden układ zawierający procesor, GPU i kontrolery. W RPi 5 to Broadcom BCM2712. Część peryferiów (USB, Ethernet, GPIO) obsługuje dodatkowy układ RP1 podłączony przez PCIe.

**sshd / konto nie-root / sudo**
To znasz z serwerów. Kryterium „podstawowy porządek” oznacza m.in.: logowanie kluczem, wyłączony login roota po SSH, użytkownik w grupie `wheel` z sudo, ustawiona strefa czasowa, NTP i hostname.

---

## Zadanie 3: Peryferia

**Sterownik (driver) / moduł kernela**
Kod w kernelu obsługujący konkretny sprzęt. Polecenia `lsmod` (załadowane moduły), `modprobe` (załadowanie), `modinfo` (informacje o module) i `dmesg` (komunikaty kernela, Twoje główne źródło „dowodów działania”).

**Device tree (DT)**
Na PC sprzęt sam się przedstawia (PCI, ACPI). Na płytkach ARM większość sprzętu nie ma takiej możliwości, więc kernel dostaje „mapę” sprzętu w pliku device tree: jakie układy są na płytce, pod jakimi adresami i do których pinów są podłączone.
- **DTS**: tekstowe źródło (czytelne dla człowieka),
- **DTB**: skompilowana wersja binarna, którą czyta kernel,
- **DTBO / overlay**: „łatka” na device tree, dokładana przy starcie (np. włączenie SPI lub dodanie modułu TPM).

**compatible**
Właściwość w device tree, np. `compatible = "brcm,bcm2835-i2c"`. Kernel szuka sterownika, który deklaruje obsługę tego samego ciągu. Tak łączy się wpis DT ze sterownikiem, co jest dokładnie tym, co kryterium każe Ci zrozumieć dla dwóch peryferiów.

**status = "okay" / "disabled"**
Właściwość w DT włączająca lub wyłączająca urządzenie. Zadanie „wyłącz i włącz z powrotem przez DT” sprowadza się do zmiany tej właściwości (przez overlay lub własny DTB) albo do usunięcia sterownika z konfiguracji kernela.

**dtoverlay / dtparam**
Wpisy w `config.txt`, które dokładają overlaye lub ustawiają parametry DT, np. `dtparam=spi=on`, `dtoverlay=disable-wifi`. To jest zmiana konfiguracji DT, a nie raspi-config, więc spełnia kryterium.

**GPIO**
Piny ogólnego przeznaczenia: włącz/wyłącz, odczytaj stan. Nowoczesne narzędzia to `libgpiod` (`gpiodetect`, `gpioset`, `gpioget`). Najprostszy test to dioda LED.

**I2C**
Dwuprzewodowa magistrala do czujników i małych układów. Każde urządzenie ma adres. `i2cdetect -y 1` skanuje magistralę i pokazuje, co jest podłączone.

**SPI**
Szybsza magistrala (4 przewody), też do czujników, wyświetlaczy, a w zadaniu 4 do modułu TPM. W systemie widoczna jako `/dev/spidev*`.

**PCIe**
Szybka magistrala rozszerzeń. Na RPi 5 jest złącze na np. dysk NVMe (przez nakładkę). Test: `lspci`.

**USB / Ethernet**
Testy: `lsusb`, `ip link`, `ethtool eth0` (pokaże prędkość 1000 Mb/s).

**WiFi: firmware i regulatory domain**
Układ WiFi w RPi (sterownik `brcmfmac`) potrzebuje pliku firmware w `/lib/firmware`. Do pasma 5 GHz trzeba ustawić kraj (regulatory domain, `iw reg set PL`), inaczej część kanałów będzie zablokowana. Połączenie przez `wpa_supplicant` lub `iwd`.

**ALSA / HDMI (KMS)**
ALSA to podstawowy system dźwięku w Linuksie (`aplay -l`, `speaker-test`). Obraz HDMI obsługuje sterownik grafiki `vc4` przez interfejs DRM/KMS. Test: `modetest` lub komunikaty w `dmesg`.

---

## Zadanie 4: Yocto, secure boot, TPM, TEE, PKCS#11

### Yocto

**Yocto Project / Poky**
Zestaw narzędzi do budowania własnej dystrybucji Linuksa dla urządzeń embedded. Filozofia podobna do Gentoo (wszystko ze źródeł), ale cały obraz systemu powstaje na PC, a nie na urządzeniu. Poky to referencyjna dystrybucja startowa.

**BitBake**
Silnik budujący w Yocto (odpowiednik emerge). Polecenie `bitbake core-image-minimal` buduje cały obraz systemu.

**Recipe (.bb) / .bbappend**
*Recipe* to przepis na jedną paczkę (jak ebuild). *bbappend* to modyfikacja cudzego przepisu bez edytowania oryginału, np. dodanie łatki albo zmiana konfiguracji.

**Layer (warstwa, meta-*)**
Katalog grupujący przepisy, np. `meta-raspberrypi`, `meta-security`, `meta-arm`. Kryterium wymaga własnej warstwy z podziałem na:
- **BSP** (*Board Support Package*): wszystko, co dotyczy sprzętu (kernel, device tree, bootloader),
- **distro**: polityka systemu (init, opcje bezpieczeństwa, domyślne funkcje),
- **aplikacje**: Twoje programy i obraz.

**MACHINE / DISTRO**
Zmienne w `local.conf` mówiące, dla jakiego sprzętu (`MACHINE = "raspberrypi5"` lub `"qemuarm64"`) i z jaką polityką budujesz. Dzięki temu ten sam obraz zbudujesz też pod QEMU, czego wymaga kryterium.

**sstate cache / powtarzalność**
Yocto zapamiętuje wyniki budowania (sstate), więc kolejne buildy są szybkie. Powtarzalny build oznacza, że te same wejścia dają ten sam obraz. Pomagają w tym przypięte wersje warstw (konkretne commity) i np. narzędzie `kas`, które opisuje całą konfigurację w jednym pliku YAML.

### Secure boot i measured boot

**Secure boot vs measured boot**
Najważniejsze rozróżnienie w tym zadaniu:
- **Secure boot**: każdy etap *sprawdza podpis* następnego i *nie uruchomi* niepodpisanego kodu. Blokuje.
- **Measured boot**: każdy etap *mierzy* (liczy hash) następny i zapisuje wynik w TPM, ale *niczego nie blokuje*. Potem można sprawdzić, co dokładnie się uruchomiło, albo uzależnić od tego odblokowanie klucza (zadanie 5).
Zadanie 4 wymaga measured boot.

**Łańcuch zaufania (chain of trust) / root of trust**
Każdy etap startu ufa poprzedniemu i weryfikuje lub mierzy następny. Pierwsze ogniwo (root of trust) musi być zaufane z założenia, bo nikt go nie sprawdza.

**TPM 2.0**
*Trusted Platform Module*: osobny, odporny na manipulację układ z własnym procesorem i pamięcią. Przechowuje klucze tak, że nie da się ich wyciągnąć, i trzyma rejestry PCR. Twój moduł Infineon SLB 9670 łączy się przez SPI (sterownik kernela `tpm_tis_spi`, w `config.txt` overlay `tpm-slb9670`). W systemie pojawia się jako `/dev/tpm0` i `/dev/tpmrm0`.

**PCR (Platform Configuration Register)**
Rejestry w TPM, do których nie da się wpisać dowolnej wartości. Można je tylko **rozszerzyć** (*extend*):
`nowa_wartość = hash(stara_wartość || pomiar)`
Dlatego końcowa wartość PCR zależy od wszystkich pomiarów i ich kolejności. Zmiana jednego bajtu w kernelu daje zupełnie inną wartość. Resetują się tylko przy restarcie.

**Event log**
Dziennik zapisujący, co i w jakiej kolejności zostało zmierzone do PCR-ów. Pozwala odtworzyć i wyjaśnić wartości PCR (`tpm2_eventlog`).

**Mapa PCR 0–7 (specyfikacja TCG dla PC)**
| PCR | Co jest mierzone |
|---|---|
| 0 | Kod firmware (BIOS/UEFI) |
| 1 | Konfiguracja firmware |
| 2 | Kod rozszerzeń (option ROM, sterowniki UEFI) |
| 3 | Konfiguracja rozszerzeń |
| 4 | Kod bootloadera |
| 5 | Konfiguracja bootloadera, tablica partycji |
| 6 | Zdarzenia specyficzne dla platformy (np. wybudzanie) |
| 7 | Stan i polityka secure boot |

**Uwaga do notatki:** to mapa z PC z UEFI. Raspberry Pi nie ma natywnego mierzonego startu: bootloader z EEPROM i firmware GPU niczego nie mierzą. Pierwszym etapem, który mierzy, jest zwykle U-Boot (z włączonym measured boot) albo firmware UEFI (EDK2) dla RPi. Wartości PCR na RPi trzeba więc objaśniać według tego, jak dany bootloader je wypełnia, a brak pomiaru wcześniejszych etapów to realne ograniczenie, które warto opisać.

**Pojęcia TPM**
- **Hierarchie**: owner (dla Ciebie, użytkownika), endorsement (tożsamość układu), platform (producent).
- **EK** (*Endorsement Key*): unikalny klucz tożsamości TPM.
- **SRK** (*Storage Root Key*): klucz nadrzędny, pod którym tworzysz własne klucze.
- **Persistent handle**: adres (np. `0x81000001`), pod którym klucz zostaje w TPM na stałe.
- **Sealing / unsealing**: zaszyfrowanie danych tak, że TPM odda je tylko przy spełnionych warunkach (np. określone wartości PCR). Kluczowe w zadaniu 5.
- **tpm2-tss / tpm2-tools / tpm2-pkcs11**: biblioteka do komunikacji z TPM, narzędzia wiersza poleceń (`tpm2_pcrread`, `tpm2_createprimary`) i moduł udostępniający TPM przez interfejs PKCS#11.

### TEE / OP-TEE

**TrustZone**
Funkcja procesorów ARM dzieląca procesor na dwa „światy”:
- **Normal World**: zwykły Linux i Twoje programy,
- **Secure World**: odizolowane środowisko, do którego Linux nie ma dostępu.

**TEE (Trusted Execution Environment)**
Bezpieczne środowisko wykonawcze działające w Secure World. **OP-TEE** to otwartoźródłowy system operacyjny TEE.

**TF-A (Trusted Firmware-A)**
Firmware startujące na ARM jako pierwsze, ładujące OP-TEE do Secure World i przełączające między światami (element BL31 to tzw. *secure monitor*).

**TA / CA**
- **TA** (*Trusted Application*): mała aplikacja działająca wewnątrz OP-TEE (np. PKCS#11 TA przechowująca klucze).
- **CA** (*Client Application*): zwykły program w Linuksie, który prosi TA o wykonanie operacji.
- **tee-supplicant**: demon w Linuksie pomagający OP-TEE (np. w dostępie do pamięci masowej).

**xtest**
Zestaw testów OP-TEE. Przejście xtest jest dowodem, że TEE działa poprawnie.

**Uwaga do notatki:** Raspberry Pi nie ma sprzętowej izolacji pamięci dla Secure World, więc OP-TEE na RPi to demonstracja działania, a nie realna ochrona. Port dla RPi 5 jest niedojrzały, stąd w zadaniu dopuszczona ścieżka QEMU ARMv8.

### PKCS#11

**PKCS#11 (Cryptoki)**
Standardowy interfejs programistyczny do urządzeń kryptograficznych (karty, tokeny USB, TPM, TEE). Aplikacja mówi „podpisz tym kluczem” i nie musi wiedzieć, czy klucz siedzi w TPM, w TEE czy na karcie. Dlatego zadanie każe spiąć PKCS#11 z obydwoma.

**Slot / token / obiekt / PIN**
- **Slot**: „czytnik”, miejsce, w którym może być token,
- **token**: „karta”, magazyn kluczy,
- **obiekt**: klucz lub certyfikat w tokenie,
- **PIN / SO-PIN**: PIN użytkownika i PIN administratora (Security Officer).

**OpenSC (pkcs11-tool) / libp11**
`pkcs11-tool` to narzędzie do operacji na tokenach (generowanie klucza, podpis). `libp11` pozwala OpenSSL korzystać z kluczy przez PKCS#11.

---

## Zadanie 5: LUKS + TPM sealing

**dm-crypt / LUKS2**
dm-crypt to mechanizm szyfrowania dysku w kernelu. LUKS to standardowy format nagłówka (wersja 2 jest aktualna). Narzędzie: `cryptsetup`. Na serwerach CentOS spotkałeś to pewnie przy szyfrowanych instalacjach.

**Volume key / keyslot**
Dane szyfruje jeden główny klucz (*volume key*). LUKS przechowuje go w kilku *keyslotach*, a każdy keyslot otwiera się inną metodą: hasłem, plikiem klucza albo TPM. Dzięki temu masz jednocześnie automatyczne odblokowanie przez TPM i hasło awaryjne (recovery), czego wymaga kryterium.

**systemd-cryptenroll / crypttab**
`systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/sdX` dodaje do LUKS keyslot zapieczętowany w TPM pod politykę wybranych PCR-ów. `/etc/crypttab` mówi systemowi, które partycje odblokować przy starcie. Alternatywa: **clevis** z pinem `tpm2`.

**Polityka PCR**
Warunek: „oddaj klucz tylko wtedy, gdy PCR-y X, Y, Z mają dokładnie te wartości”. Zmiana kernela lub konfiguracji zmienia PCR, TPM odmawia, a system pyta o hasło recovery. To jest scenariusz testowy z kryterium.

**Re-sealing przy aktualizacji**
Problem: legalna aktualizacja kernela też zmienia PCR-y, więc po restarcie TPM odmówi. Rozwiązanie, które masz opracować, to procedura: przed restartem przewidzieć nowe wartości PCR (albo tymczasowo odblokować hasłem), a potem ponownie zapieczętować klucz pod nowe wartości. Zaawansowana alternatywa to *podpisane polityki PCR* (TPM2 PolicyAuthorize, w systemd: `systemd-pcrlock` lub podpisane UKI), gdzie klucz zależy nie od konkretnych wartości, tylko od Twojego podpisu na nich.

---

## Na koniec: TPM vs TEE w pigułce

| | TPM | TEE (OP-TEE) |
|---|---|---|
| Czym jest | Osobny fizyczny układ | Odizolowany tryb tego samego procesora |
| Mocna strona | Odporność na wyciąganie kluczy, pomiary startu (PCR) | Może uruchamiać własny, dowolny kod w izolacji |
| Słabsza strona | Wolny, ograniczony zestaw operacji | Bezpieczeństwo zależy od sprzętowej izolacji i od firmware |
| Kiedy wybrać | Przechowywanie kluczy, attestation, wiązanie szyfrowania ze stanem startu | Logika biznesowa wymagająca ochrony (DRM, własne algorytmy, płatności) |

Rozbudowana wersja tej tabeli to dobry szkielet notatki wymaganej w zadaniu 4.
