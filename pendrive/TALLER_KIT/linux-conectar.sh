#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUB_KEYS_FILE="${SCRIPT_DIR}/config/controllers.pub"
STATE_DIR="/etc/taller"

PORT=22
ENABLE_VNC=0
NO_TAILSCALE=0
TAILSCALE_KEY=""
TAILSCALE_NAME=""
TAILSCALE_TAGS="tag:remoto"
DO_CLEAN=0

usage() {
  cat <<EOF
Uso: sudo $0 [opciones]
  (sin opciones)           Instalacion fija completa (SSH puerto 22 + Tailscale)
  --port <n>               Puerto SSH personalizado (default 22)
  --vnc                    Habilita x11vnc en 127.0.0.1:5900 (si hay sesion X11)
  --tailscale-key <key>    Auth key de Tailscale (tskey-auth-...)
  --name <alias>           Hostname en Tailscale
  --no-tailscale           No instala Tailscale
  --limpiar                Limpia por completo todo lo instalado por Taller Kit
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --vnc) ENABLE_VNC=1; shift ;;
    --no-tailscale) NO_TAILSCALE=1; shift ;;
    --tailscale-key) TAILSCALE_KEY="$2"; shift 2 ;;
    --name) TAILSCALE_NAME="$2"; shift 2 ;;
    --limpiar) DO_CLEAN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Opcion desconocida: $1"; usage; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Ejecuta con sudo."
  exit 1
fi

TARGET_USER="${SUDO_USER:-$(whoami)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || echo "/root")"
HOST_NAME="$(hostname -s 2>/dev/null || hostname)"

if [[ $DO_CLEAN -eq 1 ]]; then
  echo "[TALLER] Limpiando instalacion del taller..."
  if [[ -f "${STATE_DIR}/installed_tailscale.flag" ]] && command -v tailscale >/dev/null 2>&1; then
    tailscale logout >/dev/null 2>&1 || true
    systemctl disable --now tailscaled >/dev/null 2>&1 || true
  fi
  if [[ -f "${STATE_DIR}/x11vnc.pid" ]]; then
    kill "$(cat "${STATE_DIR}/x11vnc.pid")" 2>/dev/null || true
  fi
  if [[ -f "${STATE_DIR}/added_keys.flag" && -f "${TARGET_HOME}/.ssh/authorized_keys" ]]; then
    grep -Fxv -f "${STATE_DIR}/added_keys.flag" "${TARGET_HOME}/.ssh/authorized_keys" > "${TARGET_HOME}/.ssh/authorized_keys.tmp" || true
    mv "${TARGET_HOME}/.ssh/authorized_keys.tmp" "${TARGET_HOME}/.ssh/authorized_keys"
    chown "${TARGET_USER}:" "${TARGET_HOME}/.ssh/authorized_keys" 2>/dev/null || true
  fi
  rm -f /etc/ssh/sshd_config.d/99-taller.conf
  if command -v sshd >/dev/null 2>&1 && sshd -t >/dev/null 2>&1; then
    systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true
  fi
  rm -rf "${STATE_DIR}" /opt/taller-tmp
  echo "[OK] Linux limpio."
  exit 0
fi

if [[ ! -f "$PUB_KEYS_FILE" ]]; then
  echo "[ERROR] No se encontro $PUB_KEYS_FILE"
  exit 1
fi

if [[ -z "$TAILSCALE_KEY" ]]; then
  for kf in "${SCRIPT_DIR}/config/tailscale-auth.txt" "${SCRIPT_DIR}/tailscale-auth.txt"; do
    if [[ -f "$kf" ]]; then
      TAILSCALE_KEY="$(grep -vE '^\s*(#|$)' "$kf" | head -n1 | tr -d '\r' | xargs || true)"
      [[ -n "$TAILSCALE_KEY" ]] && break
    fi
  done
fi

install_pkg() {
  local pkg="$1"
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q "$pkg"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q "$pkg"
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm "$pkg"
  else
    echo "[ERROR] Gestor de paquetes no soportado; instala '$pkg' manualmente."
    return 1
  fi
}

