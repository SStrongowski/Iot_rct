#!/bin/sh
# ca.sh — mini-CA (OpenSSL) dla tożsamości urządzeń i usług (zadanie 7)
#
#   ca.sh init                          utworzenie CA (klucz EC P-256, certyfikat na 10 lat, pusta CRL)
#   ca.sh server <nazwa>                klucz + certyfikat usługi (mosquitto, REST), SAN: 10.0.2.2, localhost
#   ca.sh sign <plik.csr> <wynik.crt>   podpis CSR urządzenia (clientAuth, 365 dni)
#   ca.sh revoke <plik.crt>             odwołanie certyfikatu + nowa CRL
#   ca.sh crl                           wygenerowanie CRL od nowa
#   ca.sh list                          rejestr wydanych certyfikatów (V = ważny, R = odwołany)
#
# Dane CA (z kluczem prywatnym) w IOT_CA_DIR, domyślnie ~/iot-ca — poza repozytorium.
set -eu

export IOT_CA_DIR="${IOT_CA_DIR:-$HOME/iot-ca}"
export IOT_SAN="${IOT_SAN:-IP:10.0.2.2,IP:127.0.0.1,DNS:localhost}"
CNF="$(dirname "$(readlink -f "$0")")/openssl-ca.cnf"
CA=$IOT_CA_DIR

ossl_ca() { openssl ca -config "$CNF" -batch "$@"; }

case "${1:-}" in
init)
    [ -e "$CA/ca.crt" ] && { echo "CA już istnieje w $CA" >&2; exit 1; }
    mkdir -p "$CA/private" "$CA/newcerts" "$CA/servers"
    chmod 700 "$CA/private"
    : > "$CA/index.txt"
    echo 1000 > "$CA/serial"
    echo 1000 > "$CA/crlnumber"
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$CA/private/ca.key"
    chmod 600 "$CA/private/ca.key"
    openssl req -config "$CNF" -new -x509 -key "$CA/private/ca.key" -days 3650 \
        -extensions v3_ca -out "$CA/ca.crt"
    ossl_ca -gencrl -out "$CA/crl.pem"
    openssl x509 -in "$CA/ca.crt" -noout -subject -enddate
    ;;
server)
    n="${2:?nazwa usługi}"
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$CA/servers/$n.key"
    chmod 600 "$CA/servers/$n.key"
    openssl req -new -key "$CA/servers/$n.key" -subj "/O=Iot_rct/CN=$n" -out "$CA/servers/$n.csr"
    ossl_ca -extensions server_ext -days 365 -in "$CA/servers/$n.csr" -out "$CA/servers/$n.crt"
    openssl x509 -in "$CA/servers/$n.crt" -noout -subject -ext subjectAltName,extendedKeyUsage
    ;;
sign)
    csr="${2:?plik CSR}"; out="${3:?plik wynikowy}"
    openssl req -in "$csr" -noout -verify -subject      # podpis CSR = dowód posiadania klucza
    ossl_ca -extensions device_ext -days 365 -in "$csr" -out "$out"
    openssl x509 -in "$out" -noout -subject -serial -enddate -ext extendedKeyUsage
    ;;
revoke)
    crt="${2:?plik certyfikatu}"
    ossl_ca -revoke "$crt"
    ossl_ca -gencrl -out "$CA/crl.pem"
    openssl crl -in "$CA/crl.pem" -noout -text | grep -E 'Serial Number|Revocation Date'
    ;;
crl)
    ossl_ca -gencrl -out "$CA/crl.pem"
    ;;
list)
    cat "$CA/index.txt"
    ;;
*)
    sed -n '2,10p' "$0"; exit 2
    ;;
esac
