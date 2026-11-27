# Taller Kit — Control Remoto Multi-PC + Pendrive Multi-ISO

Sistema unificado con **solo 2 acciones** en las PCs destino:
1. **`1-CONECTAR`** (pendrive o web): deja la PC **fija y completa** para trabajar (OpenSSH puerto `22` en `C:\ProgramData\Taller`, TightVNC solo en `127.0.0.1:5900` por tunel SSH, y Tailscale listo para acceso por Internet aunque la PC se apague, cambie de Wi-Fi o te la lleves a otro local/deposito).
2. **`2-LIMPIAR`** (pendrive, web o remoto `taller clean`): desinstala todo por completo (`TallerSSH`, TightVNC, `tailscale logout` + Tailscale, firewall y `C:\ProgramData\Taller`) cuando entregas la PC al cliente o la preparas para vender.

Todo se controla desde tus PCs controladoras (`DESKTOP-LSDMKT9` y `lech`) o con agentes de IA, **sin instalar agentes de IA en las maquinas destino**.

---

## Como se usa en cada situacion

| Situacion | En la PC destino | Desde tu PC / Agente |
|---|---|---|
| **Cualquier PC (propia, taller, local, cliente en reparacion, deposito)** | Doble clic en `TALLER_KIT\1-CONECTAR.bat` (o 1 linea web) | *"Ya conecte la compu nueva, revisala"* -> `taller scan`, `taller ssh ultimo`, `taller screen ultimo` |
| **Sin pendrive a mano (por Internet)** | En PowerShell: `irm https://raw.githubusercontent.com/blechfernando/taller-kit/main/web/conectar.ps1 \| iex` | `taller scan` / `taller tailscale <destino> <alias>` / `taller add-host ...` |
| **Sin pendrive ni Internet (por LAN del taller)** | En PC principal: `taller serve` -> pegar el 1-liner LAN en la otra PC | Baja OpenSSH/VNC/Tailscale directo desde tu red local en segundos |
| **Formatear PC desde cero (Multi-ISO)** | Booteo con pendrive **Ventoy** -> elegir ISO + plantilla Taller | Al primer inicio ya ejecuta `taller-setup.ps1` y queda conectada sola |
| **Al entregar al cliente o vender la PC** | Doble clic en `TALLER_KIT\2-LIMPIAR.bat` (o `irm .../web/limpiar.ps1 \| iex`) | O desde tu PC: `taller clean <destino>` |

---

## Trucos cero-friccion (opcionales pero recomendados)

- **Pendrive 100% automatico con Internet:** guarda tu Auth Key de Tailscale (`tskey-auth-...`) una sola vez en `TALLER_KIT\config\tailscale-auth.txt` dentro de tu pendrive fisico (no se sube a GitHub). Asi, cada vez que hagas doble clic en `1-CONECTAR.bat` o formatees con Ventoy, deja SSH + VNC + Tailscale **ya conectado sin pedirte nada**.
- **Activacion remota de Tailscale desde el controlador:** guarda tu Auth Key una sola vez en `%USERPROFILE%\.taller\tailscale.key`. Cuando conectes una PC por GitHub web apretando ENTER en el paso de la clave, la activas desde tu PC con `taller tailscale <destino> restobar`.

---

## Estructura del proyecto

- [keys/controllers.pub](file:///D:/viernes/keys/controllers.pub) — Unica fuente de claves publicas autorizadas (cero secretos privados).
- [pendrive/TALLER_KIT/](file:///D:/viernes/pendrive/TALLER_KIT/1-CONECTAR.bat) — Kit 100% offline para el pendrive (`1-CONECTAR.bat`, `2-LIMPIAR.bat`, `linux-conectar.sh` + binarios Win7/Win10/Win11 x86/x64).
- [pendrive/ventoy/](file:///D:/viernes/pendrive/ventoy/ventoy.json) — Configuracion Multi-ISO Ventoy + plantillas desatendidas seguras (`win10-11-taller.xml`, `win7-taller.xml`, `win7-x86-taller.xml`, `ubuntu-autoinstall`).
- [web/](file:///D:/viernes/web/conectar.ps1) — Bootstrap por nube/LAN (`conectar.ps1`, `limpiar.ps1`, `linux.sh`).
- [controller/](file:///D:/viernes/controller/taller.ps1) — CLI `taller` + cliente VNC puro Python (`taller_gui.py`) + servidor LAN (`lan_server.py`) + visor TightVNC portable.
- [skill/taller-remote/SKILL.md](file:///D:/viernes/skill/taller-remote/SKILL.md) — Skill global para que cualquier agente sepa usar `taller` automaticamente.

---

## Guias detalladas

1. [Armado y uso del Pendrive Multi-ISO (Ventoy)](file:///D:/viernes/docs/GUIA-VENTOY-MULTI-ISO.md)
2. [Acceso remoto por Internet con Tailscale (Resto bar / Familia / Clientes)](file:///D:/viernes/docs/GUIA-TAILSCALE-REMOTO.md)
3. [Como sumar una nueva PC controladora](file:///D:/viernes/docs/GUIA-NUEVO-CONTROLADOR.md)

---

## Referencia rapida del comando `taller`

```powershell
taller scan                           # Busca PCs en LAN (puertos 22 y 2222) + Tailscale
taller list                           # Muestra PCs fijas, Tailscale y ultimo scan
taller ssh <destino> [cmd]            # Consola o comando remoto
taller scp <orig> <dest>              # Copiar archivos (ej: app.exe ultimo:C:\Temp\)
taller tailscale <destino> [alias]    # Activa Internet Tailscale remotamente en destino
taller screen <destino>               # Captura pantalla remota en PNG (via tunel SSH+VNC)
taller click <destino> x y            # Clic (--right / --double)
taller type <destino> "texto"         # Escribir texto
taller key <destino> Alt+F4           # Atajos de teclado
taller vnc <destino>                  # Abre ventana TightVNC interactiva por tunel SSH
taller clean <destino>                # Limpia por completo SSH/VNC/Tailscale al entregar
taller serve                          # Sirve web/ + bin/ en tu LAN sin necesitar pendrive
taller sync-keys --push               # Sincroniza controllers.pub en pendrive, web y PCs fijas
```
