FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append:qemuarm64-secureboot = " file://fw_env.config"

do_install:append:qemuarm64-secureboot() {
    install -d ${D}${sysconfdir}
    install -m 0644 ${UNPACKDIR}/fw_env.config ${D}${sysconfdir}/fw_env.config
}
