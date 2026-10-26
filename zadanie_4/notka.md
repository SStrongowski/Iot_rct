# Zadanie 4: Yocto + measured boot (TPM) + TEE (OP-TEE) + PKCS#11 — notatka projektowa

**Status:** wszystkie kryteria techniczne spełnione i zademonstrowane na wirtualnej płytce `iot-qemuarm64-secureboot` (QEMU ARMv8); do zrobienia: build dla `raspberrypi5` (dowód podziału warstw) i uruchomienie na sprzęcie z modułem TPM SLB 9670
**Artefakty:** `iot-wrynose.conf.json`, `artefakty/sources-fixed-revisions.json`, warstwy `meta-iot-bsp`, `meta-iot-distro`, `meta-iot-apps`, `scripts/run-qemu-tpm.sh`
**Dowody:** `dowody/` — zrzuty pierwszego startu, wyniki `tpm2-tools`, podpisy PKCS#11 (TPM i TEE), `eventlog.yaml`, `pcr-przed.txt` / `pcr-po.txt`, `xtest-regression.log`, `boot-efi.log`

## Kryteria ukończenia i dowody

| Kryterium | Stan | Dowód |

| Własna warstwa (meta-\*), czysty podział BSP / distro / aplikacje | ☑ | trzy warstwy `meta-iot-*`; sekcja „Architektura warstw” |
| Obraz buduje się powtarzalnie | ☑ | szablon `bitbake-setup` w repo + `sources-fixed-revisions.json` (dokładne commity warstw) |
| Obraz odpala się pod QEMU ARM64 | ☑ | `qemuarm64` i `iot-qemuarm64-secureboot` |
| Measured boot: kolejne etapy rozszerzają PCR-y; mapa PCR 0–7 | ☑ | `eventlog.yaml`, zgodność dziennika z PCR, eksperyment z parametrami kernela |
| `tpm2-tools` + `tpm2-pkcs11`: klucz w TPM, podpis przez PKCS#11 | ☑ | `tpm2_ptool`, `pkcs11-tool --sign`, `openssl dgst -verify` → `Verified OK` |
| OP-TEE uruchomione (QEMU ARMv8), `xtest` przechodzi | ☑ | `xtest -t regression`: 112 przypadków testowych, 35 591 podtestów, 0 błędów, 0 pominiętych |
| PKCS#11 TA spięte z libp11 / OpenSC | ☑ | podpis kluczem z OP-TEE przez `pkcs11-tool` oraz OpenSSL + libp11 (provider i engine) → `Verified OK` |
| Notatka: TPM vs TEE | ☑ | sekcja „TPM vs TEE” |


## Środowisko budowania

- Windows 10 + WSL2, Ubuntu 24.04 LTS (wspierane przez Wrynose)
- `.wslconfig`: 12 GB RAM, 12 wątków, 16 GB swap; host: Ryzen 7 3700X, 16 GB RAM
- Yocto 6.0 „Wrynose” (LTS do 04/2030), kernel 6.18, narzędzie `bitbake-setup` (zastępuje repozytorium poky)
- Repozytorium projektu w systemie plików WSL (`~/Iot_rct`), VS Code w trybie Remote-WSL; build w `~/yocto/bitbake-builds/`

## Architektura warstw

| Warstwa | Odpowiada na pytanie | Zawartość |

