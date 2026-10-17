Program zadań – IoT / Embedded Security


Zasady ogólne:
    - Na start można (i warto) używać emulatora QEMU – przed zakupem sprzętu oraz wszędzie tam, gdzie wsparcie sprzętowe jest niepełne.

    - Całość prowadzona w repozytorium Git: konfiguracje, skrypty, warstwy Yocto. Każdy etap kończy się krótką notatką projektową w repo (podjęte decyzje, rozważone alternatywy, mini threat-model w 3 zdaniach). Etap bez notatki = etap niezakończony.
    - Każde zadanie ma kryteria ukończenia – odhaczamy dopiero, gdy wszystkie są spełnione i da się je zademonstrować na żywo.

1. Gentoo Linux na maszynie wirtualnej poziom: fundament
Instalacja Gentoo na VM (styl dowolny: systemd lub OpenRC), własna konfiguracja kernela.
Kryteria ukończenia:
System bootuje się z własnoręcznie skompilowanego kernela; świadomy wybór profilu i USE flags (umie uzasadnić).
Notatka: czym różni się podejście Gentoo (source-based) od dystrybucji binarnych i co z tego wynika dla embedded.

2. Gentoo Linux na Raspberry Pi poziom: fundament
Instalacja Gentoo na fizycznym ARM64. Sprzęt polecany: Raspberry Pi 5 (2 GB RAM, WiFi 2.4/5 GHz, PCIe, Ethernet 1 Gb/s, 4× USB).
Kryteria ukończenia:
System bootuje na płytce; cross-kompilacja (crossdev lub binhost) zamiast kompilowania wszystkiego na RPi – umie wyjaśnić dlaczego.
Dostęp po SSH, konto nie-root, podstawowy porządek w systemie.

3. Obsługa wszystkich peryferiów poziom: fundament
WiFi (2.4 i 5 GHz), Ethernet, USB, PCIe, GPIO/I2C/SPI, audio/HDMI – co płytka ma, to działa.
Kryteria ukończenia:
Lista peryferiów z dowodem działania każdego (log/test); dla min. dwóch – rozumie, przez jaki sterownik i wpis w device tree działają.
Jedno peryferium celowo wyłączone i włączone z powrotem przez zmianę DT/konfiguracji kernela (nie przez raspi-config).

4. Yocto + secure boot (TPM) + TEE + PKCS#11 poziom: rdzeń
Własny obraz Yocto na RPi; secure boot w oparciu o TPM (measured boot); TEE (OP-TEE); PKCS#11 zarówno na TPM, jak i na TEE. Sprzęt polecany: LetsTrust TPM – Infineon Optiga SLB 9670 (SPI).
Kryteria ukończenia:
Własna warstwa Yocto (meta-*), czysty podział BSP / distro / aplikacje; obraz buduje się powtarzalnie i odpala też pod QEMU ARM64.
Measured boot: kolejne etapy rozszerzają PCR-y; umie pokazać i objaśnić mapę PCR 0–7.
tpm2-tools + tpm2-pkcs11 działają: klucz wygenerowany w TPM, podpis przez interfejs PKCS#11.
OP-TEE uruchomione (RPi lub – jeśli port dla RPi5 niedojrzały – QEMU ARMv8); xtest przechodzi; PKCS#11 TA spięte z libp11/OpenSC.
Notatka: TPM vs TEE – co chroni przed czym, kiedy który wybrać.

5. Szyfrowanie storage: LUKS + TPM sealing poziom: rdzeń
dm-crypt/LUKS na partycji danych; klucz zapieczętowany w TPM pod polityką PCR; obsługa aktualizacji.
Kryteria ukończenia:
Partycja otwiera się automatycznie wyłącznie przy nienaruszonym łańcuchu bootowania; po manipulacji (zmiana kernela/konfiguracji) – odmowa + ścieżka recovery z passphrase.
Scenariusz aktualizacji: nowe wartości PCR → re-sealing wpisany w procedurę update'u (rozwiązany samodzielnie, opisany w notatce).
