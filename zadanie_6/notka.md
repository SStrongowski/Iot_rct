# Zadanie 6: Podpisane aktualizacje OTA — notatka projektowa

**Status:** kryteria zrealizowane i zademonstrowane na `iot-qemuarm64-secureboot` (QEMU ARMv8, swtpm); do zrobienia: system ratunkowy na partycji `rescue`, zmienne U-Boota generowane przy budowaniu
**Artefakty:** BSP: `iot-qemuarm64-ab.wks`, `u-boot-script-ab` (`boot.cmd`), fragmenty U-Boota i kernela, `libubootenv` (`fw_env.config`), `iot-bootpart`, `iot-hwrevision`; distro: `IOT_SW_VERSION`, przypięta wersja SWUpdate, bez NvPCR; aplikacje: `iot-update.bb` + `sw-description`, `swu-sign.sh`, `iot-ota` (`iot-update`, `iot-boot-ok`, `iot-pcrlock.sh`, `iot.cfg`, certyfikat), `swupdate_%.bbappend`, `iot-data`; skrypt `provision-data.sh`


## Kryteria ukończenia i dowody

| Kryterium | Stan | Dowód |

| Urządzenie odrzuca niepodpisany lub przepodpisany złym kluczem artefakt | ☑ | niepodpisany: *Image invalid*; zły klucz: *Signature verification failed*; zmieniony manifest z oryginalnym podpisem: *Signature verification failed* — zmienne U-Boota bez zmian |
| Zerwanie zasilania w połowie update'u → start ze starej partycji (bootcount + watchdog, automatyczny rollback) | ☑ | przerwanie po ~100 MB zapisu (`echo b > /proc/sysrq-trigger`): slot docelowy uszkodzony (`e2fsck` kod 12), start ze starego; wadliwy slot (brak kernela): 3 starty → *Bootlimit exceeded* → `altbootcmd` → stary slot |
| Anti-rollback: starsza wersja niż licznik → odmowa | ☑ | *No downgrading allowed: new version 1.0.0 < installed 1.1.0* |
| Dane provisioningu przeżywają upgrade | ☑ | aktualizacje 1.3.0 → 1.4.0 → 1.5.0 (w tym nowy kernel): `/data` odblokowane automatycznie, stan polityki w `/persist` |

## Architektura

```
fabryka (Yocto)                                       urządzenie
iot-image ──▶ rootfs.ext4.gz ─┐                       U-Boot ──▶ boot.scr (FAT) ──▶ slot A|B ──▶ kernel (PCR 4)
sw-description (wersja,       ├─▶ swugenerator        │  bootcount / bootlimit / altbootcmd     parametry (PCR 9)
  hw-compat, sha256)          │   + podpis CMS        │
SoftHSM ──PKCS#11──▶ swu-sign.sh ┘  ─▶ iot-update.swu ──▶ iot-update ──▶ SWUpdate (podpis, wersja, sha256, zapis, bootenv)
                                                          └─▶ polityka TPM: kernel + parametry nowego slotu
                                                      restart ──▶ iot-boot-ok: zatwierdzenie, min_version, stary slot bez klucza
```

### Układ dysku

| Nr | Etykieta | Zawartość | Wspólna dla slotów |

| 1 | `boot` (FAT) | `boot.scr`, `uboot.env`, `uboot-redund.env` | tak |
| 2 / 3 | `rootfsA` / `rootfsB` | system + kernel (`/boot/Image`), stały rozmiar 1 GiB | — |
| 4 | `rescue` | zarezerwowana (system ratunkowy — do zrobienia) | — |
| 5 | `data` | LUKS2 + TPM (zadanie 5): dane użytkownika | tak |
| 6 | `persist` | dane provisioningu: komponenty i opis polityki `pcrlock` (później tożsamość urządzenia) | tak |

Rozdzielenie `data` / `persist`: polityka TPM jest potrzebna **przed** odblokowaniem `data`, więc nie może na niej leżeć; nie jest tajna (opis polityki, blob bezużyteczny bez tego TPM).

## Podjęte decyzje

