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

## Flujo rapido

1. **Descubrir la PC destino:**
   - Si el usuario conecto una PC nueva con el pendrive (`1-CONECTAR-CLIENTE.bat`) o por web:
     ```powershell
     taller scan
     ```
     Escanea la subred local en los puertos `2222` (clientes temporales) y `22` (PCs propias) y consulta Tailscale si esta disponible.
   - Para ver PCs fijas registradas (`hosts.json`), nodos Tailscale y el ultimo escaneo:
     ```powershell
     taller list
     ```
   - El alias especial `ultimo` apunta automaticamente al cliente mas reciente detectado en puerto `2222`.

2. **Ejecutar comandos y scripts (sin abrir sesion interactiva):**
   ```powershell
   taller ssh <destino> "hostname & whoami"
   taller ssh ultimo "powershell -NoProfile -Command Get-Printer"
   ```
   - `<destino>` acepta: alias de `hosts.json` (`lech`, `restobar`, `mama`), `ultimo`, hostname, nombre Tailscale o IP directa.

3. **Transferir archivos / instaladores:**
   ```powershell
   taller scp C:\ruta\local\archivo.exe ultimo:C:\Temp\
   taller scp lech:D:\drivers\clip.zip .\clip.zip
   ```

4. **Control grafico de ventanas (cuando un instalador o programa no es CLI):**
   TightVNC Server en el destino escucha **solo en `127.0.0.1:5900`**. `taller` abre y cierra un tunel SSH cifrado automaticamente:
   ```powershell
   taller screen <destino>
   ```
   - Imprime la ruta absoluta del PNG generado (ej: `SCREEN_OK 1920x1080 C:\Users\...\screen.png`).
   - Lee ese PNG con la herramienta de lectura de archivos (`read_file`) para ver exactamente que hay en pantalla antes de hacer clic o escribir.
   - Acciones disponibles:
     - `taller click <destino> <x> <y>` (opcional `--right` o `--double`)
     - `taller drag <destino> <x1> <y1> <x2> <y2>`
     - `taller type <destino> "<texto>"`
     - `taller key <destino> <tecla>` (ej: `Enter`, `Tab`, `Esc`, `Alt+F4`, `Ctrl+Shift+Esc`, `Win+R`)
   - Si el usuario humano quiere tomar el control visual en vivo: `taller vnc <destino>`.

5. **Limpieza obligatoria al terminar con una PC de cliente:**
   Cuando termines de reparar una PC ingresada de un cliente en modo temporal (`TallerSSH` puerto `2222`), limpia todo rastro antes de avisar que esta lista para entregar:
   ```powershell
   taller clean <destino>
   ```
   Esto detiene y elimina el servicio `TallerSSH`, la regla de firewall, TightVNC temporal y la carpeta `C:\TallerTmp`. **Nunca ejecutes `taller clean` sobre PCs fijas/propias salvo pedido explicito.**

## Casos frecuentes de soporte

- **Impresoras termicas / de red (ej. resto bar):** listar impresoras y puertos TCP/IP con `Get-Printer`, `Get-PrinterPort` y `Get-Service Spooler`; reconfigurar puerto IP o reinstalar spooler sin ir al local.
- **PCs remotas por Internet (Tailscale):** si el host usa `tag:remoto` en Tailscale, llega directo por su IP `100.x.y.z` o alias registrado.
- **Windows 7 / escaneres legacy:** usan OpenSSH 8.1 en el mismo esquema; preferir comandos PowerShell compatibles con PS 2.0 o `cmd.exe` y apoyarse en `taller screen` / `taller click` para asistentes graficos antiguos.
