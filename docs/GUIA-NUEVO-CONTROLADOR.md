# Guia para Agregar una Nueva PC Controladora

Por defecto vienen configuradas como controladoras:
- `casa-a` (`DESKTOP-LSDMKT9`)
- `lech` (`DESKTOP-SHO7RNL`)

Si mas adelante queres que otra notebook tuya o la PC del local tambien pueda ejecutar `taller` y controlar a todas las demas con los agentes, segui estos **3 pasos**:

---

## Paso 1: Instalar el controlador en la nueva PC

Copia la carpeta `d:\viernes\controller\` + `d:\viernes\skill\` (o clona tu repo `taller-kit`) en la nueva PC y ejecuta en PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\controller\install-controller.ps1 -SelfName "notebook"
```

Este script hace todo solo:
1. Instala `taller.cmd`, `taller.ps1`, `taller_gui.py` y `tvnviewer.exe` en `%USERPROFILE%\.taller\`.
2. Agrega `%USERPROFILE%\.taller` al `PATH` del usuario.
3. Si la PC no tenia clave SSH (`~/.ssh/id_ed25519`), crea una nueva automaticamente.
4. Instala el skill `taller-remote` para agentes en `%USERPROFILE%\.gemini\config\skills\taller-remote\SKILL.md` (y en `~/.codex/skills/` si existe).
5. Muestra en pantalla la **clave publica** de la nueva PC (`ssh-ed25519 AAAA...`).

---

## Paso 2: Autorizar la nueva clave publica

1. En tu PC principal (`DESKTOP-LSDMKT9`), abri [controllers.pub](file:///D:/viernes/keys/controllers.pub).
2. Pega la linea de clave publica de la nueva PC al final del archivo y guarda.

---

## Paso 3: Sincronizar en pendrive, web y PCs fijas

En tu PC principal, ejecuta:

```powershell
taller sync-keys --push
```

Esto actualiza automaticamente:
- `pendrive\TALLER_KIT\config\controllers.pub` (para copiar al pendrive)
- `web\controllers.pub` (si usas GitHub, recuerda hacer `git add web keys pendrive && git commit && git push`)
- `pendrive\ventoy\autounattend\ubuntu-autoinstall\user-data`
- Y con `--push`, envia la nueva clave autorizada por SSH a todas las PCs fijas encendidas de `hosts.json`.
