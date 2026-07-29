# win11-debloat-iso

Debloat **offline** de Windows 11 25H2: se edita la imagen (`install.wim`) **dentro de la ISO original**
antes de instalar, así el bloat **nunca llega al disco**. No se toca un SO ya corriendo.

> Estado: ✅ **funcionando**. Pipeline completo (9 fases) y probado en VM: instala desatendido con cuenta
> local, sin bloat, sin Edge. Ver `docs/decisiones.md` para el porqué de cada decisión.

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

## Uso rápido: LunaticOS (recomendado)

Poné la ISO oficial de Windows 11 en `work\` y **doble clic en `LunaticOS.cmd`**.

```
LunaticOS.cmd          <- doble clic (se eleva solo a Administrador)
```

> **¿Por qué un `.cmd` y no el `.ps1`?** Windows asocia los `.ps1` al **editor**, no al
> intérprete: doble clic en `LunaticOS.ps1` abre el Notepad y parece que está roto. El `.cmd`
> sí se ejecuta, y además pide elevación solo (el pipeline monta imágenes y edita hives, necesita
> Administrador).

La herramienta hace todo:

1. **Preflight** — admin, espacio en disco, ADK (lo descarga e instala si falta), ISO.
2. **Selección** — apps, servicios, features, opciones, personalización y programas a instalar.
   Con `*` en lo recomendado y **la explicación de cada ítem siempre a la vista**.
3. **`perfil.json`** — guarda tu selección. Es **compartible**: le pasás el archivo a un compa y
   genera la misma ISO que vos, sin volver a elegir nada.
4. **Pipeline** — corre las 12 fases y arma la ISO.

```powershell
.\LunaticOS.ps1 -SelfTest    # 44 validaciones, sin UI ni build
.\LunaticOS.ps1 -Apply       # usa el perfil.json existente y genera, sin abrir la TUI
```

## Uso manual (fase por fase)

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
.\07-remove-edge.ps1        # navegador Edge fuera (WebView2 se CONSERVA)
.\08-inject-runtime.ps1     # SetupComplete.cmd (tasks telemetria) + autounattend.xml
.\09-build-iso.ps1          # cierra el WIM y arma la ISO booteable
```

**Para ajustar sin programar:** editá `scripts\config.ps1` — listas de appx/servicios/features/capabilities
y flags (`ShowWeatherWidget`, `RemoveOneDrive`, etc.). Cada compa lo tunea a su gusto sin tocar la lógica.

### Servicios: 27 apagados, 25 opcionales documentados

`$ServicesDisable` trae los que apagamos por defecto. `$ServicesOptional` trae los que **dependen de tu
hardware y tu uso**, desactivados, cada uno con **qué perdés** si lo apagás. Para usar uno, movelo al
primer bloque — pero leé la nota antes, porque varios muerden:

| Servicio | Lo que casi nadie te avisa |
|---|---|
| `SSDPSRV` / `upnphost` | **NAT estricto en juegos.** El sospechoso #1 si el matchmaking empeora tras debloatear. |
| `SharedAccess` | Lo usa el **Default Switch de Hyper-V**. Si virtualizás, dejalo. |
| `diagnosticshub.standardcollector` | Lo usa el **profiler de Visual Studio**. |
| `WSearch` | Te mata la búsqueda de archivos — justo lo que un dev usa todo el día. |
| `SysMain` | El clásico "apagalo para gamear". En 25H2 con SSD puede **empeorar** las cargas. |
| `Spooler` | Cierra el vector de PrintNightmare, pero también mata *Imprimir a PDF*. |

Regla: **Manual > Disabled cuando dudes.** En Manual no arranca solo, pero si algo lo necesita lo levanta.

### Probar la ISO en una VM antes de grabarla (muy recomendado)

Cada bug que encontró este proyecto salió de instalar en una VM y **leer los logs** — no de revisar
el código. Rehacer una ISO cuesta ~45 min; descubrir el problema en la máquina real cuesta reinstalar.

```powershell
.\test-vm.ps1 -Reset -Boot   # VHDX limpio + la ISO en el DVD + arranca
# -> UN clic en "Next" en la selección de disco (el teclado sintético no llega ahí)
.\test-vm.ps1 -Shot          # screenshot para ver el progreso
Stop-VM Debloat-Test
.\test-vm.ps1 -Verify        # audita el disco instalado: Edge, WebView2, servicios, logs
```

Requiere una VM Hyper-V **Gen2** llamada `Debloat-Test` (el script le pone Secure Boot + TPM solo).

### Instalar en la máquina real

Seguí **[`docs/dia-d.md`](docs/dia-d.md)** — checklist completo: grabar el USB, qué tocar en la BIOS
(Secure Boot + TPM son innegociables), qué esperar durante la instalación y cómo verificar el resultado.

### Grabar a USB

