# Taller Kit — Control Remoto Multi-PC + Pendrive Multi-ISO

Sistema unificado para administrar, reparar, transferir archivos y operar pantallas graficas en **cualquier PC del taller, casa, negocio o por Internet**, directamente desde tus controladores (`DESKTOP-LSDMKT9` y `lech`) o mediante agentes de IA, **sin instalar agentes de IA en las maquinas destino**.

---

## Escenarios cubiertos de punta a punta

| Situacion | Que haces en la PC destino | Que haces desde tu PC / Agente |
|---|---|---|
| **PC de cliente en el taller (temporal)** | Enchufar pendrive -> doble clic `TALLER_KIT\1-CONECTAR-CLIENTE.bat` (o web/LAN) | *"Ya conecte la compu nueva, revisala"* -> `taller scan`, `taller ssh ultimo`, `taller screen ultimo`, al final `taller clean ultimo` |
| **PC propia fija (local, camaras, taller)** | Doble clic `TALLER_KIT\3-INSTALAR-PROPIA.bat` | `taller add-host negocio <ip> <user>` -> acceso permanente por puerto `22` |
| **PC fuera de tu red (Resto bar, Mama)** | `4-REMOTO-INTERNET.bat` (o `irm .../conectar.ps1 \| iex` opcion `3`) | `taller add-host restobar <ip_tailscale> <user>` -> `taller ssh`, `taller scp`, `taller vnc` por Internet |
| **Win 7 / Escaner viejo sin red o soporte puntual** | `1-CONECTAR-CLIENTE.bat` (usa OpenSSH 8.1) o `5-PANTALLA-RAPIDA-RUSTDESK.bat` | `taller ssh` / `taller screen` / `taller click` o RustDesk |
| **Formatear PC desde cero (Multi-ISO)** | Booteo con pendrive **Ventoy** -> elegir ISO + plantilla Taller | Al primer inicio ya queda con SSH + TightVNC localhost listo |
| **Sin pendrive a mano en el taller** | En PC principal: `taller serve` -> pegar el 1-liner LAN en la otra PC | Baja OpenSSH/VNC directo por Wi-Fi/LAN en segundos |

---

## Estructura del proyecto

- [keys/controllers.pub](file:///D:/viernes/keys/controllers.pub) — Fuente unica de claves publicas autorizadas (cero secretos privados).
- [pendrive/TALLER_KIT/](file:///D:/viernes/pendrive/TALLER_KIT/1-CONECTAR-CLIENTE.bat) — Kit 100% offline para copiar al pendrive (`.bat` 1 al 5 + `linux-conectar.sh` + binarios firmados para Win7/Win10/Win11 x86/x64).
- [pendrive/ventoy/](file:///D:/viernes/pendrive/ventoy/ventoy.json) — Configuracion Multi-ISO Ventoy + plantillas desatendidas seguras (`win10-11-taller.xml`, `win7-taller.xml`, `win7-x86-taller.xml`, `ubuntu-autoinstall`).
- [web/](file:///D:/viernes/web/conectar.ps1) — Bootstrap por nube/LAN (`conectar.ps1`, `limpiar.ps1`, `linux.sh`).
- [controller/](file:///D:/viernes/controller/taller.ps1) — CLI `taller` + cliente VNC puro Python (`taller_gui.py`) + servidor LAN (`lan_server.py`) + visor TightVNC portable.
- [skill/taller-remote/SKILL.md](file:///D:/viernes/skill/taller-remote/SKILL.md) — Skill global para que cualquier agente sepa usar `taller` automaticamente.

---

## Guias detalladas

1. [Armado y uso del Pendrive Multi-ISO (Ventoy)](file:///D:/viernes/docs/GUIA-VENTOY-MULTI-ISO.md)
2. [Acceso remoto por Internet con Tailscale (Resto bar / Familia)](file:///D:/viernes/docs/GUIA-TAILSCALE-REMOTO.md)
3. [Como sumar una nueva PC controladora](file:///D:/viernes/docs/GUIA-NUEVO-CONTROLADOR.md)

---

## Referencia rapida del comando `taller`

```powershell
taller scan                     # Busca PCs nuevas (puerto 2222 y 22) + Tailscale
taller list                     # Muestra PCs fijas, Tailscale y ultimo scan
taller ssh <destino> [cmd]      # Consola o comando remoto
taller scp <orig> <dest>        # Copiar archivos (ej: app.exe ultimo:C:\Temp\)
taller screen <destino>         # Captura pantalla remota en PNG (via tunel SSH+VNC)
taller click <destino> x y      # Clic (--right / --double)
taller type <destino> "texto"   # Escribir texto
taller key <destino> Alt+F4     # Atajos de teclado
taller vnc <destino>            # Abre ventana TightVNC interactiva por tunel SSH
taller clean <destino>          # Borra acceso temporal de PC cliente al entregarla
taller serve                    # Sirve web/ + bin/ en tu LAN sin necesitar pendrive
taller sync-keys --push         # Sincroniza controllers.pub en pendrive, web y PCs fijas
```
