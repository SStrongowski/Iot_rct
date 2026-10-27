# Zadanie 5: Szyfrowanie storage — LUKS + TPM sealing — notatka projektowa

**Status:** kryteria zrealizowane i przetestowane na `iot-qemuarm64-secureboot` (QEMU ARMv8, swtpm, measured boot z zadania 4); `provision-data.sh` przetestowany od zera (czysty obraz dysku, nowy stan swtpm → automatyczne odblokowanie po restarcie);
**Artefakty:** opis dysku z partycją `data` (`meta-iot-bsp/files/wic/iot-qemuarm64-efi.wks`), przepis `meta-iot-apps/recipes-core/iot-data` (`crypttab`, `data.mount`), paczki w `iot-image`, skrypty `zadanie_5/scripts/provision-data.sh` i `iot-kernel-update.sh`
**Dowody:** `zadanie_5/dowody/` — dzienniki `systemd-cryptsetup@data` (stan prawidłowy, manipulacje, aktualizacja), zrzuty PCR przed/po, `luksDump`, katalog `dowody-aktualizacja/<data>/` z przebiegu skryptu

## Kryteria ukończenia i dowody

| Kryterium | Stan | Dowód |

| Partycja otwiera się automatycznie wyłącznie przy nienaruszonym łańcuchu bootowania | ☑ | dziennik: tylko `Starting`/`Finished Cryptography Setup for data`, bez pytania o hasło |
| Po manipulacji (zmiana kernela/konfiguracji) — odmowa + recovery z passphrase | ☑ | parametry kernela: zmiana tylko PCR 12; kernel: zmiana PCR 4; dziennik `TPM policy does not match current system state`, odblokowanie hasłem awaryjnym |
| Aktualizacja: nowe wartości PCR → re-sealing w procedurze update'u (rozwiązany samodzielnie, opisany) | ☑ | `iot-kernel-update.sh` (systemd-pcrlock); nowy kernel zmierzony skrótem identycznym z przewidzianym, automatyczne odblokowanie, slot LUKS niezmieniony |


## Architektura

```
partycja data (GPT, etykieta "data") ──▶ nagłówek LUKS2
    ├── keyslot 0: hasło awaryjne (człowiek)
    ├── keyslot 1: losowy klucz zapieczętowany w TPM
    └── token systemd-tpm2: tpm2-pcrlock = true, tpm2-pcrlock-nv = true
            │
            └──▶ polityka w TPM (indeks NV): dozwolone stany PCR 0+4+7+12
                 (PolicyAuthorizeNV; zawartość zmienia tylko systemd-pcrlock)

start: crypttab → systemd-cryptsetup@data → TPM (tpm_tis, /dev/tpmrm0) → /dev/mapper/data → data.mount → /data
```

| Element | Warstwa / miejsce | Zawartość |

| partycja `data` (256 MB, pusta) | BSP — `iot-qemuarm64-efi.wks` | `part --label data --size 256M --align 1024 --use-uuid` |
| narzędzia | aplikacje — `iot-image` | `systemd-crypt` (`systemd-cryptenroll`, wtyczka `libcryptsetup-token-systemd-tpm2.so`), `cryptsetup`, `e2fsprogs-mke2fs` |
| konfiguracja odblokowania | aplikacje — przepis `iot-data` | `/etc/crypttab`, `data.mount` (włączony przez `inherit systemd`), `RDEPENDS` na `systemd-crypt cryptsetup` |
| wsparcie TPM2 w systemd | distro — `DISTRO_FEATURES += tpm2` (zadanie 4) | systemd `+TPM2 +LIBCRYPTSETUP +LIBCRYPTSETUP_PLUGINS`, SRK tworzony przy starcie |
| sekrety (klucz wolumenu, polityka, PIN-y) | **urządzenie** — `provision-data.sh` | nigdy w obrazie ani w repozytorium |

## Podjęte decyzje

