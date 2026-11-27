#!/usr/bin/env python3
"""
lan_server.py - Servidor HTTP simple en LAN para Taller Kit
Sirve web/ en /, pendrive/TALLER_KIT/bin/ en /bin/ y scripts/ en /scripts/
"""

import argparse
import functools
import http.server
import os
import posixpath
import socketserver
import urllib.parse


class TallerHTTPHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, web_dir: str, bin_dir: str, scripts_dir: str, linux_sh: str, **kwargs):
        self.web_dir = web_dir
        self.bin_dir = bin_dir
        self.scripts_dir = scripts_dir
        self.linux_sh = linux_sh
        super().__init__(*args, directory=web_dir, **kwargs)

    def translate_path(self, path: str) -> str:
        clean = urllib.parse.urlsplit(path).path
        clean = posixpath.normpath(urllib.parse.unquote(clean))
        parts = [p for p in clean.split("/") if p and p not in (".", "..")]

        if parts and parts[0] == "bin":
            return os.path.join(self.bin_dir, *parts[1:])
        if parts and parts[0] == "scripts":
            if len(parts) == 2 and parts[1] == "linux-conectar.sh":
                return self.linux_sh
            return os.path.join(self.scripts_dir, *parts[1:])
        return os.path.join(self.web_dir, *parts)


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def main() -> int:
    parser = argparse.ArgumentParser(description="Servidor LAN Taller Kit")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--repo", required=True)
    args = parser.parse_args()

    repo = os.path.abspath(args.repo)
    web_dir = os.path.join(repo, "web")
    bin_dir = os.path.join(repo, "pendrive", "TALLER_KIT", "bin")
    scripts_dir = os.path.join(repo, "pendrive", "TALLER_KIT", "scripts")
    linux_sh = os.path.join(repo, "pendrive", "TALLER_KIT", "linux-conectar.sh")

    handler = functools.partial(
        TallerHTTPHandler,
        web_dir=web_dir,
        bin_dir=bin_dir,
        scripts_dir=scripts_dir,
        linux_sh=linux_sh,
    )
    server = ThreadingHTTPServer(("0.0.0.0", args.port), handler)
    print(f"[TALLER SERVE] Escuchando en 0.0.0.0:{args.port} (Ctrl+C para detener)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[TALLER SERVE] Detenido.")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