El `install.wim` pesa >4 GB, así que **no entra en un pendrive FAT32 común**. Usá **[Rufus](https://rufus.ie)**:
elegí la ISO, esquema **GPT / UEFI**; Rufus parte el WIM solo. Queda listo para bootear e instalar.

Al bootear del USB **apretá una tecla** cuando aparezca *"Press any key to boot from CD or DVD"*
(tenés ~5 segundos; si se vence, el firmware aborta con `The boot loader failed` y hay que reintentar).
**Una sola vez, al principio.** En los reinicios que hace el instalador **no toques nada** — ese prompt
es precisamente lo que hace que arranquen del disco y no del USB. Ver D17 en `docs/decisiones.md`.

## Qué pasa con Edge (y por qué no se desinstala)

Edge **no se desinstala: se oculta y se bloquea.** No es una concesión, es lo que la evidencia obligó.

El instalador de WebView2 y el de Edge son **el mismo binario** (`MicrosoftEdge_X64_<ver>.exe`).
Windows Update lo baja para actualizar WebView2 — que la Store y los Widgets necesitan — y Edge viene
adentro del paquete. Se intentó desinstalarlo tres veces (uninstaller, borrado offline, matar
EdgeUpdate) y las tres volvió. Ver **D21**.

Así que se bloquea la **ejecución** en lugar de pelear contra la instalación:

- **IFEO** sobre `msedge.exe`, `msedge_proxy.exe` y `msedge_pwa_launcher.exe`: el kernel no lo lanza.
  La clave es por *nombre de ejecutable*, así que da igual cuántas veces lo reinstalen.
- Accesos directos borrados + `CreateDesktopShortcutDefault=0` para que no los recreen.
- `msedgewebview2.exe` **no** se toca: es WebView2, otro ejecutable. Sigue funcionando y **se
  actualiza solo**, sin mantenimiento manual.

**Único ajuste manual:** poné Firefox/Chrome como predeterminado (`Settings → Apps → Default apps`).
Si algo del sistema quiere abrir un link con Edge, falla en silencio.

Para revertirlo en un equipo ya instalado: `herramientas\ocultar-edge.ps1 -Revert`.
Para no aplicarlo nunca: `RemoveEdgeBrowser = $false` en `scripts\config.ps1`.

## Trampas conocidas (aprendidas a los golpes, no las repitas)

| Síntoma | Causa real |
|---|---|
| El instalador pide product key, idioma y teclado; BypassNRO no hace nada; fecha en formato US | Al `autounattend.xml` le falta el pass **`windowsPE`**. El setup encuentra el archivo, lo evalúa contra el pass en curso, no le sirve y lo **descarta entero** — se pierden también `specialize` y `oobeSystem`. Un defecto, cuatro síntomas. |
| `The computer restarted unexpectedly` a mitad de instalación | Un setting en el componente equivocado del unattend (nos pasó con `RunSynchronous` en `Shell-Setup`, que va en `Microsoft-Windows-Deployment`). No se ignora: invalida el archivo y aborta. La fase 8 ahora lo valida antes de buildear. |
| Edge sigue instalado pese a `SetupComplete.cmd` | El uninstaller de Microsoft se niega fuera del EEA (`Browser/WebView is sticky, uninstall not allowed` / `blocked for this product: 93`). Y aunque funcionara, **EdgeUpdate lo reinstala de internet**. Por eso Edge se saca offline (fase 7) + policy `Install{56EB18F8-...}=0`. |
| Edge vuelve aunque la policy esté escrita | `EdgeUpdate` **saltea** las group policies fuera del EEA: `Edge not uninstallable per regional policy, skipping group policy`. Y lo instala Windows Update (`/installsource windowsupdate_zdp`). **La policy sola es decorativa.** |
| Arrancar con GeoID del EEA para que la policy valga | **No funciona.** El `<UserLocale>es-AR</UserLocale>` del pass `oobeSystem` pisa el GeoID antes de que EdgeUpdate corra. Se intentó y se descartó. Ver **D20**. |
| Edge vuelve aunque mates los servicios de EdgeUpdate | El instalador de WebView2 **es el mismo** que el de Edge (`MicrosoftEdge_X64_<ver>.exe --msedgewebview`). Y Windows Update ejecuta el binario directo, sin pasar por el servicio — que además se recrea solo al reinstalarse. No se puede desinstalar y conservar WebView2: se **bloquea la ejecución** con IFEO. Ver **D21**. |
| Deshabilitar `edgeupdate` "para que no vuelva" | Contraproducente: es quien parcha **WebView2**. La fase 7 lo deja **vivo a propósito** y hasta revierte a `Start=2/3` si venía deshabilitado de una corrida vieja. |
| `The boot loader failed` al arrancar el medio | Prompt *Press any key to boot from CD* vencido (tenés ~5 s). **Reintentá el boot y apretá una tecla a tiempo.** NO cambies a `efisys_noprompt.bin`: ese prompt es lo que evita que los reinicios intermedios del setup vuelvan a bootear del medio. Ver **D17**. |
| La VM de prueba no arranca tras instalar | El DVD sigue primero en el boot order. Sacar la ISO y poner el disco primero. |

## Aviso

El perfil por defecto está pensado para **dev pesado + gaming competitivo**. Si tu uso es otro,
revisá las listas de `config/` antes de correrlo: debloatear a ciegas el perfil de otra persona
es exactamente lo que este proyecto trata de evitar.