- **Szyfrowanie na urządzeniu, nie przy budowaniu obrazu:** klucz wolumenu powstaje na płytce i jest pieczętowany w jej TPM; obraz (z publicznego repo) zawiera tylko pustą partycję i opis, jak ją odblokować. Inaczej klucz byłby na maszynie budującej i identyczny na wszystkich urządzeniach.
- **Szyfrowana partycja danych, nie systemowa:** odblokowanie po zamontowaniu root — bez initramfs i bez kopii polityki na ESP.
- **Etykieta GPT `data` → `/dev/disk/by-partlabel/data`:** stała ścieżka niezależna od numeru partycji i nazwy dysku (`vda` w QEMU, `mmcblk0` na RPi).
- **`tpm2-device=/dev/tpmrm0` jawnie:** po dodaniu `optee-client` w systemie pojawił się drugi TPM (fTPM w OP-TEE, `optee-ftpm`); pieczętować trzeba w TPM, w którym zapisany jest łańcuch measured boot (`tpm_tis`/swtpm) — w fTPM PCR-y nie opisują startu.
- **`nofail` w crypttab, `WantedBy` w data.mount:** brak odblokowania nie zatrzymuje startu urządzenia bez ekranu — system działa, dane są zamknięte, można je otworzyć hasłem awaryjnym po zalogowaniu.
- **Jednostka `data.mount` zamiast wpisu w fstab:** `/etc/fstab` należy do `base-files` i jest generowany przez wic; osobny plik dodaje przepis bez nadpisywania cudzego pliku.
- **Hasło awaryjne (passphrase)** zgodnie z treścią zadania; alternatywa: `systemd-cryptenroll --recovery-key` (losowy klucz o wysokiej entropii).

### Wybór PCR do polityki: 0 + 4 + 7 + 12

| PCR | Co pilnuje | Wykryje |
| 0 | firmware (U-Boot) | podmianę bootloadera / firmware |
| 4 | kod systemd-boot i kernela | podmianę kernela (także brak jego pomiaru) |
| 7 | polityka secure boot | zmianę kluczy lub trybu secure boot |
| 12 | parametry kernela (systemd-boot) | np. `init=/bin/sh` |

Pominięte: PCR 5 (GPT + `loader.conf` — systemd-pcrlock nie opisuje pomiaru `loader.conf`), PCR 9 (dubluje parametry z PCR 12; zawiera pomiary systemd `nvpcr-init` z przestrzeni użytkownika), PCR 1 (zmienne rozruchowe UEFI zmieniane przez firmware). Kompromis: PCR 12 chroni przed manipulacją parametrami, ale każda ich legalna zmiana wymaga aktualizacji polityki (wariant komponentu `660-kernel-cmdline-sdboot`).

## Testy: łańcuch nienaruszony i manipulacje

| Scenariusz | Zmienione PCR | Reakcja |
| łańcuch nienaruszony | — | odblokowanie automatyczne (≈1 s) |
| dopisany parametr kernela `tamper=1` | 12 | `TPM policy does not match current system state` → hasło awaryjne (odblokowanie 18 s później, po wpisaniu) |
| cofnięcie zmiany | PCR 12 wraca do wartości z polityki | znów automatycznie — polityka wiąże klucz z konkretnym stanem |
| kernel z dopisanym bajtem | 4 | odmowa → hasło awaryjne |

**Odkrycie przy teście kernela:** kernela z doklejonym za ostatnią sekcją bajtem U-Boot **nie zmierzył wcale** (w PCR 4 trzy zdarzenia zamiast czterech — prawdopodobnie nie udało się policzyć skrótu PE), a mimo to go uruchomił (secure boot wyłączony). Polityka i tak zadziałała: wymaga konkretnego pomiaru kernela, a jego brak też daje inny PCR 4. Wnioski: polityka wymagająca obecności pomiaru chroni także przed jego pominięciem; measured boot bez secure boot dokumentuje, ale nie blokuje; symulacja „doklejonym bajtem” testuje inny scenariusz niż zamierzony.

## Procedura aktualizacji (re-sealing)

### Problem

Klucz związany z wartościami PCR; nowy kernel zmienia PCR 4. Dla TPM legalna aktualizacja wygląda jak atak.

### Rozważone podejścia

| | Podejście | Zalety | Wady |
| A | po aktualizacji: start z hasłem awaryjnym, `systemd-cryptenroll --wipe-slot=tpm2` i ponowne pieczętowanie | proste, ochrona ani na chwilę nie słabnie | człowiek z hasłem przy każdej aktualizacji — nie dla floty IoT |
| B | przed restartem tymczasowy słabszy slot (tylko PCR 0+7), po starcie pełna polityka i usunięcie slotu | automatyczne, tylko znane narzędzia | okno podatności na jeden start; ryzyko pozostawienia słabego slotu |
| **C** | **systemd-pcrlock: przewidywanie PCR, polityka jako lista dozwolonych stanów w indeksie NV** | **automatyczne, bez okna podatności, slot LUKS niezmieniony** | najbardziej złożone; narzędzie projektowane pod PC/UEFI (U-Boot mierzy rzeczy nieznane narzędziu) |
| D | podpisane polityki PCR (`--tpm2-public-key`): klucz zależy od podpisu na wartościach PCR | skaluje się na flotę, urządzenie nic nie przepieczętowuje | narzędzia systemd praktycznie dla PCR 11 i UKI — wymagałoby przejścia na UKI |

