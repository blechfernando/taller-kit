================================================================================
  CARPETA \ISO\ DEL PENDRIVE VENTOY - NOMBRES RECOMENDADOS
================================================================================

Copia tus archivos .iso dentro de la carpeta \ISO\ del pendrive Ventoy con estos
nombres para que Ventoy muestre el menu bonito y te ofrezca la plantilla
desatendida con Taller SSH preinstalado:

  Archivo en \ISO\                         Uso recomendado
  ---------------------------------------  -------------------------------------
  Win11.iso                                PCs modernas (Ventoy salta TPM/RAM)
  Win10.iso                                PCs generales y notebooks
  Tiny10.iso                               PCs/notebooks viejas (2-4 GB RAM)
  Win7_x64.iso                             Escaneres automotrices / Win7 64-bit
  Win7_x86.iso                             Escaneres antiguos / Win7 32-bit
  ubuntu-24.04.5-live-server-amd64.iso     Servidores, camaras, proyectos Linux
  (o ubuntu-24.04-live-server-amd64.iso)

NOTA:
- Podes agregar cualquier otra ISO (Linux Mint, HirensBoot, Clonezilla, etc.)
  en \ISO\ aunque no este en esta tabla: Ventoy las bootea igual!
- Cuando elijas una ISO de la tabla, Ventoy pregunta si queres:
    [0] Boot sin plantilla (instalacion normal)
    [1] Boot con plantilla Taller (crea usuario Taller / Taller2026! y ejecuta
        TALLER_KIT\scripts\taller-setup.ps1 automaticamente al terminar)
- Si guardas tu Auth Key de Tailscale en \TALLER_KIT\config\tailscale-auth.txt,
  al terminar el formateo tambien queda conectada a Internet sola.
- Si necesitas inyectar drivers NVMe / USB 3.0 en Windows 7 o Intel VMD en
  notebooks nuevas, revisa la seccion "Injection" en docs\GUIA-VENTOY-MULTI-ISO.md.
================================================================================
