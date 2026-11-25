SUMMARY = "Tożsamość urządzenia: klucz w TPM (tpm2-pkcs11), CSR, certyfikat; CA floty"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://iot-identity \
           file://ca.crt"
S = "${UNPACKDIR}"

inherit allarch

RDEPENDS:${PN} = "tpm2-pkcs11 tpm2-pkcs11-tools libp11 openssl-bin"

do_install() {
    install -d ${D}${bindir} ${D}${sysconfdir}/iot-identity
    install -m 0755 ${UNPACKDIR}/iot-identity ${D}${bindir}/
    install -m 0644 ${UNPACKDIR}/ca.crt ${D}${sysconfdir}/iot-identity/
}
FILES:${PN} = "${bindir}/iot-identity ${sysconfdir}/iot-identity/ca.crt"