- **SWUpdate, nie Mender:** podpis CMS kluczem przez PKCS#11, wbudowany anti-rollback (`-N`), integracja ze zmiennymi U-Boota, bez serwera.
- **Slot wybiera U-Boot** (kryterium: bootcount w U-Boocie): deterministyczny `bootcmd` (`boot.scr` z partycji 1) zamiast `bootflow scan`, które uruchamiało pierwszą znalezioną metodę startu (kernel podany przez `runqemu`, systemd-boot ze slotu).
- **Kernel w slocie**, uruchamiany `bootefi` — nadal mierzony przez TCG2 w PCR 4; systemd-boot usunięty z obrazu.
- **Zmienne U-Boota na FAT, dwie kopie** (`uboot.env`, `uboot-redund.env`): zapis do emulowanego flasha z Linuksa blokował sterownik CFI w QEMU (najpierw `MEMLOCK`, potem synchronizacja przy zamknięciu — diagnoza przez `sysrq-trigger`); tak robi się to na Raspberry Pi. Dwie kopie: przerwany zapis nie niszczy obu.
- **Licznik startów tylko w trakcie aktualizacji** (`BOOTCOUNT_ENV`, `upgrade_available=1`): zwykłe starty nie zapisują zmiennych.
- **Watchdog:** `softdog` + `RuntimeWatchdogSec=30s`, `panic=10` — w QEMU brak sprzętowego watchdoga; `softdog` nie obsłuży zawieszenia kernela (na płytce: watchdog SoC).
- **Zatwierdzenie po `multi-user.target`** (surowe kryterium): wykryło demona SWUpdate blokującego start — demon wyłączony (aktualizacje z wiersza poleceń, mniej usług).
- **Blokada niezatwierdzonej aktualizacji w `iot-update`:** zawsze istnieje jeden znany, działający slot.
- **Kontrola zgodności sprzętu** (`/etc/hwrevision`, `hardware-compatibility`).
- **Podpis CMS kluczem z tokena SoftHSM** (`sensitive, always sensitive, never extractable, local`), tryb `CUSTOM` (`swugenerator` dokleja ścieżki), engine PKCS#11 — provider PKCS#11 w OpenSSL 3.0 zawieszał się z SoftHSM. Klucz i PIN poza repozytorium (`IOT_SIGNING_DIR` w `local.conf`), certyfikat (publiczny) w obrazie, `cert-purpose = codeSigning`, weryfikacja `opensslCMS`.
- **Anti-rollback:** `min_version` w zmiennych U-Boota (wspólne dla slotów), podnoszone przy zatwierdzeniu; wersja w jednym miejscu (`IOT_SW_VERSION`, distro).

### Polityka TPM w układzie A/B: PCR 0 + 4 + 7 + 9

| PCR | Co | Komponent |

| 0 | wersja U-Boota | z dziennika (`240-firmware-code`) — bez `lock-firmware-code`, który objąłby kernel (mierzony przed separatorem) |
| 4 | kernel slotu | `300-kernel.pcrlock.d/{A,B}` (przed `350-action-efi-application`) |
| 7 | polityka secure boot | `lock-secureboot-policy` + `245-…` (DeployedMode, AuditMode) |
| 9 | parametry kernela (stub EFI) | `710-kernel-cmdline.pcrlock.d/{A,B}` — różnią się PARTUUID |

PCR 12 zniknął razem z systemd-bootem; jego rolę przejął PCR 9. **NvPCR systemd wyłączone** (distro): kotwice `nvpcr-init` trafiały do PCR 9 zależnie od stanu w systemie plików slotu (przy pierwszym starcie nowego slotu i po przełączeniu), raz po odblokowaniu dysku (psując kontrolę w `iot-boot-ok`), raz przed (odmowa TPM). **fTPM wyłączony w kernelu** (BSP): odłączanie sterownika przy starcie trwało minutami (stan `D`).

### Aktualizacja a polityka

1. `iot-update` po zapisie obrazu: warianty kernela i parametrów slotu docelowego → kontrola → `make-policy`; błąd → cofnięcie przełączenia slotu. Przed restartem dopuszczone są oba sloty (rollback zachowuje dostęp do danych).
2. `iot-boot-ok` po zatwierdzeniu: warianty starego slotu na bok → kontrola → `make-policy` (błąd → przywrócenie). Usunięcie wariantu **parametrów** blokuje cały stary slot, nawet przy identycznym kernelu.

Wynik: przełączenie zmiennej `slot` na starszy system uruchamia go, ale TPM odmawia klucza (*None of the alternative values for PCR 9*).

## Rozważone alternatywy

- **systemd-boot z licznikiem prób** zamiast U-Boota — zachowuje PCR 12, ale kryterium mówi o bootcount w U-Boocie.
- **Zmienne we flashu** (bliżej płytek z NOR) — porzucone przez niezgodność sterownika CFI z emulacją QEMU.
- **Surowy podpis RSA** zamiast CMS — prostszy, ale bez certyfikatów (ważność, przeznaczenie, łańcuch).
- **Licznik wersji w TPM (NV counter)** zamiast zmiennej U-Boota — odporny na cofnięcie nawet z fizycznym dostępem do dysku; wymaga zapamiętania punktu startowego (nowy licznik startuje od najwyższej wartości w układzie).
- **Stan polityki na FAT** zamiast `persist` — źle znosi utratę zasilania.