| `meta-iot-bsp` | **na czym działa?** | maszyna `iot-qemuarm64-secureboot` (start UEFI, deklaracje `efi`, `optee`), opis dysku `files/wic/iot-qemuarm64-efi.wks`, fragment kernela `tpm-tis-mmio.cfg` (`linux-yocto_%.bbappend`) |
| `meta-iot-distro` | **jakie zasady obowiązują?** | dystrybucja `iot` (`require poky-altcfg.conf` → systemd), `DISTRO_FEATURES += tpm2` |
| `meta-iot-apps` | **co robi urządzenie?** | przepis `iot-image` (TPM2, PKCS#11, OpenSC, libp11, SSH; narzędzia TEE warunkowo) |

Zasady podziału zastosowane w praktyce:
- **obraz pyta o możliwości sprzętu, nie o sprzęt:** narzędzia OP-TEE instalowane tylko gdy `MACHINE_FEATURES` zawiera `optee` (`bb.utils.contains`), a deklarację dodaje maszyna w BSP;
- **sterownik układu TPM to sprawa BSP:** fragment kernela z `SRC_URI:append:qemuarm64` (na RPi 5 inny interfejs — SPI, inny kernel);
- **format dysku to sprawa maszyny:** próba wymuszenia `QB_DEFAULT_FSTYPE` w przepisie obrazu zepsuła start maszyny z obrazem partycjonowanym — przeniesione do parametru skryptu startowego;
- **`local.conf` tylko na ustawienia hosta** (limity wątków, `rm_work`); wszystko, co opisuje produkt, jest w warstwach.

### Powtarzalność

- Szablon `iot-wrynose.conf.json`: źródła (bitbake 2.18; openembedded-core, meta-yocto, meta-openembedded, meta-arm, meta-security, meta-raspberrypi — gałęzie `wrynose`), lista warstw, własne warstwy przez `bb-layers-file-relative` (działa po sklonowaniu repo w dowolne miejsce), fragmenty `distro/iot` i `core/yocto/sstate-mirror-cdn`, wybór maszyny, warianty `iot-dev` (logowanie roota bez hasła) i `iot`.
- Odtworzenie setupu jednym poleceniem:
  ```bash
  bitbake-setup init --non-interactive zadanie_4/iot-wrynose.conf.json iot-dev machine/iot-qemuarm64-secureboot
  ```
- Dokładne commity warstw w `sources-fixed-revisions.json` (do użycia przez `--source-overrides`).
- Przy wielu setupach sstate i pobrane źródła są współdzielone.

## Podjęte decyzje

- **Yocto 6.0 Wrynose** (LTS do 2030, kernel 6.18 — ta sama gałąź co w Gentoo), mimo że wiele poradników dotyczy jeszcze workflow z repozytorium poky.
- **WSL2 zamiast VM:** brak narzutu VirtualBox przez Hyper-V, dynamiczna pamięć, natywny swtpm;
- **`poky-with-sstate`** (publiczny sstate mirror Yocto — odpowiednik oficjalnego binhosta Gentoo): pierwszy build `core-image-minimal` w 15 min (99% trafień: 2740 z 2751 zadań pobranych, 11 zbudowanych lokalnie).
- **Ograniczona równoległość** (`BB_NUMBER_THREADS = 6`, `PARALLEL_MAKE = -j 8`) i `rm_work` — 16 GB RAM i ograniczony dysk poniżej oficjalnych wymagań (32 GiB / 140 GiB).
- **Tylko podwarstwa `meta-security/meta-tpm`** (zależy od `core`, `meta-oe`, `meta-python`) bez głównej `meta-security`, `meta-perl` i `meta-networking` — mniej warstw, brak modyfikacji niepotrzebnych przepisów.
- **`tpm2` w `DISTRO_FEATURES`:** kernel z obsługą TPM oraz systemd z `+TPM2 +LIBCRYPTSETUP` (podstawa pod `systemd-cryptenroll` w zadaniu 5).
- **Sterownik `tpm_tis` wbudowany (=y):** TPM dostępny od pierwszych chwil startu (measured boot, odblokowanie LUKS) bez modułów w obrazie.
- **Maszyna `qemuarm64-secureboot` z meta-arm jako baza:** gotowy łańcuch TF-A BL1 → BL2 → BL31 + OP-TEE → U-Boot; jedna zmiana maszyny daje zarówno TEE, jak i bootloader zdolny do pomiarów.
- **Własna maszyna `iot-qemuarm64-secureboot` ze startem UEFI** (U-Boot → systemd-boot → kernel): przy domyślnym starcie klasycznym (`bootimg-partition`, `loader=u-boot`) U-Boot mierzył tylko PCR 0 i 7, nie mierzył kernela i nie przekazywał dziennika.
- **Własny opis dysku** (na bazie `meta-arm/wic/qemu-efi-disk.wks.in`): bez partycji swap (zużycie karty SD na RPi), bez `ip=dhcp` (siecią zarządza `systemd-networkd`), z jawnym `console=ttyAMA0`.
- **swtpm podłączony jako `tpm-tis-device`** z trwałym stanem w osobnym katalogu na maszynę (`swtpm-state`, `swtpm-secureboot`) — zachowanie jak fizycznego układu.

## Measured boot

### Przebieg dochodzenia

| Konfiguracja | PCR 0–7 | Obserwacje |

| `qemuarm64`, kernel ładowany bezpośrednio przez QEMU | same zera | kernel: `TPM error (256)` (`TPM_RC_INITIALIZE`) → sam wysyła `TPM2_Startup`; brak firmware, który rozpoczyna łańcuch |
| `qemuarm64-secureboot`, start klasyczny (U-Boot → kernel) | tylko PCR 0 i 7 | `TPM2_Startup` wysyła firmware; brak `/sys/firmware/efi`, brak dziennika zdarzeń w Linuksie, kernel niezmierzony |
| `iot-qemuarm64-secureboot`, start UEFI (U-Boot → systemd-boot → kernel) | pełny zestaw | kernel: `efi: … TPMEventLog=…`; dziennik w `/sys/kernel/security/tpm0/`; usługi TPM systemd aktywne (SRK, pomiary `machine-id`, NvPCR) |

### Mapa PCR (z dziennika zdarzeń płytki `iot-qemuarm64-secureboot`)

| PCR | Zdarzenia | Znaczenie | Kto mierzy |
|---|---|---|---|
| 0 | `EV_NO_ACTION`, `EV_S_CRTM_VERSION`, `EV_SEPARATOR` | nagłówek dziennika (bez rozszerzenia), wersja firmware (U-Boot = korzeń zaufania pomiarów) | U-Boot |
| 1 | 2× `EV_EFI_VARIABLE_BOOT2`, `EV_EFI_HANDOFF_TABLES2`, `EV_SEPARATOR` | konfiguracja firmware: zmienne rozruchowe UEFI, tabele przekazane systemowi | U-Boot |
| 2 | `EV_SEPARATOR` | kod modułów rozszerzeń — brak na płytce | U-Boot |
| 3 | `EV_SEPARATOR` | konfiguracja modułów rozszerzeń — brak | U-Boot |
| 4 | `EV_EFI_BOOT_SERVICES_APPLICATION` (systemd-boot), `EV_EFI_ACTION`, `EV_SEPARATOR`, `EV_EFI_BOOT_SERVICES_APPLICATION` (kernel) | kod uruchamianych programów EFI | U-Boot (UEFI) |
| 5 | `EV_EFI_GPT_EVENT`, `EV_SEPARATOR`, `EV_EVENT_TAG`, 2× `EV_EFI_ACTION` | tablica partycji GPT, znacznik bootloadera, wywołanie i zakończenie `ExitBootServices` | U-Boot, systemd-boot |
| 6 | `EV_SEPARATOR` | zdarzenia platformy — brak | U-Boot |
| 7 | 7× `EV_EFI_VARIABLE_DRIVER_CONFIG`, `EV_SEPARATOR` | polityka secure boot (`SecureBoot`, `PK`, `KEK`, `db`, `dbx` …) — mierzona także w stanie wyłączonym | U-Boot |
| 9 | `EV_EVENT_TAG` | parametry startowe zmierzone przez EFI stub kernela | kernel |
| 12 | `EV_IPL` | parametry kernela zmierzone przez systemd-boot | systemd-boot |

Separatory w PCR 0–7 oznaczają koniec fazy firmware: każdy późniejszy pomiar w tych rejestrach byłby widoczny jako anomalia.

### Weryfikacja i eksperyment

- **Zgodność dziennika:** wartości PCR odtworzone z dziennika przez `tpm2_eventlog` (sekcja `pcrs:`) identyczne z `tpm2_pcrread` → dziennik prawdziwy.
- **Eksperyment:** dopisanie `quiet` do parametrów kernela we wpisie systemd-boot → zmiana **tylko PCR 9 i 12** (parametry mierzone niezależnie przez systemd-boot i przez kernel). PCR 0–7 bez zmian — kod firmware, bootloadera i kernela (PCR 4) bit w bit identyczny.

### Ograniczenia

- Korzeniem zaufania pomiarów jest U-Boot: TF-A i OP-TEE przed nim nie mierzą (analogicznie na RPi 5 — firmware w EEPROM nie mierzy).
- PCR 11 niewykorzystany: `systemd-pcrextend` pomija pomiary, bo kernel nie jest uruchamiany jako UKI (Unified Kernel Image) — możliwe rozszerzenie.
- Measured boot niczego nie blokuje; ochrona działa przez atestację lub pieczętowanie (zadanie 5). Secure boot (weryfikacja podpisów) wyłączony.

## OP-TEE

- Łańcuch: TF-A BL1 → BL2 → BL31 (Secure Monitor) + OP-TEE 4.9 (Secure World) → U-Boot (Normal World).
- Linux: sterownik `optee`, urządzenia `/dev/tee0` (aplikacje) i `/dev/teepriv0` (`tee-supplicant`).
- `tee-supplicant` jako usługa szablonowa `tee-supplicant@teepriv0.service`, uruchamiana przez udev po pojawieniu się urządzenia; wczytuje TA z `/lib/optee_armtz/` i obsługuje bezpieczny magazyn.
- Paczki w obrazie (warunkowo, `optee` w `MACHINE_FEATURES`): `optee-client` (`libteec`, `libckteec`, `tee-supplicant`), `optee-test` (`xtest` + testowe TA), `optee-os-ta` (TA dostarczane z OP-TEE, m.in. PKCS#11 `fd02c9da-306c-48c7-a49c-bbd827ae86ee`).
- `xtest -t regression`: 112 przypadków testowych / 35 591 podtestów, 0 błędów, 0 pominiętych;


## TPM vs TEE

| | TPM 2.0 | TEE (OP-TEE w TrustZone) |

| Czym jest | osobny układ: własny procesor, pamięć, generator liczb losowych, odporność na manipulację fizyczną | odizolowany tryb tego samego procesora (Secure World) z własnym systemem (OP-TEE) |
| Kod | stały zestaw funkcji zdefiniowany specyfikacją TCG | dowolne aplikacje zaufane (TA) — można napisać własną logikę |
| Mocne strony | przechowywanie kluczy, PCR i measured boot, atestacja, pieczętowanie sekretów pod stan systemu | wykonywanie własnego kodu w izolacji (np. DRM, płatności, własne protokoły), bezpieczny magazyn, szybkość (ten sam procesor) |
| Słabe strony | wolny, ograniczony zestaw operacji, brak własnej logiki | bezpieczeństwo zależy od sprzętowej izolacji (TZASC, bezpieczna pamięć) i poprawności firmware (TF-A, OP-TEE); współdzieli procesor z Normal World (ataki boczne) |
| Przed czym chroni | wydobyciem kluczy (także fizycznie), niewykrytą podmianą oprogramowania startowego | dostępem systemu Normal World (nawet roota w Linuksie) do kluczy i kodu TA |
| Czego nie chroni | logiki aplikacji (wykonuje tylko swoje operacje); działającego systemu przed atakującym z rootem, który może używać TPM | przed atakami fizycznymi na pamięć; gdy brak sprzętowej izolacji — praktycznie przed niczym |
| Kiedy wybrać | tożsamość urządzenia, klucze o długim życiu, wiązanie szyfrowania z integralnością startu (zadanie 5), atestacja zdalna | gdy trzeba wykonać chronioną logikę albo brak fizycznego TPM (fTPM jako TA) |

**Przenikanie się:** maszyna `qemuarm64-secureboot` deklaruje `optee-ftpm` — TPM zaimplementowany jako TA w OP-TEE (firmware TPM). W tej konfiguracji fTPM nie jest aktywny (jedynym TPM jest swtpm przez `tpm_tis`). fTPM jest tak bezpieczny jak izolacja TrustZone, na której działa — dlatego na płytkach bez pełnej izolacji (RPi) dyskretny układ (SLB 9670) jest właściwym wyborem dla kluczy i measured boot, a TEE uzupełnieniem dla chronionej logiki.

## Rozważone alternatywy

- **Yocto 5.0 Scarthgap** (niższe wymagania, więcej poradników) — odrzucony na rzecz nowszego LTS z kernelem 6.18.
- **VM z Ubuntu w VirtualBox** — wolniejsza (Hyper-V) i ze stałą rezerwacją RAM;
- **`poky` bez sstate mirror** — wszystko lokalnie, wielogodzinny pierwszy build.
- **U-Boot `MEASURED_BOOT` przy starcie klasycznym** (pomiar obrazów `bootm`, dziennik przez device tree) — wybrano start UEFI (standardowy protokół TCG2, dziennik przez tabelę EFI, współpraca z systemd).
- **Szablon `qemu-efi-disk.wks.in` z meta-arm bez zmian** — swap i `ip=dhcp` niepożądane.
- **Magazyn `tpm2-pkcs11` w domyślnym miejscu (katalog domowy)** vs stały `/var/lib/tpm2-pkcs11` (przepis `iot-env`, opcjonalny) — kwestia przewidywalności lokalizacji opakowanych kluczy.

## Mini threat-model (3 zdania)

1. **Co chronię:** klucze urządzenia (w TPM i w OP-TEE — nigdy w postaci jawnej w Linuksie) oraz wiarygodną informację o tym, jakie oprogramowanie wystartowało (PCR + zweryfikowany dziennik zdarzeń).
2. **Przed czym:** kradzieżą kluczy z dysku lub przez proces w Linuksie (bloby bez układu TPM / dane tokenu OP-TEE bez Secure World są bezużyteczne) oraz niewykrytą podmianą bootloadera, kernela lub jego parametrów.
3. **Czego to NIE chroni:** pierwszych etapów przed U-Bootem (TF-A, OP-TEE nie mierzą), uruchomienia zmodyfikowanego systemu (brak secure boot — measured boot tylko dokumentuje), roota w działającym systemie, który może używać kluczy przez PKCS#11 (zna PIN-y), a w QEMU — emulowanego TPM, którego stan leży w plikach hosta; obraz `iot-dev` dopuszcza logowanie roota bez hasła i nie może trafić poza laboratorium.

## Problemy i rozwiązania

| Problem | Przyczyna | Rozwiązanie |
| `ModuleNotFoundError: websockets` | serwer równoważności skrótów (`wss://hashserv…`) wymaga modułu Pythona | `pip install websockets` w venv + `python3-websockets` w systemie |
| `runqemu`: `.zst images are only supported with snapshot mode` | domyślny obraz skompresowany | `snapshot` lub `ext4` jako argument / `IMAGE_FSTYPES += ext4` |
| Brak logowania roota | w Wrynose `debug-tweaks` rozbity na osobne opcje | fragment `core/yocto/root-login-with-empty-password` (tylko wariant `iot-dev`) |
| `Nothing PROVIDES 'iot-image'` | pliki tworzone ze starą ścieżką repo | poprawienie lokalizacji; kontrola `find` |
| `'security' has not been enabled` | główna warstwa `meta-security` niepotrzebna | usunięta z szablonu (z `meta-perl`, `meta-networking`), została `meta-tpm` |
| Urządzenie `c000000.tpm_tis` bez sterownika, brak `/dev/tpm0` | kernel bez `TCG_TIS` dla układu MMIO (`tcg,tpm-tis-mmio`) | fragment `tpm-tis-mmio.cfg` w BSP |
| Kernel panic `Unable to mount root fs on unknown-block(253,2)` | `QB_DEFAULT_FSTYPE = ext4` w przepisie obrazu: sam system plików zamiast dysku z partycjami | usunięte z obrazu (format zależy od maszyny), parametr `FSTYPE` w skrypcie |
| Fragment kernela dołączany podwójnie | `MACHINEOVERRIDES` secureboot zawiera `qemuarm64` | jeden wpis `:qemuarm64` (`bitbake-getvar MACHINEOVERRIDES`) |
| PCR 1–6 puste, brak dziennika, brak `/sys/firmware/efi` | U-Boot uruchamiał kernel bez UEFI | własna maszyna ze startem przez systemd-boot |
| `No kickstart files … iot-qemuarm64-efi.wks` | wic szuka w `files/wic/`, nie w `wic/` | przeniesienie pliku; nazwa wtyczki `bootimg-efi` (z myślnikiem) |
| W Wrynose brak `scripts/lib/wic` | wic jest osobnym przepisem | wzorce opisów dysku z `meta-arm/files/wic/` |
| `C_Initialize … CKR_GENERAL_ERROR` po restarcie | zmienna `TPM2_PKCS11_STORE` tylko w sesji | ponowne `export`; trwale: `/etc/profile.d` (przepis `iot-env`) |
| `systemd-analyze: not found` | osobna paczka | opcjonalnie do obrazu |
| `pkcs11_1001 FAILED`, `TEEC open session failed ffff0008` | brak TA PKCS#11 w obrazie (`TEEC_ERROR_ITEM_NOT_FOUND`) | paczka `optee-os-ta` (`oe-pkgdata-util find-path`) |

## Wnioski

- Yocto automatyzuje wszystko, co w zadaniach 1–2 było ręczne (toolchain, sysroot, zależności, obraz dysku, konfiguracja offline) — rozumienie tych mechanizmów skraca diagnozę (sterownik bez urządzenia → zadanie 3, `root=PARTUUID` → zadania 1–2).
- Powtarzalność opiera się na skrótach wejść: ten sam skrót = ten sam wynik, niezależnie od tego, czy zbudowany lokalnie, czy pobrany z sstate mirror.
- Measured boot wymaga ciągłości: brak jednego ogniwa (firmware → bootloader UEFI → kernel) daje PCR-y, które nie opisują systemu, mimo że TPM działa poprawnie.
- `bitbake-getvar` (z historią operacji), `oe-pkgdata-util` i `MACHINEOVERRIDES` to podstawowe narzędzia diagnostyki w Yocto.

## Do zrobienia

- Build `iot-image` dla `raspberrypi5` z tego samego szablonu (bez zmian w warstwach distro i aplikacji).
- Na RPi 5: moduł TPM SLB 9670 na SPI (overlay `tpm-slb9670`, sterownik `tpm_tis_spi` w BSP), measured boot w łańcuchu RPi, OP-TEE — jeśli port dojrzały (w przeciwnym razie zostaje QEMU, zgodnie z treścią zadania).
- Wariant `iot` (bez logowania roota bez hasła): konto nie-root z kluczem SSH w obrazie.
- Opcjonalnie: UKI i PCR 11, przepis `iot-env`.
