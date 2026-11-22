#!/bin/sh
# swu-sign.sh <katalog_kluczy> <sw-description> <sw-description.sig>
# Podpis CMS manifestu kluczem z tokena PKCS#11 (SoftHSM), przez engine OpenSSL.
# Klucz prywatny nigdy nie istnieje jako plik; w katalogu są tylko certyfikat,
# konfiguracja OpenSSL i PIN (poza repozytorium).
set -eu

DIR="${1:?katalog kluczy (IOT_SIGNING_DIR)}"
IN="${2:?plik sw-description}"
OUT="${3:?plik podpisu}"

export SOFTHSM2_CONF="$DIR/softhsm2.conf"
export OPENSSL_CONF="$DIR/openssl-pkcs11.cnf"
PIN=$(cat "$DIR/pin")
URI="pkcs11:token=swupdate-signing;object=swu-signing;type=private?pin-value=$PIN"

# OpenSSL hosta (z engine PKCS#11), a nie openssl-native z Yocto
/usr/bin/openssl cms -sign -engine pkcs11 -keyform engine \
    -binary -nosmimecap -outform DER \
    -in "$IN" -out "$OUT" \
    -signer "$DIR/swupdate-signing.crt" -inkey "$URI"