## Mini threat-model (3 zdania)

1. **Co chronię:** integralność i pochodzenie oprogramowania urządzenia (tylko podpisane, zgodne ze sprzętem, nie starsze aktualizacje), ciągłość działania przy awarii (przerwany zapis, wadliwa wersja) oraz dostęp do danych tylko dla bieżącej, zatwierdzonej wersji systemu.
2. **Przed czym:** podsunięciem zmodyfikowanej, cudzej lub starej (podatnej) aktualizacji, utratą urządzenia przy przerwanej aktualizacji, uruchomieniem starszego systemu z dysku w celu wydobycia danych.
3. **Czego to NIE chroni:** atakującego z fizycznym dostępem do dysku zmieniającego `min_version` lub `boot.scr` (niemierzony skrypt może np. podsunąć własny device tree), modyfikacji systemu plików slotu offline (kernel i parametry są mierzone, rootfs nie — potrzebne dm-verity), kompromitacji maszyny budującej z tokenem podpisującym, a w laboratorium klucza w SoftHSM zamiast HSM/TPM.

## Problemy i rozwiązania

| Problem | Przyczyna | Rozwiązanie |
|---|---|---|
| `fw_setenv` zawieszał system, Ctrl+C nie działało | sterownik CFI vs emulacja flasha w QEMU (`MEMLOCK`, potem `sync` przy zamknięciu) | zmienne na FAT; diagnoza: `/proc/PID/syscall`, `sysrq-trigger` |
| U-Boot z jedną kopią zmiennych mimo fragmentu | opcja przemianowana (`CONFIG_ENV_REDUNDANT`), nieznane opcje ignorowane po cichu | sprawdzanie nazw w `Kconfig` i wynikowego `.config` |
| emergency mode: `/dev/sda1` | `wic` dopisał partycję FAT do `fstab` po nazwie urządzenia | bez punktu montowania w `.wks`, jednostka `.mount` po etykiecie |
| `boot.scr` się nie wykonywał | `bootflow scan` uruchamiał kernel podany przez `runqemu` (fw_cfg) | `QB_DEFAULT_KERNEL = "none"`, jawny `bootcmd` |
| `.bbappend` bez efektu | zła nazwa pliku | `bitbake-layers show-appends` |
| *HW compatibility not found* | brak `hardware-compatibility` / `/etc/hwrevision` | `iot-hwrevision` (BSP) + lista w `sw-description` |
| *bootloader support absent* | interfejs U-Boota jest, brak handlera sekcji `bootenv` | `CONFIG_BOOTLOADERHANDLER=y` |
| zatwierdzenie czekało | `swupdate.service` nie kończył startu (`multi-user.target`), potem `hvc0` (90 s) | demon wyłączony, `SERIAL_CONSOLES` tylko `ttyAMA0` |
| *HASH mismatch* | `.swu` uszkodzony przez wyłączenie QEMU przed zapisem buforów | `sync`; suma wykryła uszkodzenie — podpis chroni przed podmianą |
| podpis CMS zawieszał się | provider PKCS#11 + SoftHSM w OpenSSL 3.0 | engine PKCS#11 z modułem w pliku konfiguracyjnym |
| podpis nie trafiał do `.swu` | `swugenerator` dokleja własne ścieżki | `SWUPDATE_SIGN_TOOL` tylko z katalogiem kluczy |
| *unable to load key* | domyślny dostawca weryfikacji `opensslRSA` | `iot.cfg`: `digest-provider = opensslCMS`, `cert-purpose = codeSigning` |
| PCR 9 nieprzewidywalny | kotwice NvPCR systemd | NvPCR wyłączone (distro) |
| `iot-boot-ok` w stanie `D` | odłączanie fTPM przy starcie | fTPM wyłączony w kernelu (BSP) |

## Do zrobienia

- System ratunkowy na partycji `rescue` (np. obraz `swupdate-image` z `meta-swupdate`) i ścieżka startu po wyczerpaniu obu slotów.
- Zmienne U-Boota generowane przy budowaniu (`mkenvimage -r`) i umieszczane na FAT — bez ręcznego `saveenv` przy pierwszym starcie.
- Dowiązanie `/var/lib/systemd/pcrlock.json` → `/persist` (`tmpfiles.d`), żeby wtyczka tokenu znalazła politykę.
- Licznik wersji w TPM (NV counter) zamiast zmiennej U-Boota.
- Klucz podpisujący w TPM/HSM zamiast SoftHSM; podpisywanie w CI (zadanie 12).
- Na płytce: sprzętowy watchdog SoC (także w U-Boocie), zmienne w pamięci flash, podpisany FIT (secure boot, zadanie 13).
