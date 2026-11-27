# Guia de Acceso Remoto por Internet (Tailscale)

Esta guia explica como conectarte **desde tu casa/taller a PCs externas por Internet** — por ejemplo la PC de tu mama (para ayudarla con Excel) o la caja del resto bar de tu amigo (para reconfigurar su impresora termica sin viajar) — **manteniendo tu red de casa y taller 100% aislada**.

---

## 1. Como funciona el aislamiento (seguridad)

Usamos **Tailscale** con una etiqueta especial `tag:remoto` y una regla ACL **en una sola direccion**:
- **Tus PCs controladoras** (esta PC `DESKTOP-LSDMKT9`, `lech`, tu usuario) **SI pueden iniciar conexion** hacia cualquier PC etiquetada `tag:remoto`.
- **Las PCs `tag:remoto` NO pueden ver ni conectarse** a tus PCs de casa, ni a tus camaras, ni a otras PCs remotas entre si. Solo responden cuando vos te conectas.
- Ademas, en cada PC remota el servidor grafico TightVNC escucha **exclusivamente en `127.0.0.1:5900`**, asi que nadie ni nada en la red del resto bar ni en Internet puede ver la pantalla sin pasar primero por tu clave SSH privada.

---

## 2. Configurar las reglas ACL en Tailscale (1 sola vez)

1. Entra al panel de Tailscale con tu cuenta (`blechfernando@`):
   `https://login.tailscale.com/admin/acls`
2. Asegurate de tener definidas las `tagOwners` y las `acls` con esta logica (adaptando si ya tenes otras reglas):

```json
{
  "tagOwners": {
    "tag:remoto": ["autogroup:admin"]
  },
  "acls": [
    // Tus dispositivos propios (sin tag:remoto) pueden hablar entre si
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["autogroup:member:*"]
    },
    // Tus controladores pueden entrar a las PCs remotas (SSH y servicios)
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["tag:remoto:*"]
    }
    // IMPORTANTE: tag:remoto NO aparece en "src", asi que NO puede
    // iniciar conexiones hacia tu casa, tu taller ni otros clientes.
  ]
}
```
3. Guarda las ACLs (**Save**).

---

## 3. Crear una Auth Key reutilizable para dar de alta PCs externas

1. Ve a **Settings -> Keys -> Generate auth key**:
   `https://login.tailscale.com/admin/settings/keys`
2. Configura:
   - **Reusable:** activado (si vas a dar de alta varias PCs, ej. resto bar + mama; o genera una por vez de un solo uso si preferis maxima seguridad).
   - **Expiration:** 90 dias.
   - **Tags:** selecciona `tag:remoto`.
3. Copia la clave generada (`tskey-auth-...`).
   > **Importante:** nunca subas esta clave a GitHub ni a ningun repositorio publico. Si la guardas en tu pendrive privado dentro de `TALLER_KIT\tailscale-auth.txt`, manten el pendrive bajo tu control (y `.gitignore` ya la ignora para no subirla por accidente).

---

## 4. Como conectar una PC externa (2 formas)

### Opcion A: Con el pendrive
1. Enchufa el pendrive en la PC de tu amigo o de tu mama.
2. Doble clic en `TALLER_KIT\4-REMOTO-INTERNET.bat`.
3. Escribi el nombre corto (ej: `restobar` o `mama`) y pega tu `tskey-auth-...` (o dejalo en `tailscale-auth.txt`).
4. En ~30 segundos instala OpenSSH + TightVNC localhost + Tailscale con `tag:remoto`, y te muestra en pantalla la **IP Tailscale** (`100.x.y.z`) y el usuario.

### Opcion B: Desde Internet sin pendrive (1 linea en PowerShell como Admin)
```powershell
irm https://raw.githubusercontent.com/blechfernando/taller-kit/main/web/conectar.ps1 | iex
```
Elegi la **opcion `[3] Remoto por Internet`**, ingresa el alias (`restobar`) y tu Auth Key.

*(Si la PC externa tiene Windows 7 o solo necesitas mirar/tocar la pantalla una vez con asistencia de la persona en vivo, usa `5-PANTALLA-RAPIDA-RUSTDESK.bat` o la opcion `[4]` de la web).*

---

## 5. Registrar la PC remota en tu controlador y usarla

Una vez que tengas la IP Tailscale (por ejemplo `100.90.10.25` y usuario `Caja`), registrala con un alias comodo desde esta PC o desde `lech`:

```powershell
taller add-host restobar 100.90.10.25 Caja 22 "Impresora termica resto bar"
```

Despues, en cualquier momento desde tu casa:
- **Entrar por consola o arreglar la impresora:**
  ```powershell
  taller ssh restobar "powershell -Command Get-Printer"
  ```
- **Pasarle un driver o archivo:**
  ```powershell
  taller scp .\driver_termica.exe restobar:C:\Temp\
  ```
- **Ver la pantalla de Excel de tu mama o del POS del resto bar:**
  ```powershell
  taller vnc mama
  ```
  (o decile al agente: *"conectate a `restobar`, fijate por que cambio la IP de la impresora termica y arreglasela"*).

---

## 6. Activar Tailscale tambien en `lech` (opcional)

`lech` actualmente solo esta en tu red local (`192.168.3.179`). Si queres que **los agentes desde `lech`** tambien lleguen a `restobar` o `mama` por Internet:
1. Copia o ejecuta [tailscale-amd64.msi](file:///D:/viernes/pendrive/TALLER_KIT/bin/tailscale-amd64.msi) en `lech`.
2. Inicia sesion en Tailscale con tu cuenta `blechfernando@`.
3. Copia la linea de `hosts.json` del controlador o ejecuta `taller add-host restobar ...` en `lech`.
