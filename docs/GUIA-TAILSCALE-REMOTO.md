# Guia de Acceso Remoto por Internet (Tailscale)

Esta guia explica como conectarte **desde tu casa/taller a cualquier PC por Internet** — ya sea una PC tuya en otro local/deposito, una PC de cliente que va y viene, la PC de tu mama o la caja del resto bar de tu amigo — **manteniendo tu red de casa y taller 100% aislada**.

---

## 1. Como funciona el aislamiento (seguridad)

Usamos **Tailscale** con la etiqueta `tag:remoto` y una regla ACL **en una sola direccion**:
- **Tus PCs controladoras** (`DESKTOP-LSDMKT9` / `casa-a` y `lech`) **SI pueden iniciar conexion** hacia cualquier PC etiquetada `tag:remoto`.
- **Las PCs `tag:remoto` NO pueden ver ni conectarse** a tus PCs de casa, ni a tus camaras, ni a otras PCs remotas entre si. Solo responden cuando vos te conectas.
- Ademas, en cada PC el servidor grafico TightVNC escucha **exclusivamente en `127.0.0.1:5900`**, asi que nadie en la red del resto bar ni en Internet puede ver la pantalla sin pasar primero por tu clave SSH privada.

---

## 2. Configurar las reglas ACL en Tailscale (1 sola vez)

1. Entra al panel de Tailscale con tu cuenta (`blechfernando@`):
   `https://login.tailscale.com/admin/acls`
2. Asegurate de tener definidas las `tagOwners` y las `acls`:

```json
{
  "tagOwners": {
    "tag:remoto": ["autogroup:admin"]
  },
  "acls": [
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["autogroup:member:*"]
    },
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["tag:remoto:*"]
    }
  ]
}
```
*(Como `tag:remoto` no aparece en `"src"`, ninguna PC conectada con `tag:remoto` puede iniciar conexiones hacia tu casa, tus camaras ni otros clientes.)*
3. Guarda las ACLs (**Save**).

---

## 3. Crear una Auth Key reutilizable para dar de alta PCs

1. Ve a **Settings -> Keys -> Generate auth key**:
   `https://login.tailscale.com/admin/settings/keys`
2. Configura:
   - **Reusable:** activado (si vas a dar de alta varias PCs; o de un solo uso si preferis).
   - **Expiration:** 90 dias.
   - **Tags:** selecciona `tag:remoto`.
3. Copia la clave generada (`tskey-auth-...`).
   > **Importante:** nunca subas esta clave a GitHub. Guardala solo en lugares privados ignorados por git:
   > - En tu **pendrive privado** como `TALLER_KIT\config\tailscale-auth.txt` (asi `1-CONECTAR.bat` y Ventoy conectan Internet solos sin pedirla).
   > - En tu **PC controladora** como `%USERPROFILE%\.taller\tailscale.key` (asi `taller tailscale <destino>` la lee automatico).

---

## 4. Como conectar una PC (siempre fija: LAN + Internet)

### Opcion A: Con el pendrive
1. Enchufa el pendrive y doble clic en `TALLER_KIT\1-CONECTAR.bat`.
2. Si pusiste `tailscale-auth.txt` en el pendrive, corre minimizado en segundo plano sin preguntar nada: instala **OpenSSH (puerto 22) + TightVNC localhost + Tailscale (`tag:remoto`)** y guarda el resumen (IP LAN e IP Tailscale) en `C:\ProgramData\Taller\install.log`.
   - En **Windows 10/11** (32 y 64 bits) instala Tailscale `1.104.7`.
   - En **Windows 7 / 8** (32 y 64 bits) instala automaticamente Tailscale `1.44.3` *(nota: Windows 7 requiere SP1 con parche SHA-2 `KB4474419` / `KB2921916` para que acepte el driver de red WinTUN)*.

### Opcion B: Desde Internet sin pendrive (1 linea en PowerShell)
```powershell
irm https://raw.githubusercontent.com/blechfernando/taller-kit/main/web/conectar.ps1 | iex
```
1. Podes poner un nombre corto (ej: `restobar`, `mama`, `deposito`) y tu Auth Key — o apretar **ENTER** en la Auth Key para no escribir secretos en la otra PC.
2. Si apretaste ENTER, igual queda todo instalado (`TallerSSH` + TightVNC + Tailscale MSI), y desde tu casa activas Tailscale remoto en 1 segundo:
   ```powershell
   taller tailscale <destino> restobar
   ```

---

## 5. Registrar y usar la PC remota

Una vez que tengas la IP Tailscale (por ejemplo `100.90.10.25` y usuario `Caja`), registrala con un alias comodo:

```powershell
taller add-host restobar 100.90.10.25 Caja 22 "Impresora termica resto bar"
```

Despues, desde cualquiera de tus controladoras (`casa-a` o `lech`, ambos ya tienen Tailscale funcionando):
- **Entrar por consola o arreglar la impresora:**
  ```powershell
  taller ssh restobar "powershell -Command Get-Printer"
  ```
- **Pasarle un driver o archivo:**
  ```powershell
  taller scp .\driver_termica.exe restobar:C:\Temp\
  ```
- **Ver o tocar la pantalla (Excel de tu mama, POS del resto bar, escaner):**
  ```powershell
  taller vnc mama
  ```
  (o decile al agente: *"conectate a `restobar`, fijate por que cambio la IP de la impresora termica y arreglasela"*).

---

## 6. Al entregar la PC al cliente o venderla

Cuando una PC ya no sea tuya ni quede bajo tu soporte, limpia todo rastro con un solo clic o comando:
- Desde el pendrive: doble clic en `TALLER_KIT\2-LIMPIAR.bat`
- Por Internet (1 linea): `irm https://raw.githubusercontent.com/blechfernando/taller-kit/main/web/limpiar.ps1 | iex`
- Desde tu PC: `taller clean <destino>`

Esto hace `tailscale logout` (saca el equipo de tu red Tailscale), desinstala Tailscale y TightVNC (si los instalo el kit), borra `TallerSSH`, cierra el firewall y elimina `C:\ProgramData\Taller`.
