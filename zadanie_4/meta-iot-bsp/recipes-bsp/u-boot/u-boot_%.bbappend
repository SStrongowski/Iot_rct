FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append:qemuarm64-secureboot = " file://bootcount.cfg"
