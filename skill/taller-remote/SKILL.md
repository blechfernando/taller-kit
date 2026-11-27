---
name: taller-remote
description: >-
  Remote workshop PC administration via SSH, SCP, and VNC GUI tunneling using the `taller` CLI.
  Use whenever the user asks to inspect, repair, install software, transfer files, fix printers/drivers,
  or control another computer in the house, workshop, store, or over the internet (Tailscale),
  or mentions a newly connected PC ready for remote access.
---

# Taller Remote — Operacion Multi-PC para Agentes IA

Esta PC controladora tiene instalado el comando global `taller` (en `%USERPROFILE%\.taller`) y claves SSH ya autorizadas por el kit del taller. **No es necesario instalar ningun agente de IA en la PC destino.**

Todas las PCs conectadas con `1-CONECTAR.bat`, `web/conectar.ps1` o `linux-conectar.sh` quedan configuradas de forma **fija y completa** (sobreviven reinicios, cortes de luz y traslados entre casa/taller/local/deposito):
- OpenSSH (`TallerSSH` puerto `22`) en `C:\ProgramData\Taller` (o `/etc/taller` en Linux)
- TightVNC Server en `127.0.0.1:5900` (solo accesible por tunel SSH)
- Tailscale instalado en Win10/11 x64 para acceso por Internet (`tag:remoto`)

## Flujo rapido

1. **Descubrir la PC destino:**
   ```powershell
   taller scan
   ```
   Escanea la subred local (puertos `22` y `2222`) + peers online en Tailscale.
   - `taller list`: muestra PCs fijas (`hosts.json`), nodos Tailscale y ultimo escaneo.
   - El alias especial `ultimo` apunta automaticamente a la PC no-controladora mas reciente detectada en `taller scan`.

2. **Ejecutar comandos y scripts:**
   ```powershell
   taller ssh <destino> "hostname & whoami"
   taller ssh ultimo "powershell -NoProfile -Command Get-Printer"
   ```
   `<destino>` acepta: alias de `hosts.json` (`lech`, `restobar`, `mama`), `ultimo`, hostname, nombre Tailscale o IP directa.

3. **Transferir archivos / instaladores:**
   ```powershell
   taller scp C:\ruta\local\archivo.exe ultimo:C:\Temp\
   taller scp lech:D:\drivers\clip.zip .\clip.zip
   ```

4. **Activar Internet (Tailscale) remotamente si aun quedo pendiente:**
   Si la PC se conecto por web sin ingresar Auth Key en ese momento:
   ```powershell
   taller tailscale <destino> [alias]
   ```
   Usa `%USERPROFILE%\.taller\tailscale.key` (o `--key tskey-auth-...`) para unir la PC al Tailnet con `tag:remoto` sin ir hasta la otra maquina.

5. **Control grafico de ventanas (cuando un instalador o programa no es CLI):**
   TightVNC escucha **solo en `127.0.0.1:5900`**. `taller` abre y cierra un tunel SSH cifrado automaticamente:
   ```powershell
   taller screen <destino>
   ```
   - Imprime la ruta absoluta del PNG generado (`SCREEN_OK WxH C:\...\screen.png`).
   - Lee ese PNG con `read_file` para ver la pantalla antes de interactuar.
   - Acciones disponibles:
     - `taller click <destino> <x> <y>` (opcional `--right` o `--double`)
     - `taller drag <destino> <x1> <y1> <x2> <y2>`
     - `taller type <destino> "<texto>"`
     - `taller key <destino> <tecla>` (`Enter`, `Tab`, `Esc`, `Alt+F4`, `Ctrl+Shift+Esc`, `Win+R`)
   - Para que el usuario humano vea/opere la pantalla en vivo: `taller vnc <destino>`.

6. **Limpieza completa al entregar a cliente o vender una PC:**
   Solo cuando el usuario indique que la PC ya se entrega al cliente o se prepara para la venta (y **nunca** sobre `casa-a`, `lech` ni PCs propias):
   ```powershell
   taller clean <destino>
   ```
   Desinstala `TallerSSH`, TightVNC (si lo instalo el kit), ejecuta `tailscale logout` + desinstala Tailscale (si lo instalo el kit), limpia firewall y borra `C:\ProgramData\Taller`.

## Casos frecuentes de soporte

- **Impresoras termicas / de red (ej. resto bar):** inspeccionar puertos con `Get-Printer`, `Get-PrinterPort` y reiniciar `Spooler` por `taller ssh`.
- **PCs que se mueven de lugar / deposito:** registrar por IP Tailscale con `taller add-host <alias> <ip_tailscale> <user> 22` (si tambien esta en LAN, `hosts.json` puede guardar `host` LAN + `tailscale_ip` y `taller` usa LAN si responde o Tailscale automaticamente).
- **Windows 7 / escaneres legacy:** usan OpenSSH 8.1 en puerto 22; usar comandos PowerShell 2.0 o `cmd.exe` y `taller screen` / `taller click` para instaladores graficos.