**Wybór: C.** Wykonalność sprawdzona przed implementacją: `systemd-pcrlock log` poprawnie rozkłada dziennik U-Boota (dla każdego PCR wartość obliczona = odczytana).

### Mechanizm

- Start dzielony na **komponenty** (pliki `.pcrlock`); katalog `NNN-nazwa.pcrlock.d/` z kilkoma plikami = **warianty** (alternatywy) komponentu. Numer = kolejność pomiarów.
- `make-policy` oblicza wszystkie kombinacje i zapisuje je w **indeksie NV TPM**; slot LUKS jest zapieczętowany pod „politykę z indeksu NV” (`PolicyAuthorizeNV`), nie pod konkretne wartości.
- Zmiana zawartości indeksu wymaga sekretu zapieczętowanego **pod bieżącą politykę** — po manipulacji nie da się dopisać własnego kernela.

### Komponenty na płytce

| Komponent | Źródło | PCR |
| `250-firmware-code-early` i in. | `lock-firmware-code` (obejmuje też systemd-boot w PCR 4, mierzony przed separatorem) | 0, 2, 4 |
| firmware config | `lock-firmware-config` | 1, 3 |
| `240-secureboot-policy` | `lock-secureboot-policy` (SecureBoot, PK, KEK, db, dbx) | 7 |
| `245-secureboot-modes-uboot` | **własny**, z dziennika: `DeployedMode`, `AuditMode` (mierzone przez U-Boot, nieznane narzędziu) | 7 |
| GPT, parametry (PCR 9) | `lock-gpt`, `lock-kernel-cmdline` | 5, 9 |
| `650-kernel.pcrlock.d/obecny` | `lock-pe /boot/Image` | 4 |
| `660-kernel-cmdline-sdboot.pcrlock.d/obecny` | **własny**, z dziennika: zdarzenie `ipl` (parametry mierzone przez systemd-boot) | 12 |

Gotowe komponenty systemd: separatory, `350-action-efi-application`, `400-secureboot-separator`, `700-action-efi-exit-boot-services`. Komponenty faz systemd (`750-enter-initrd` … `990-final`, PCR 11) pominięte — brak UKI.

### Procedura (`iot-kernel-update.sh`)

**`stage <nowy_kernel>`** (przed restartem):
1. kontrola: bieżący PCR 4 należy do obecnej polityki (inaczej polityki nie da się zaktualizować);
2. `lock-pe` nowego kernela jako wariant `nowy` → dozwolony stary **i** nowy;
3. kontrola: nowy wariant dodał stany PCR 4; bieżący stan nadal dozwolony;
4. `make-policy`, kontrola, że żaden PCR nie został pominięty;
5. instalacja nowego kernela (kopia poprzedniego zachowana).

**`finalize`** (po restarcie):
1. kontrole: na ESP zainstalowany kernel; kernel **zmierzony** w tym starcie; zmierzony skrót = skrót wariantu `nowy`; partycja odblokowana przez TPM;
2. dopiero wtedy `nowy` → `obecny` (usunięcie starego wariantu);
3. kontrola: bieżący stan dozwolony, **żaden stan sprzed aktualizacji już nie** (anty-rollback);
4. `make-policy`; dowody w `/root/dowody-aktualizacja/<data>/`.

W razie wątpliwości skrypt zostawia stary wariant — zawsze stan, z którego można się bezpiecznie wycofać.

### Wynik testu

Kernel zbudowany w Yocto (inny plik binarny): w dzienniku zdarzenie `File: \Image` przypisane do komponentu `650-kernel`, skrót `47f6d099…` = skrót w `nowy.pcrlock` obliczony przed restartem; partycja odblokowana automatycznie; zmiana tylko PCR 4; token LUKS niezmieniony (`tpm2-pcrlock: true`, ten sam slot).

## TPM vs ochrona sekretów — wnioski projektowe

- **Dwa hasła awaryjne o różnych rolach:** hasło LUKS ratuje **dane**; PIN awaryjny polityki pcrlock (`--recovery-pin`) ratuje **możliwość aktualizacji polityki**. Oba offline, poza repozytorium.
- **Błędna polityka blokuje własną poprawkę** (sekret do indeksu NV zapieczętowany pod starą politykę). Reguła: przed każdym `make-policy` `predict` musi zawierać bieżący stan.
- **Ścieżka ostatniej szansy:** `remove-policy` (uprawnienia właściciela TPM) + nowa polityka + ponowne pieczętowanie hasłem awaryjnym.

## Rozważone alternatywy

- Szyfrowanie partycji systemowej (initrd z `systemd-cryptsetup`, kopia polityki pcrlock na ESP) — większa ochrona, większa złożoność; zostawione na wersję docelową.
- `--tpm2-with-pin` (PIN użytkownika przy każdym starcie) — chroni przed kradzieżą całego urządzenia, ale wymaga człowieka — nie dla urządzenia bez ekranu.
- `--recovery-key` zamiast passphrase — silniejsze, zadanie wymaga passphrase.

