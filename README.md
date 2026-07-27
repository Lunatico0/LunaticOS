# win11-debloat-iso

Debloat **offline** de Windows 11 25H2: se edita la imagen (`install.wim`) **dentro de la ISO original**
antes de instalar, así el bloat **nunca llega al disco**. No se toca un SO ya corriendo.

> Estado: 🚧 en construcción. Enfoque y toolchain definidos; pipeline en desarrollo.

## Por qué offline y no post-install

Editar la imagen = el bloat no se instala nunca, no hay que "limpiar" después, y la ISO
resultante es reproducible en cualquier PC. Lo que no se puede hacer 100% offline
(algunas scheduled tasks, ajustes runtime) se resuelve inyectando un `SetupComplete.cmd`
que corre **al final del setup** — sigue siendo parte de la ISO, no una limpieza manual posterior.

## Principios (la línea que no se cruza)

- **Anticheat-safe.** Nada de lo que hacemos flaggea Vanguard/FACEIT. Secure Boot + TPM intactos.
- **No romper dependencias de dev** (winget, Store, runtimes VC++/.NET, WSL/Hyper-V).
- **Reversible donde se pueda.** Los tweaks de registro se documentan con su reversa.
- **Con criterio, no a ciegas.** El perfil base salió de 32 días de uso real medido, no de una guía de foro.

## Requisitos (host que edita la ISO)

| Requisito | Detalle |
|---|---|
| Windows | Host igual o más nuevo que el target (editar 25H2 → ADK 24H2 con DISM acorde) |
| Windows ADK 24H2 | Solo *Deployment Tools* → aporta `oscdimg` + `dism` |
| ISO | Windows 11 **25H2 x64 Pro**, oficial de Microsoft (no modificada de terceros) |
| Disco | ~20 GB libres de scratch para montar/exportar el WIM |
| Permisos | Consola **como Administrador** |

## Estructura

```
win11-debloat-iso/
├── scripts/   # pipeline offline (montar WIM, quitar appx, hives, rearmar ISO)
├── config/    # listas de appx, features, autounattend.xml, hives offline
├── docs/      # plan por fases, decisiones, tabla anticheat
└── work/      # scratch (gitignored): ISO original, WIM montado, ISO de salida
```

## Uso

Consola **como Administrador**. Poné la ISO oficial de Win11 25H2 en `work\` y corré las fases en orden:

```powershell
cd scripts
.\00-prepare-wim.ps1        # exporta Pro de la ISO original y monta el WIM
.\01-remove-appx.ps1        # quita appx bloat (Widgets/clima se CONSERVAN)
.\02-remove-onedrive.ps1    # OneDrive fuera (archivos + hives)
.\03-privacy-policies.ps1   # telemetria, Copilot, Recall, ads (SOFTWARE hive)
.\04-services.ps1           # servicios de telemetria a Disabled (SYSTEM hive)
.\05-ui-tweaks.ps1          # explorer/taskbar dev-friendly, sin ads (DEFAULT hive)
.\06-features.ps1           # IE, WMP legacy, WorkFolders, etc. (DISM)
.\07-inject-runtime.ps1     # SetupComplete.cmd (tasks + quitar Edge) + autounattend.xml
.\08-build-iso.ps1          # cierra el WIM y arma la ISO booteable
```

**Para ajustar sin programar:** editá `scripts\config.ps1` — listas de appx/servicios/features/capabilities
y flags (`ShowWeatherWidget`, `RemoveOneDrive`, etc.). Cada compa lo tunea a su gusto sin tocar la lógica.

### Grabar a USB

El `install.wim` pesa >4 GB, así que **no entra en un pendrive FAT32 común**. Usá **[Rufus](https://rufus.ie)**:
elegí la ISO, esquema **GPT / UEFI**; Rufus parte el WIM solo. Queda listo para bootear e instalar.

## Aviso

El perfil por defecto está pensado para **dev pesado + gaming competitivo**. Si tu uso es otro,
revisá las listas de `config/` antes de correrlo: debloatear a ciegas el perfil de otra persona
es exactamente lo que este proyecto trata de evitar.
