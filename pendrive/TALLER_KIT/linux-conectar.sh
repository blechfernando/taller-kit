#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUB_KEYS_FILE="${SCRIPT_DIR}/config/controllers.pub"

MODE="cliente"
PORT=""
ENABLE_VNC=0
TAILSCALE_KEY=""
TAILSCALE_NAME=""
TAILSCALE_TAGS="tag:remoto"
DO_CLEAN=0

usage() {
  cat <<EOF
Uso: sudo $0 [--cliente | --permanente | --remoto] [opciones]
  --cliente                Modo temporal puerto 2222 en /opt/taller-tmp (default)
  --permanente             Modo fijo puerto 22 en /etc/ssh
  --remoto                 Modo fijo + Tailscale (requiere --tailscale-key)
  --port <n>               Puerto SSH personalizado
  --vnc                    Habilita x11vnc en 127.0.0.1:5900 (si hay sesion X11)
  --tailscale-key <key>    Auth key de Tailscale (tskey-auth-...)
  --name <alias>           Hostname en Tailscale
  --limpiar                Elimina por completo el acceso temporal (/opt/taller-tmp)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cliente) MODE="cliente"; shift ;;
    --permanente) MODE="permanente"; shift ;;
    --remoto) MODE="remoto"; shift ;;
    --port) PORT="$2"; shift 2 ;;
    --vnc) ENABLE_VNC=1; shift ;;
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
  echo "[TALLER] Limpiando acceso temporal..."
  if [[ -f /opt/taller-tmp/sshd.pid ]]; then
    kill "$(cat /opt/taller-tmp/sshd.pid)" 2>/dev/null || true
  fi
  if [[ -f /opt/taller-tmp/x11vnc.pid ]]; then
    kill "$(cat /opt/taller-tmp/x11vnc.pid)" 2>/dev/null || true
  fi
  if command -v ufw >/dev/null 2>&1; then
    ufw delete allow 2222/tcp >/dev/null 2>&1 || true
  fi
  rm -rf /opt/taller-tmp
  echo "[OK] Acceso temporal eliminado."
  exit 0
fi

if [[ -z "$PORT" ]]; then
  if [[ "$MODE" == "cliente" ]]; then PORT=2222; else PORT=22; fi
fi

if [[ ! -f "$PUB_KEYS_FILE" ]]; then
  echo "[ERROR] No se encontro $PUB_KEYS_FILE"
  exit 1
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

merge_keys() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  touch "$dest"
  while IFS= read -r line; do
    line="$(echo "$line" | tr -d '\r')"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if ! grep -Fqx "$line" "$dest"; then
      echo "$line" >> "$dest"
    fi
  done < "$PUB_KEYS_FILE"
}

VNC_FLAG="VNC=0"
VNC_DIR="/opt/taller-tmp"
[[ "$MODE" != "cliente" ]] && VNC_DIR="/etc/taller"
mkdir -p "$VNC_DIR"
chmod 700 "$VNC_DIR"

if [[ $ENABLE_VNC -eq 1 ]]; then
  if ! command -v x11vnc >/dev/null 2>&1; then
    install_pkg x11vnc || true
  fi
  if command -v x11vnc >/dev/null 2>&1; then
    VNC_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8 || true)"
    echo -n "$VNC_PASS" > "${VNC_DIR}/vnc.pass"
    chmod 600 "${VNC_DIR}/vnc.pass"
    x11vnc -storepasswd "$VNC_PASS" "${VNC_DIR}/vnc.rfbpass" >/dev/null 2>&1 || true
    if [[ -n "${DISPLAY:-}" ]] || ls /tmp/.X11-unix/X* >/dev/null 2>&1; then
      DISP="${DISPLAY:-:0}"
      nohup x11vnc -display "$DISP" -localhost -rfbport 5900 -rfbauth "${VNC_DIR}/vnc.rfbpass" -forever -shared -bg -o "${VNC_DIR}/x11vnc.log" >/dev/null 2>&1 || true
      VNC_FLAG="VNC=1"
    fi
  fi
fi

META_B64="$(printf '%s|%s|Linux|%s' "$HOST_NAME" "$TARGET_USER" "$VNC_FLAG" | base64 -w0 2>/dev/null || printf '%s|%s|Linux|%s' "$HOST_NAME" "$TARGET_USER" "$VNC_FLAG" | base64 | tr -d '\n')"

if [[ "$MODE" == "cliente" ]]; then
  TMP_DIR="/opt/taller-tmp"
  mkdir -p "$TMP_DIR"
  chmod 755 "$TMP_DIR"
  AUTH_FILE="${TMP_DIR}/authorized_keys"
  merge_keys "$AUTH_FILE"
  chmod 644 "$AUTH_FILE"

  if [[ ! -f "${TMP_DIR}/ssh_host_ed25519_key" ]]; then
    ssh-keygen -t ed25519 -N "" -f "${TMP_DIR}/ssh_host_ed25519_key" -q
  fi
  chmod 600 "${TMP_DIR}/ssh_host_ed25519_key"

  SFTP_BIN="$(command -v sftp-server || find /usr -name sftp-server 2>/dev/null | head -n1 || echo "/usr/lib/openssh/sftp-server")"
  cat > "${TMP_DIR}/sshd_config" <<EOF
Port ${PORT}
ListenAddress 0.0.0.0
HostKey ${TMP_DIR}/ssh_host_ed25519_key
PidFile ${TMP_DIR}/sshd.pid
AuthorizedKeysFile ${AUTH_FILE}
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
StrictModes no
AllowTcpForwarding yes
GatewayPorts no
VersionAddendum TALLER:${META_B64}
Subsystem sftp ${SFTP_BIN}
EOF

  if [[ -f "${TMP_DIR}/sshd.pid" ]]; then
    kill "$(cat "${TMP_DIR}/sshd.pid")" 2>/dev/null || true
    sleep 0.5
  fi
  sshd -t -f "${TMP_DIR}/sshd_config"
  "$(command -v sshd)" -f "${TMP_DIR}/sshd_config"
else
  merge_keys "${TARGET_HOME}/.ssh/authorized_keys"
  chown -R "${TARGET_USER}:" "${TARGET_HOME}/.ssh"
  chmod 700 "${TARGET_HOME}/.ssh"
  chmod 600 "${TARGET_HOME}/.ssh/authorized_keys"

  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-taller.conf <<EOF
PubkeyAuthentication yes
AllowTcpForwarding yes
VersionAddendum TALLER:${META_B64}
EOF
  sshd -t
  systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || service ssh restart
fi

if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi "Status: active"; then
  ufw allow "${PORT}/tcp" >/dev/null || true
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --add-port="${PORT}/tcp" >/dev/null || true
  [[ "$MODE" != "cliente" ]] && firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null || true
fi

TS_IP=""
if [[ "$MODE" == "remoto" || -n "$TAILSCALE_KEY" ]]; then
  if ! command -v tailscale >/dev/null 2>&1; then
    echo "[TALLER] Instalando Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
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
echo "  LISTO! LINUX PREPARADO PARA CONTROL REMOTO DEL TALLER"
echo "============================================================"
echo "  Equipo       : ${HOST_NAME} (Linux)"
echo "  Usuario SSH  : ${TARGET_USER}"
echo "  IP(s) LAN    : ${LAN_IPS}"
[[ -n "$TS_IP" ]] && echo "  IP Tailscale : ${TS_IP}"
echo "  Puerto SSH   : ${PORT} (Modo: ${MODE})"
echo "============================================================"