if ! command -v sshd >/dev/null 2>&1; then
  echo "[TALLER] Instalando openssh-server..."
  install_pkg openssh-server
fi

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

merge_keys() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  touch "$dest"
  while IFS= read -r line; do
    line="$(echo "$line" | tr -d '\r')"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if ! grep -Fqx "$line" "$dest"; then
      echo "$line" >> "$dest"
      echo "$line" >> "${STATE_DIR}/added_keys.flag"
    fi
  done < "$PUB_KEYS_FILE"
}

VNC_FLAG="VNC=0"
if [[ $ENABLE_VNC -eq 1 ]]; then
  if ! command -v x11vnc >/dev/null 2>&1; then
    install_pkg x11vnc || true
  fi
  if command -v x11vnc >/dev/null 2>&1; then
    VNC_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8 || true)"
    echo -n "$VNC_PASS" > "${STATE_DIR}/vnc.pass"
    chmod 600 "${STATE_DIR}/vnc.pass"
    x11vnc -storepasswd "$VNC_PASS" "${STATE_DIR}/vnc.rfbpass" >/dev/null 2>&1 || true
    if [[ -n "${DISPLAY:-}" ]] || ls /tmp/.X11-unix/X* >/dev/null 2>&1; then
      DISP="${DISPLAY:-:0}"
      nohup x11vnc -display "$DISP" -localhost -rfbport 5900 -rfbauth "${STATE_DIR}/vnc.rfbpass" -forever -shared -bg -pidfile "${STATE_DIR}/x11vnc.pid" -o "${STATE_DIR}/x11vnc.log" >/dev/null 2>&1 || true
      VNC_FLAG="VNC=1"
    fi
  fi
fi

merge_keys "${TARGET_HOME}/.ssh/authorized_keys"
chown -R "${TARGET_USER}:" "${TARGET_HOME}/.ssh"
chmod 700 "${TARGET_HOME}/.ssh"
chmod 600 "${TARGET_HOME}/.ssh/authorized_keys"

META_B64="$(printf '%s|%s|Linux|%s' "$HOST_NAME" "$TARGET_USER" "$VNC_FLAG" | base64 -w0 2>/dev/null || printf '%s|%s|Linux|%s' "$HOST_NAME" "$TARGET_USER" "$VNC_FLAG" | base64 | tr -d '\n')"
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-taller.conf <<EOF
Port ${PORT}
PubkeyAuthentication yes
PasswordAuthentication no
AllowTcpForwarding yes
VersionAddendum TALLER:${META_B64}
EOF
sshd -t
systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || service ssh restart

if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi "Status: active"; then
  ufw allow "${PORT}/tcp" >/dev/null || true
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --add-port="${PORT}/tcp" >/dev/null || true
  firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null || true
fi

TS_IP=""
if [[ $NO_TAILSCALE -eq 0 ]]; then
  if ! command -v tailscale >/dev/null 2>&1; then
    echo "[TALLER] Instalando Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
    touch "${STATE_DIR}/installed_tailscale.flag"
  fi
  if [[ -n "$TAILSCALE_KEY" ]]; then
    TS_ARGS=(up --authkey="$TAILSCALE_KEY" --advertise-tags="$TAILSCALE_TAGS")
    [[ -n "$TAILSCALE_NAME" ]] && TS_ARGS+=(--hostname="$TAILSCALE_NAME")
    tailscale "${TS_ARGS[@]}"
    TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  fi
fi

LAN_IPS="$(hostname -I 2>/dev/null || true)"
echo "============================================================"
echo "  LISTO! LINUX CONECTADO (FIJO LAN + INTERNET)"
echo "============================================================"
echo "  Equipo       : ${HOST_NAME} (Linux)"
echo "  Usuario SSH  : ${TARGET_USER}"
echo "  IP(s) LAN    : ${LAN_IPS}"
[[ -n "$TS_IP" ]] && echo "  IP Tailscale : ${TS_IP}"
echo "  Puerto SSH   : ${PORT}"
echo "============================================================"
