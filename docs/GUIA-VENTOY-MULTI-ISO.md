# Guia del Pendrive Multi-ISO con Ventoy + Taller Kit

Esta guia explica como armar **un unico pendrive** que te sirve al mismo tiempo para:
1. **Instalar cualquier sistema operativo** (Windows 11, Windows 10, Tiny10, Windows 7 32/64-bit para escaneres, Ubuntu Linux, utilidades de rescate) simplemente copiando los archivos `.iso`.
2. **Dejar la PC lista y fija para trabajar** (SSH puerto `22` + TightVNC localhost + Tailscale si pusiste `tailscale-auth.txt`) apenas termina de formatear.
3. **Conectar o limpiar cualquier PC ya instalada** usando los 2 accesos de `TALLER_KIT\` (`1-CONECTAR.bat` y `2-LIMPIAR.bat`).

---

## 1. Como funciona Ventoy (por que reemplaza formatear el pendrive cada vez)

Normalmente, programas como Rufus borran todo el pendrive para grabar **una sola ISO**.
**Ventoy** divide el pendrive en dos partes:
- Una particion chica oculta de arranque (compatible con **UEFI** moderno, **Secure Boot** y **BIOS Legacy** viejo).
- Una particion grande de datos normal (exFAT/NTFS) donde simplemente **copias y pegas archivos `.iso` y carpetas comunes**.

Cuando encendes una PC y arrancas desde el pendrive:
- Ventoy muestra un menu con todas las `.iso` que pusiste en `\ISO\`.
- Para Windows 11, Ventoy saltea automaticamente las trabas de TPM 2.0, Secure Boot, RAM minima y cuenta Microsoft obligatoria (`VTOY_WIN11_BYPASS_CHECK` y `VTOY_WIN11_BYPASS_NRO` ya vienen activos en `ventoy.json`).
- Y si elegis una ISO configurada en `ventoy.json`, Ventoy te pregunta si queres arrancar con nuestra **plantilla Taller**, que:
  - **Mantiene manual la eleccion del disco/particion** (por seguridad: nunca borra por error el disco de datos de un cliente).
  - Configura zona horaria Argentina (`UTC-03:00`).
  - Crea el usuario administrador `Taller` (clave `Taller2026!`) sin pantallas de cuenta Microsoft ni preguntas de privacidad.
  - Al primer inicio de sesion busca el pendrive y ejecuta `TALLER_KIT\scripts\taller-setup.ps1 -Quiet`, dejando OpenSSH + TightVNC localhost + Tailscale (si pusiste `tailscale-auth.txt` en `TALLER_KIT\config\`) prendidos y listos para que tus agentes trabajen.

---

## 2. Como preparar el pendrive paso a paso (1 sola vez)

Usa un pendrive de **32 GB o 64 GB** (o mas grande si vas a guardar muchas ISOs). **Este paso borra el contenido actual del pendrive.**

1. Conecta el pendrive vacio o respaldado en esta PC.
2. Ejecuta como Administrador:
   [Ventoy2Disk.exe](file:///D:/viernes/tools/ventoy/Ventoy2Disk.exe)
3. En el menu **Option** de Ventoy2Disk:
   - **Partition Style:** `GPT` si casi todas tus PCs son modernas UEFI, o `MBR` si formateas seguido notebooks/PCs muy viejas con BIOS Legacy (MBR funciona bien tanto en Legacy como en UEFI en la mayoria de equipos).
   - **Secure Boot Support:** activado (`Options -> Secure Boot Support`).
4. Selecciona tu pendrive en el desplegable **Device** y pulsa **Install** (confirma el formateo).
5. Al terminar, te queda una unidad USB normal (ej. `E:\`). Copia dentro de la raiz de ese pendrive **todo el contenido** de la carpeta `d:\viernes\pendrive\`:
   - `E:\ISO\`
   - `E:\ventoy\` (contiene `ventoy.json` y `autounattend\`)
   - `E:\TALLER_KIT\` (contiene `1-CONECTAR.bat`, `2-LIMPIAR.bat`, `linux-conectar.sh`, `scripts\`, `bin\` y `config\controllers.pub`)
6. *(Opcional recomendado)* Crea `E:\TALLER_KIT\config\tailscale-auth.txt` pegando dentro tu Auth Key `tskey-auth-...` (`tag:remoto`) para que tanto `1-CONECTAR.bat` como las instalaciones Ventoy conecten Internet automaticamente.
7. Descarga o copia tus `.iso` dentro de `E:\ISO\` respetando estos nombres recomendados:

| Archivo en `E:\ISO\` | Para que sirve | Plantilla automatica asociada |
|---|---|---|
| `Win11.iso` | PCs y notebooks modernas | `win10-11-taller.xml` (saltea TPM y cuenta MS) |
| `Win10.iso` | Windows 10 general | `win10-11-taller.xml` |
| `Tiny10.iso` | Notebooks/PCs viejas con 2–4 GB RAM | `win10-11-taller.xml` |
| `Win7_x64.iso` | Windows 7 64-bit (escaneres, hardware legacy) | `win7-taller.xml` |
| `Win7_x86.iso` | Windows 7 32-bit (ej. Renault Clip antiguo) | `win7-x86-taller.xml` |
| `ubuntu-24.04.5-live-server-amd64.iso` | Servidores de camaras, proyectos Linux | `ubuntu-autoinstall/user-data` |

> Ya tenes una ISO de Ubuntu en [D:\isos\ubuntu-24.04.5-live-server-amd64.iso](file:///D:/isos/ubuntu-24.04.5-live-server-amd64.iso) lista para copiar a `E:\ISO\`.

---

## 3. Como se usa al formatear una PC

1. Enchufa el pendrive y bootea por USB (F12 / F8 / F11 / Esc segun la placa).
2. En el menu de Ventoy elegi la ISO (por ejemplo `Win10.iso` o `Win7_x86.iso`).
3. Cuando Ventoy muestre el submenu de plantilla:
   - Elegi `Boot with /ventoy/autounattend/...` para que al terminar deje **Taller SSH + VNC + Tailscale** activado.
   - O elegi `Boot without template` si queres una instalacion comun manual.
4. En el instalador de Windows, elegi el disco/particion donde instalar (el unico paso manual por seguridad).
5. Deja que termine e inicie sesion automatico con `Taller`. Espera ~30 segundos a que termine de configurar OpenSSH, TightVNC y Tailscale.
6. Desde tu PC principal o desde `lech`, decile al agente: *"acabo de formatear la notebook, buscala y terminale la configuracion"* (o corre `taller scan`).

---

## 4. Nota sobre Ubuntu 24.04 Server y `cidata`

En Ubuntu 24.04, la ISO se bloquea al arrancar, por lo que `cloud-init` busca una particion etiquetada `cidata` si queres instalacion 100% sin tocar teclado.
- Opcion A (la mas facil para taller): instala Ubuntu normal seleccionando "Install OpenSSH server" en el asistente, y apenas arranca ejecuta el 1-liner de red:
  ```bash
  curl -fsSL http://<IP_DE_TU_PC>:8787/linux.sh | sudo TALLER_BASE_URL=http://<IP_DE_TU_PC>:8787 bash
  ```
- Opcion B (100% desatendida por USB): reserva ~16 MB al final del pendrive al crearlo con Ventoy (`Ventoy2Disk` -> Option -> Partition Configuration -> Preserve space at the bottom), formatea ese espacio en FAT32 con etiqueta `cidata` y copia dentro los archivos `user-data` y `meta-data` de [ubuntu-autoinstall](file:///D:/viernes/pendrive/ventoy/autounattend/ubuntu-autoinstall/user-data).

---

## 5. Caso especial: Drivers USB 3.0 / NVMe en Windows 7 o Intel VMD en notebooks nuevas

Windows 7 original no trae drivers USB 3.0 ni discos NVMe modernos, y muchas notebooks Intel Gen 11–14 traen controlador VMD que oculta el SSD en Windows 10/11. Ventoy lo resuelve **sin modificar tu ISO** con el plugin **Injection**:

1. Junta la carpeta de drivers `.inf/.sys/.cat` del controlador (por ejemplo `drivers\vmd\` o `drivers\win7_usb3\`).
2. Comprimila en un `.zip` (por ejemplo `E:\ventoy\injection\win7_drivers.zip`) con la estructura `drivers\...` adentro.
3. Agrega en `E:\ventoy\ventoy.json`:
   ```json
   "injection": [
     {
       "image": "/ISO/Win7_x64.iso",
       "archive": "/ventoy/injection/win7_drivers.zip"
     }
   ]
   ```
4. Durante el instalador de Windows ("Cargar controlador" / "Load driver"), examina `X:\drivers\` (el disco RAM donde Ventoy descomprimio el ZIP automaticamente) y selecciona el driver.