## Mini threat-model (3 zdania)

1. **Co chronię:** dane na partycji `data` — szyfrowane LUKS2, klucz dostępny automatycznie tylko w znanym, zmierzonym stanie startu (firmware, bootloader, kernel, polityka SB, parametry kernela).
2. **Przed czym:** kradzieżą nośnika lub obrazu dysku (bez tego TPM klucz bezużyteczny), uruchomieniem zmodyfikowanego lub starszego kernela albo zmienionych parametrów (np. `init=/bin/sh`) w celu wydobycia danych — TPM odmawia, a aktualizacja nie otwiera okna podatności.
3. **Czego to NIE chroni:** atakującego z rootem w działającym systemie (dane są wtedy odblokowane), ataków na firmware przed pierwszym pomiarem (TF-A, OP-TEE), zaufania do stanu w chwili provisioningu (pomiary z tego startu stają się wzorcem), właściciela TPM bez hasła (może usunąć politykę — nie odzyska danych, ale wyłączy automatyczne odblokowanie), a w QEMU stanu swtpm w plikach hosta.

## Problemy i rozwiązania

| Problem | Przyczyna | Rozwiązanie |
| `mke2fs` w żadnej paczce | `e2fsprogs` nie był potrzebny wcześniej | `e2fsprogs-mke2fs` w obrazie |
| Brak `/dev/disk/by-partlabel/data`, `lsblk`, `findmnt` | uruchomiona płytka `qemuarm64` zamiast secureboot; narzędzia z `util-linux` | secureboot domyślnie w `run-qemu-tpm.sh`; BusyBox: `mount`, `df` |
| `Could not find TPM2 device: Name not unique on network` | drugi TPM (fTPM, `optee-ftpm`) po dodaniu `optee-client` | `tpm2-device=/dev/tpmrm0` w crypttab; odłączenie fTPM (`unbind`) przed systemd-pcrlock; docelowo fTPM wyłączony w BSP |
| `device-mapper: remove ioctl … busy` | wyścig z udev po `mke2fs` | odblokowanie przez `crypttab` + `udevadm settle` |
| systemd-pcrlock nie zna `DeployedMode`, `AuditMode`, `ipl` (PCR 12) | narzędzie projektowane pod PC/UEFI, U-Boot i systemd-boot mierzą więcej | własne komponenty ze skrótami z dziennika (automatycznie w `provision-data.sh`) |
| `None of the alternative values for PCR 4 …` po pierwszej polityce | systemd-boot w dwóch komponentach (`250-firmware-code-early` i `300-boot-loader`) → podwójny pomiar w przewidywaniu (`log` tego nie ujawnia) | usunięty zdublowany komponent; kontrola `predict` vs bieżące PCR przed `make-policy` |
| `make-policy` odmawia poprawki | sekret do indeksu NV zapieczętowany pod błędną politykę | `remove-policy` + nowa polityka + ponowne `systemd-cryptenroll` (hasło awaryjne); PIN awaryjny polityki |
| Kernel z doklejonym bajtem nie został zmierzony | U-Boot nie policzył skrótu PE, uruchomił bez pomiaru | symulacja kernelem zbudowanym w Yocto |
| `CONFIG_LOCALVERSION` bez efektu w `uname -r` | w linux-yocto dopisek ustawia `LINUX_VERSION_EXTENSION` | `LINUX_VERSION_EXTENSION:qemuarm64 = "-iot-v3"` |
| `finalize`: „predict nie zgadza się” | warianty komponentu firmware mnożą wartości PCR 4 — błędne założenie „jedna wartość” | kontrola: bieżący stan dozwolony i żaden stan sprzed aktualizacji |
| `provision-data.sh`: „przewidywanie PCR 12 nie zawiera bieżącej wartości” mimo zgodnych wartości | parsowanie `tpm2_pcrread`: dla PCR dwucyfrowych format `12: 0x…` (bez spacji) — pusta wartość bieżąca | odczyt samej wartości szesnastkowej (`grep -o '0x…'`); kontrola zatrzymała skrypt przed zapisem polityki |

## Do zrobienia

- fTPM wyłączony w BSP (`# CONFIG_TCG_FTPM_TEE is not set`) — jeden TPM, jednoznaczny wybór urządzenia.
- Na RPi 5: ten sam przepis i skrypty; polityka pod łańcuch startowy RPi (inny zestaw pomiarów → ponowne sprawdzenie `systemd-pcrlock log`); hasło właściciela TPM w produkcji.
