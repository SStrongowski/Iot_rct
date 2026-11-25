#!/usr/bin/env python3
"""rest_server.py — przykładowe REST API z wzajemnym uwierzytelnianiem TLS (zadanie 7).

GET  /whoami      -> kim jest klient według certyfikatu (CN, seria, ważność)
POST /telemetry   -> przyjęcie pomiaru JSON od urządzenia

Uruchomienie: python3 rest_server.py   (port 8443)
Lista odwołań (CRL) jest wczytywana przy starcie: po odwołaniu certyfikatu zrestartuj serwer.
"""
import json
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

CA_DIR = Path.home() / "iot-ca"
CA_CERT = CA_DIR / "ca.crt"
CRL = CA_DIR / "crl.pem"
CERT = CA_DIR / "servers" / "rest.crt"
KEY = CA_DIR / "servers" / "rest.key"


def client_identity(cert):
    """CN i seria z certyfikatu klienta (już zweryfikowanego przez TLS)."""
    subject = {k: v for rdn in cert["subject"] for (k, v) in rdn}
    return {
        "device": subject.get("commonName"),
        "serial": cert.get("serialNumber"),
        "valid_until": cert.get("notAfter"),
    }


class Handler(BaseHTTPRequestHandler):
    def _reply(self, code, body):
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        ident = client_identity(self.connection.getpeercert())
        if self.path == "/whoami":
            self._reply(200, ident)
        else:
            self._reply(404, {"error": "nieznana ścieżka"})

    def do_POST(self):
        ident = client_identity(self.connection.getpeercert())
        if self.path != "/telemetry":
            self._reply(404, {"error": "nieznana ścieżka"})
            return
        length = int(self.headers.get("Content-Length", 0))
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self._reply(400, {"error": "niepoprawny JSON"})
            return
        print(f"telemetria od {ident['device']} (seria {ident['serial']}): {payload}")
        self._reply(201, {"accepted": True, "from": ident["device"]})


def main():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(CERT, KEY)
    ctx.verify_mode = ssl.CERT_REQUIRED                 # klient musi mieć certyfikat
    ctx.load_verify_locations(CA_CERT)                  # ...podpisany przez nasze CA
    ctx.load_verify_locations(CRL)                      # ...i nieodwołany
    ctx.verify_flags |= ssl.VERIFY_CRL_CHECK_LEAF

    server = ThreadingHTTPServer(("0.0.0.0", 8443), Handler)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    print("REST API (mTLS) na :8443")
    server.serve_forever()


if __name__ == "__main__":
    main()
