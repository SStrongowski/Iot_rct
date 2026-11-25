# Zadanie 7: Tożsamość urządzenia i PKI — notatka projektowa

**Status:** kryteria zrealizowane i zademonstrowane (QEMU ARMv8, swtpm, usługi na hoście WSL); do zrobienia: automatyzacja odnawiania (serwer podpisujący / ACME), PIN tokena zapieczętowany w TPM, dwupoziomowe CA
**Artefakty:** `zadanie_7/ca/` (`ca.sh`, `openssl-ca.cnf`), `zadanie_7/services/` (`mosquitto.conf`, `mosquitto.acl`, `rest_server.py`); warstwa aplikacji: `iot-identity` (skrypt + CA floty), `mosquitto` (łatka przez `devtool`), `meta-networking` w szablonie; `run-qemu-tpm.sh` (trwały dysk urządzenia)
**Dowody:** `zadanie_7/dowody/` — atrybuty klucza (PKCS#11 i TPM), odmowa eksportu, blob TSS2 (`asn1parse`), podpis zweryfikowany certyfikatem, mTLS MQTT/REST (+ testy negatywne), rotacja w trakcie publikacji, rewokacja (`certificate revoked`)

## Kryteria ukończenia i dowody

| Kryterium | Stan | Dowód |
|---|---|---|
| Klucz prywatny nigdy nie opuszcza TPM (dowód, nie deklaracja) | ☑ | atrybuty obiektu TPM `0x00060072`: `fixedTPM`, `fixedParent`, `sensitiveDataOrigin`; PKCS#11: `sensitive, always sensitive, never extractable, local`; eksport odrzucony; na dysku tylko blob TSS2 z częścią prywatną zaszyfrowaną kluczem rodzica `0x81000000` |
| mTLS do mosquitto i REST, klucz klienta przez tpm2-pkcs11 | ☑ | `CONNACK (0)`; `/whoami` → CN i seria z certyfikatu; bez certyfikatu: połączenie zerwane; publikacja do cudzej gałęzi: `Denied PUBLISH` |
| Rotacja certyfikatu bez przestoju | ☑ | ciągła publikacja co ~1,5 s: przełączenie `1004` → `1005` o 11:49:20, bez błędów i luk |
| Rewokacja po stronie CA przetestowana | ☑ | `1004` (zastąpiony) i `1002` (osierocony) na CRL; broker: `certificate verify failed`; `openssl verify -crl_check`: `error 23 … certificate revoked`, `1005`: `OK` |

## Architektura

```
host (WSL)                                         urządzenie (QEMU)
mini-CA (OpenSSL)  ~/iot-ca (poza repo)            TPM: klucz EC P-256 (fixedTPM, sensitiveDataOrigin)
  ca.key, ca.crt, index.txt, crl.pem               /persist/identity:
    ▲ CSR (podpisany kluczem z TPM)                   device-id, PIN tokena, magazyn tpm2-pkcs11 (bloby),
    │                                                 certyfikaty, current (aktywny klucz)
    │  certyfikat ───────────────────────────────▶   /etc/iot-identity/ca.crt (CA floty, w obrazie)
mosquitto :8883 (mTLS, CN = użytkownik, ACL, CRL) ◀── mosquitto_pub --keyform engine --tls-engine pkcs11
REST API  :8443 (mTLS, CRL)                       ◀── curl --engine pkcs11 --key-type ENG
```

| Dane | Gdzie | Dlaczego |
|---|---|---|
| klucz prywatny urządzenia | TPM (na dysku tylko blob opakowany przez TPM) | nie da się go wynieść |
| certyfikaty urządzenia, identyfikator, magazyn | `/persist/identity` | unikalne dla egzemplarza; przeżywają aktualizacje A/B |
| certyfikat CA (kotwica zaufania) | obraz (`/etc/iot-identity`) | wspólny dla floty, jak certyfikat weryfikacji aktualizacji |
| klucz CA, klucze usług | host, `~/iot-ca` (poza repozytorium) | sekret CA |

## Podjęte decyzje

- **CA na OpenSSL, nie step-ca:** każdy krok wprost (CSR → podpis → CRL), bez dodatkowej usługi; step-ca lepszy przy automatycznym odnawianiu i krótko żyjących certyfikatach (ACME).
- **Jeden poziom CA** (laboratorium); w produkcji offline'owy root + CA wydające.
- **EC P-256** dla urządzeń: obsługiwana przez TPM, podpis ECDSA w TPM szybszy niż RSA — liczy się przy każdym uścisku dłoni TLS.
- **Polityka CA:** `unique_subject = no` (dwa ważne certyfikaty z tym samym CN — warunek rotacji), `copy_extensions = none` (CA decyduje o rozszerzeniach — urządzenie nie poprosi o `CA:TRUE`), osobne `extendedKeyUsage`: `clientAuth` (urządzenia) i `serverAuth` (usługi, SAN z `10.0.2.2`).
- **Klucz generowany w TPM, CSR na urządzeniu:** CA nigdy nie widzi klucza prywatnego; podpis CSR dowodzi posiadania klucza.
- **Magazyn tpm2-pkcs11 na `/persist`:** domyślny `~/.tpm2_pkcs11` jest w systemie plików slotu i znikałby przy aktualizacji.
- **Losowy identyfikator urządzenia** zapisany raz w `/persist` (nie `machine-id`, który jest w slocie).
- **Tożsamość z certyfikatu, nie z adresu:** w sieci QEMU (slirp) połączenia przychodzą z `127.0.0.1`; broker bierze nazwę użytkownika z CN (`use_identity_as_username`).
- **ACL z `%u`:** urządzenie publikuje tylko w `iot/<CN>/…` — przejęte urządzenie nie podszyje się pod inne.
- **Engine PKCS#11 (libp11)** w klientach (`mosquitto_pub`, `curl`, `openssl`): moduł `libtpm2_pkcs11` wskazany w pliku konfiguracji OpenSSL generowanym przez `iot-identity env`.
- **Rotacja:** nowy klucz obok starego, serwery ufają CA (nie konkretnemu certyfikatowi), atomowe przełączenie pliku `current`; po rotacji odwołanie starego certyfikatu i usunięcie starego klucza z TPM (`iot-identity retire`).
- **Rewokacja przez CRL** wczytywaną przez mosquitto (`crlfile`) i REST (`VERIFY_CRL_CHECK_LEAF`); po zmianie CRL przeładowanie usług.

### Dowód, że klucz nie opuszcza TPM

| Warstwa | Dowód |
|---|---|
| PKCS#11 | `sensitive, always sensitive, never extractable, local` |
| próba eksportu | `reading private keys not (yet) supported` |
| blob na dysku (`tpm2_ptool export`, `asn1parse`) | OID `2.23.133.10.1.3` (klucz TPM do wczytania), rodzic `0x81000000`, część prywatna zaszyfrowana kluczem rodzica (HMAC + IV + szyfrogram) |
| atrybuty obiektu w TPM | `0x00060072` = `fixedTPM` (bit 1), `fixedParent` (4), `sensitiveDataOrigin` (5), `userWithAuth` (6), `decrypt`/`sign` (17, 18) |
| spójność | punkt EC w blobie = klucz publiczny w PKCS#11 i w certyfikacie; podpis z TPM → `Verified OK` kluczem z certyfikatu |

Silniejszy dowód dla strony zdalnej: **certyfikacja klucza przez TPM** (`TPM2_Certify` kluczem attestation) — TPM sam podpisuje atrybuty obiektu; do zrobienia.

## Rozważone alternatywy

- **step-ca / ACME** zamiast ręcznego `ca.sh` — automatyczne odnawianie, krótkie czasy życia zamiast CRL.
- **OCSP** zamiast CRL — status w czasie rzeczywistym, ale wymaga dostępnej usługi; przy słabej łączności CRL lub krótkie certyfikaty.
- **Provider PKCS#11 (OpenSSL 3)** zamiast engine — nowocześniejszy; engine wybrany dla spójności z zadaniem 6 i obsługi w `mosquitto_pub`/`curl`.
- **Klucz w pliku na urządzeniu** — prostsze, ale klucz do skopiowania razem z nośnikiem.

## Mini threat-model (3 zdania)

1. **Co chronię:** tożsamość urządzenia (klucz prywatny w TPM, którego nie da się wynieść ani skopiować na inne urządzenie) oraz dostęp do usług tylko dla urządzeń z ważnym certyfikatem naszego CA, każde w granicach swoich uprawnień (ACL).
2. **Przed czym:** klonowaniem urządzenia lub jego tożsamości (kradzież nośnika, kopia magazynu tpm2-pkcs11), podszywaniem się pod inne urządzenie lub serwer, dalszym używaniem certyfikatu zastąpionego lub skompromitowanego (rewokacja).
3. **Czego to NIE chroni:** atakującego z rootem na urządzeniu (PIN tokena leży w pliku — może *używać* klucza, choć go nie wyniesie), kompromitacji klucza CA na hoście (plik, nie HSM), okna między odwołaniem a przeładowaniem CRL przez usługi oraz ataków na same usługi po stronie serwera.

## Problemy i rozwiązania

| Problem | Przyczyna | Rozwiązanie |
|---|---|---|
| `iot-identity init` na hoście | pomyłka terminala (`work@COMP`) | sprzątanie `/persist` na hoście; zasada: patrz na znak zachęty |
| `mosquitto_pub`: *Problem setting TLS options: File not found* | klient wywołuje `mosquitto_tls_set` przed ustawieniem `keyform engine` — URI `pkcs11:` sprawdzane jak plik PEM (`MOSQ_ERR_INVAL` opisany jako *File not found*) | diagnoza testem z pustym plikiem o nazwie URI; łatka (`devtool modify/finish`): engine i keyform przed `mosquitto_tls_set`, `Upstream-Status: Pending` |
| publikacja do cudzej gałęzi „przeszła” | MQTT 3.1.1, QoS 0: broker po cichu odrzuca | dowód po stronie serwera: `Denied PUBLISH` w logu, brak wiadomości u operatora |
| utrata `/persist` po buildzie | `runqemu` brał nowy obraz z deploy | trwały dysk urządzenia (`~/yocto/device`), dowiązanie w deploy przestawiane przed startem; zmiany tylko aktualizacją `.swu` |
| `runqemu` z plikiem spoza deploy | wymóg `-image-` w nazwie, `bitbake -e` z `MACHINE` kłóci się z fragmentem maszyny | zamiast ścieżki: dowiązanie w deploy na kopię urządzenia |
| `iot-identity: not found` po instalacji | przepis nie dopisany do `IMAGE_INSTALL` | kontrola manifestu obrazu przed wysłaniem aktualizacji |
| osierocony certyfikat `1002` | klucz zniknął razem ze starym dyskiem | odwołanie w CA (realny przypadek rewokacji) |

## Do zrobienia

- Automatyczne odnawianie: serwer podpisujący (EST/ACME, np. step-ca) zamiast ręcznego przenoszenia CSR.
- PIN tokena zapieczętowany w TPM pod polityką PCR (użycie klucza tylko w zaufanym stanie startu) zamiast pliku.
- Dwupoziomowe CA (offline root), klucz CA w HSM.
- Certyfikacja klucza przez TPM (`TPM2_Certify`) jako zdalny dowód pochodzenia klucza.
- Zgłoszenie łatki mosquitto do projektu.
