# Decisiones del proyecto

> La "memoria" del proyecto. Todo lo que decidimos, con el porqué. Si en 6 meses no te acordás
> por qué algo es así, se responde acá. Formato ADR ligero: contexto → decisión → porqué.

## D1 — Enfoque: debloat OFFLINE sobre la imagen

- **Decisión:** editar el `install.wim` **dentro de la ISO original** (montar con DISM, quitar appx
  provisioned, features/capabilities, editar hives offline, rearmar ISO booteable con `oscdimg`).
- **Porqué:** el bloat nunca se instala; nada que "limpiar" después; la ISO resultante es reproducible
  en cualquier PC. Descartado el post-install (los scripts viejos `debloat*.ps1` quedan como referencia).
- **Límite honesto:** lo que no se puede hacer 100% offline (algunas scheduled tasks, ajustes runtime)
  se inyecta en un `SetupComplete.cmd` que corre al final del setup. Sigue siendo parte de la ISO.

## D2 — Versión: Windows 11 25H2 Pro x64

- **Decisión:** 25H2 (build 26200.x), edición **Pro**, ISO **oficial de Microsoft** (no modificada).
- **Porqué:** 25H2 es la última ESTABLE (jul 2026). 26H2 existe pero es preview/Insider → descartado:
  Vanguard/FACEIT sobre Insider = cierres y `VAN` errors. Pro porque el plan asume el tratamiento de
  `AllowTelemetry=0` como Pro (en Home varias policies no pegan).

## D3 — Diseño: perfil de referencia + modular

- **Decisión:** el perfil por defecto es el de Pittana (dev pesado + FPS competitivo, salido de 32 días
  de uso medido). Pero **todo modular con toggles**: cada compa puede activar/desactivar bloques a gusto.
- **Porqué:** los compas son devs y juegan a lo mismo, pero cada uno arma y desarma como quiera.
  Imponer un perfil ajeno a ciegas es justo lo que este proyecto evita.

## D4 — Toolchain (host que edita la ISO)

- **Host actual:** Windows 11 Pro **23H2** (build 22631).
- **Decisión:** instalar **Windows ADK 24H2 → solo Deployment Tools** (`oscdimg` + `dism` acorde al target).
- **Porqué:** `oscdimg` no viene con Windows y hace falta para rearmar la ISO booteable. El DISM del host
  (23H2) es más viejo que el target (25H2); el del ADK 24H2 cubre 24H2/25H2 (misma base 26100).
- **Scratch:** en `E:` o `D:` (C: tiene poco libre). Nunca en el repo (`work/` está gitignored).
- **Instalado (2026-07-26):** `...\Deployment Tools\amd64\Oscdimg\oscdimg.exe` (2.56) +
  `...\Deployment Tools\amd64\DISM\dism.exe` (10.0.26100.2454). El pipeline usa ESTE dism, no el del sistema.

## D5 — Reglas de oro (heredadas del plan original, innegociables)

1. **Secure Boot + TPM 2.0 SIEMPRE ON.** Vanguard los exige; sin ellos Valorant no abre (`VAN9001`).
2. **No tocar red/firewall/cripto/anticheat:** `BFE`, `mpssvc`, `CryptSvc`, DNS/DHCP, `vgc`/`vgk`.
3. **No romper dependencias de dev disfrazadas de bloat:** winget (`DesktopAppInstaller`), Store,
   `VCLibs`, `UI.Xaml`, `WindowsAppRuntime`, `.NET.Native`, WebView2.
4. **Telemetría se corta por servicio + tarea + policy**, NUNCA por firewall/hosts (rompe Windows Update).

## D6 — Datos personales fuera del repo

- **Decisión:** `uso.csv` y `servicios.csv` (medición de uso propia) NO se suben. Ya están en `.gitignore`.
- **Porqué:** son datos personales de qué usa Pittana, irrelevantes para el resto y no compartibles.

---

## Estado actual

- [x] Repo inicializado (`git init`, branch `main`), `README.md`, `.gitignore`.
- [x] Decisiones asentadas (este doc).
- [x] ADK 24H2 (Deployment Tools) instalado — `oscdimg` 2.56 + DISM 10.0.26100.2454.
- [x] ISO 25H2 Pro descargada + **hash SHA-256 verificado** (`Win11_25H2_English_x64_v2.iso`).
- [x] WIM reducido a **solo Pro** (index 1) y montado en `work\mount`.
- [x] **Fase 1 — appx:** 19 removidos, 28 conservados (verificado; deps/Xbox/codecs intactos).
- [x] **Fase 2 — OneDrive fuera** + helper de hives offline (verificado, sin hives colgados).
- [x] **Fase 3 — privacidad/policies** (15 policies: telemetría, Copilot, Recall, ads) → SOFTWARE hive.
- [x] **Fase 4 — servicios** (15 disabled; críticos de red/firewall/audio intactos) → SYSTEM hive.
- [x] **Fase 5 — UI tweaks** (22 tweaks; explorer, taskbar, ads off, Bing web off) → DEFAULT hive.
- [x] **Fase 6 — features/capabilities** (IE 11, WMP legacy, StepsRecorder, MathRecognizer, Handwriting, WorkFolders) → DISM.
- [x] **Fase 7 — navegador Edge fuera** offline + EdgeUpdate neutralizado (WebView2 se conserva; ver D20).
- [x] **Fase 8 — SetupComplete.cmd + autounattend.xml** (cuenta local, teclado ES+EN, tasks telemetría).
- [x] **Fase 9 — commit del WIM + rearmar ISO** booteable (oscdimg).

## RESULTADO ✅ — ISO v5 (2026-07-28)

`work\Win11_25H2_Pro_debloat.iso` — Windows 11 **Pro 25H2** debloateado, booteable UEFI+BIOS.
Verificado: install.wim = solo Pro, autounattend en raíz con los 3 passes, boot sectors presentes.

**Correcciones sobre el plan original:** Widgets/clima CONSERVADOS (toggle `ShowWeatherWidget`, feed MSN
off por defecto en 25H2); Edge (navegador) se quita **offline** de la imagen (fase 7) preservando WebView2.

### Probado en VM (test v4) y funcionando

- Cuenta local `pato` automática: entra directo al escritorio, nunca pide cuenta Microsoft.
- Formatos es-AR, teclado ES LatAm + EN US. Sin pantallas de idioma/product key/EULA/edición.
- OneDrive, Copilot y bloat ausentes. Store y WebView2 funcionando.

### Lo que cambió de v4 a v5 (el único pendiente que quedaba: Edge)

En v4 Edge se reinstalaba durante el OOBE. La v5 lo corta matando EdgeUpdate offline en la fase 7,
y deja la región en Argentina sin trucos. Ver **D20** — incluye el costo asumido (WebView2 a mano).

## D14 — El `autounattend.xml` DEBE tener el pass `windowsPE` (2026-07-27, test en VM)

- **Contexto:** la primera ISO instaló bien pero el unattend no tuvo ningún efecto: pidió product key,
  pidió idioma y teclado, `BypassNRO` nunca se escribió y el `UserLocale` quedó en `en-US`.
- **Evidencia** (`C:\Windows\Panther\setupact.log` de la VM instalada):
  ```
  UnattendSearchExplicitPath: Found unattend file at [D:\autounattend.xml]; examining for applicability.
  UnattendSearchExplicitPath: [D:\autounattend.xml] does not meet criteria to be used for this unattend pass.
  SetupHost: Unattend not found. Releasing UnattendMgr object.
  Callback_Unattend_InitiatePass: No unattend file was present, skipping unattend settings passes
  ```
  Además `C:\Windows\Panther\unattend.xml` **no existe** en el disco instalado: prueba de que nunca se procesó.
- **Decisión:** el archivo lleva `windowsPE` sí o sí, con `Microsoft-Windows-Setup/UserData`
  (ProductKey genérica de Pro + `AcceptEula`) y `Microsoft-Windows-International-Core-WinPE`.
- **Porqué:** el instalador evalúa el unattend contra el pass en curso (`windowsPE`). Si no encuentra nada
  aplicable, **descarta el archivo entero** — no lo guarda para pases posteriores. Un solo defecto producía
  cuatro síntomas distintos, que es exactamente por qué hay que diagnosticar antes de parchar.
- **Guarda:** la fase 8 valida el XML y aborta si falta `windowsPE`. Un `--` dentro de un comentario XML
  también invalida el archivo (nos pasó al reescribirlo): el archivo se mantiene en **ASCII puro**.

## D15 — Cuenta local por `<UserAccounts>`, no por BypassNRO

- **Contexto:** en 25H2 el OOBE mostró "Unlock your Microsoft experience" con un único botón *Sign in*.
- **Decisión:** crear la cuenta local directamente en el pass `oobeSystem` (`LocalAccount` en el grupo
  Administrators, password vacío) + `HideOnlineAccountScreens` + `HideLocalAccountScreen`. `BypassNRO`
  queda como red de seguridad, no como mecanismo principal.
- **Porqué:** Microsoft viene cerrando `BypassNRO` desde 24H2. Una cuenta creada por unattend es
  determinista: el OOBE nunca llega a preguntar. No se hardcodea ningún secreto (password vacío;
  se pone una desde Settings al primer arranque).

## D16 — Edge se saca OFFLINE, no con su uninstaller

- **Contexto:** `SetupComplete.cmd` corría `setup.exe --uninstall --msedge --force-uninstall` y Edge seguía ahí.
- **Evidencia** (`C:\Windows\SystemTemp\msedge_installer.log`):
  ```
  Device region: <none>
  Stable: didn't check uninstall policy, or policy disabled
  Browser/WebView is sticky, uninstall not allowed.
  WARNING: Uninstall was blocked for this product: 93
  ```
  El script SÍ se ejecutó (lo confirma `windeploy.exe: RunUserProvidedScript`) y SÍ encontró el `setup.exe`.
  Fuera del EEA el uninstaller de Microsoft se niega. **Y hay un segundo muro**: a las `14:08:28` se
  bloqueó el uninstall de la 145.0.3800.97 y a las `14:09:46` EdgeUpdate instaló la 150.0.4078.105
  bajada de internet. Aunque el uninstall funcionara, Edge volvía.
- **Decisión:** fase 7 (`07-remove-edge.ps1`) borra offline `Program Files (x86)\Microsoft\Edge` y
  `\EdgeCore` (~1.6 GB) y aplica la policy `EdgeUpdate\Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}=0`.
- **Porqué:** que Edge nunca exista es más robusto que pelearse con un uninstaller que no coopera.
  Los tres árboles (`Edge`, `EdgeCore`, `EdgeWebView`) son **hardlinks al mismo contenido**, así que
  borrar los dos primeros deja WebView2 intacto. No hay paquete DISM del navegador que respalde esas
  carpetas (el único paquete Edge del WIM es `Microsoft-Edge-WebView-FOD-Package`), así que el
  component store no se corrompe.
- **Lo que NO se toca:** `EdgeWebView` (lo necesitan la Store y Widgets) y `EdgeUpdate` (es quien
  mantiene WebView2 parcheado). Por eso el bloqueo es por GUID de Edge Stable y no un `InstallDefault=0`.

## D19 — Región EEA temporal: sin eso, las policies de Edge son decorativas

- **Contexto:** con Edge borrado del WIM (D16) y la policy `Install{56EB18F8-...}=0` correctamente
  escrita en el registro, Edge **volvió igual**. La versión instalada era la `150.0.4078.105`, no la
  `145.0.3800.97` que borramos: se bajó de internet durante el OOBE.
- **Evidencia** (`C:\ProgramData\Microsoft\EdgeUpdate\Log\MicrosoftEdgeUpdate.log`):
  ```
  [IsEdgeUninstallablePerRegionalPolicy][0]
  [Edge not uninstallable per regional policy, skipping group policy]
  [ProcessAppUninstallPolicy(Edge) skipped]
  [Uninstall policy: Default]
  ...
  [CachedOmahaPolicy][is_managed][0] ... [install_default][-1][update_default][-1]
  ["...\MicrosoftEdgeUpdate.exe" /ua /installsource windowsupdate_zdp /critical]
  ```
  Tres cosas: (1) **EdgeUpdate saltea las group policies** cuando la región no permite desinstalar Edge;
  (2) su caché de policy quedó en `-1` (no configurado) pese a estar escritas en el registro — ni las
  leyó; (3) quien disparó la instalación fue **Windows Update** (`windowsupdate_zdp`).
- **Decisión (elegida por el usuario, variante temporal):** el equipo arranca con **GeoID 68 (Irlanda)**
  puesto en el hive `DEFAULT` y en `Users\Default\NTUSER.DAT` (fase 7) y en `HKU\.DEFAULT` (specialize).
  Con región EEA, `IsEdgeUninstallablePerRegionalPolicy` da 1, EdgeUpdate respeta la policy y Edge no se
  instala. `SetupComplete.cmd` deja un **RunOnce** que devuelve la región a **Argentina (11)** en el
  primer login.
- **La región NO afecta los formatos** de fecha/hora/moneda: eso lo fija `UserLocale=es-AR` en el
  `oobeSystem`, que es independiente. Lo que sí cambia mientras dura es el catálogo de la Store.
- **RIESGO ASUMIDO Y CONSCIENTE:** una vez restaurada la región a AR, EdgeUpdate vuelve a ignorar las
  policies. Un Windows Update futuro **podría** reinstalar Edge. No hay garantía; por eso se testea.
- **Plan B si Edge vuelve:** deshabilitar los servicios `edgeupdate` / `edgeupdatem`. Costo: WebView2
  deja de auto-actualizarse y hay que mantenerlo a mano
  (`winget upgrade Microsoft.EdgeWebView2Runtime`), que en un componente que renderiza web no es menor.
- **Lección:** una policy escrita no es una policy aplicada. Hay que verificar que el consumidor la
  haya leído, no que el registro la tenga.

## D22 — Servicios: 27 apagados + 25 documentados como opcionales

- **Decisión:** la lista activa (`$ServicesDisable`) llega a **27 servicios efectivamente apagados**.
  Los que dependen del hardware o del uso de cada uno van en `$ServicesOptional`, **desactivados**, cada
  uno con una línea que dice **qué perdés** si lo apagás.
- **Porqué opcionales y no activos:** apagar un servicio que otro necesita produce un error que **no dice
  por qué**. La regla es *"Manual > Disabled cuando dudes"*: en Manual no arranca solo, pero si algo lo
  pide lo puede levantar. Disabled es una puerta tapiada.
- **Las trampas que quedaron documentadas** (esto es el valor real de la lista, no los nombres):
  - `SSDPSRV` / `upnphost` → **NAT estricto en juegos**. Es el sospechoso número uno cuando el matchmaking
    empeora después de un debloat.
  - `SharedAccess` → lo usa el **Default Switch de Hyper-V**. Si virtualizás, dejalo.
  - `diagnosticshub.standardcollector.service` → lo usa el **profiler de Visual Studio**.
  - `WSearch` → te mata la búsqueda de archivos, justo lo que un dev usa todo el día.
  - `SysMain` → el clásico *"apagalo para gamear"*; en 25H2 con SSD puede **empeorar** los tiempos de carga.
  - `Spooler` → apagarlo cierra el vector de PrintNightmare, pero también mata *Imprimir a PDF*.
  - `MixedRealityOpenXRSvc` / `spectrum` → los necesitás si tenés visor VR.
- **`TrkWks` no se puede apagar:** el registro lo protege por ACL y da `Access is denied` incluso offline.
  Queda como viene. No es un fallo del pipeline.
- **Bug de robustez que esto destapó:** la fase 4 usaba `Invoke-Reg` (que lanza excepción tras 3 intentos),
  así que **un solo servicio protegido abortaba los otros 30**. `lib.ps1` ya tenía `Set-RegDword`, escrita
  justo para lotes tolerantes — la fase no la usaba. Ahora sí, y reporta al final qué quedó sin tocar.
- **Lección:** la herramienta correcta ya estaba escrita y documentada en la librería. El bug no fue de
  lógica sino de no leer lo que el propio proyecto ya había resuelto.

## D21 — Edge no se desinstala: se OCULTA y se BLOQUEA (el instalador es compartido)

- **Contexto:** tras D20 (matar los servicios de EdgeUpdate) Edge **volvió otra vez** en el test v5.
  Tercer intento fallido, y el que finalmente reveló la causa raíz.
- **LA EVIDENCIA QUE CIERRA EL CASO** (`MicrosoftEdgeUpdate.log` de la VM v5):
  ```
  [Installing][display name: Microsoft EdgeWebView]
  [installer path: ...\MicrosoftEdge_X64_150.0.4078.105.exe]
  [manifest args: --msedgewebview --do-not-launch-msedge --system-level]
  ```
  **El instalador es UNIFICADO.** El mismo binario instala WebView2 y Edge. Windows Update lo bajó
  para actualizar **WebView2** — que conservamos a propósito — y Edge vino adentro del paquete.
  En el mismo request pide los tres productos juntos: `msedgeupdate`, `msedge-stable`, `msedgewebview`.
- **Por qué el mecanismo de D20 no podía funcionar** (dos errores de razonamiento, no de código):
  1. Los servicios volvieron a `edgeupdate=0x2` y `edgeupdatem=0x3`: el instalador de EdgeUpdate se
     reinstala y **recrea sus propios servicios**, pisando nuestro `Start=4`.
  2. Windows Update invoca el **ejecutable** directo (`/installsource windowsupdate_zdp`), no el
     servicio. Deshabilitar el servicio nunca iba a impedirlo.
- **La consecuencia arquitectónica, que es lo importante:** *"WebView2 al día"* y *"Edge desinstalado"*
  son **objetivos incompatibles**. Son el mismo paquete. No hay término medio.
- **Decisión (propuesta por el usuario):** elegir la otra rama. Edge se queda en disco pero **no puede
  ejecutarse ni aparece en ningún lado**, y EdgeUpdate sigue **vivo** manteniendo WebView2 parchado.
  - **IFEO** (`Image File Execution Options`) con `Debugger = systray.exe` sobre `msedge.exe`,
    `msedge_proxy.exe` y `msedge_pwa_launcher.exe`. El kernel ejecuta el *Debugger* en lugar del
    binario: el proceso muere sin ventana ni error.
  - Accesos directos borrados (imagen + cada perfil) y `CreateDesktopShortcutDefault=0` para que el
    instalador no los recree.
  - Policies: `HideFirstRunExperience`, `PinBrowserToTaskbar=0`, `StartupBoostEnabled=0`,
    `BackgroundModeEnabled=0`.
- **Por qué esto sí resiste:** la clave de IFEO es por **nombre de ejecutable, no por ruta**. Da igual
  cuántas veces Windows Update reinstale Edge — el bloqueo sigue aplicando. Los intentos anteriores
  peleaban contra la *instalación*; este pelea contra la *ejecución*, que es terreno nuestro.
- **No cuesta disco:** `Edge`, `EdgeCore` y `EdgeWebView` son **hardlinks** al mismo contenido NTFS.
  Con WebView2 presente, Edge "de más" ocupa casi nada.
- **No rompe WebView2:** WebView2 corre `msedgewebview2.exe`, un ejecutable **distinto**. Por eso la
  lista de bloqueo es explícita y sin comodines.
- **VERIFICADO en VM (25H2):** Edge desapareció del escritorio y del menú Inicio, el widget del clima
  siguió funcionando (o sea WebView2 opera), y `msedge.exe` desde `Win+R` **no hace nada**.
- **Costo aceptado:** si algo del sistema intenta abrir un link con Edge, falla en silencio. Se pone
  Firefox/Chrome como predeterminado. **Ya NO hace falta mantener WebView2 a mano** (eso era D20).
- **Lección:** tres intentos atacaron el síntoma en la capa equivocada — la región, el servicio, el
  archivo. La pregunta correcta no era *"cómo bloqueo a EdgeUpdate"* sino *"quién trae a Edge y por qué"*,
  y la respuesta estaba en el **nombre del archivo del instalador**, visible en el log desde el primer día.

## D20 — La región EEA perdió contra el locale: Edge se frena matando EdgeUpdate

- **Contexto:** D19 apostó a arrancar con GeoID 68 (Irlanda) para que EdgeUpdate respetara la policy
  `Install{56EB18F8-...}=0`, y devolver la región a Argentina por RunOnce. **No funcionó.** En el test v4
  Edge 150.0.4078.105 se instaló igual.
- **Evidencia** (`MicrosoftEdgeUpdate.log` de la VM v4):
  ```
  [IsEdgeUninstallablePerRegionalPolicy][0]
  [CachedOmahaPolicy][is_managed][0] ... [install_default][-1][update_default][-1]
  ```
  Sigue en `0`: EdgeUpdate **nunca vio la región EEA**. Y el GeoID final en los tres hives era `11`.
- **El dato que cierra el caso:** la fase 7 había escrito `68` en `Users\Default\NTUSER.DAT`, y el
  `restore-region.ps1` del RunOnce **no tocaba ese hive** (solo `HKCU` y `HKU\.DEFAULT`). Terminó en `11`
  igual → **algo lo pisó durante el setup**, y ese algo es el propio `<UserLocale>es-AR</UserLocale>` del
  pass `oobeSystem`. El orden de passes juega en contra: nuestro `68` se aplica en `specialize`, el locale
  lo sobreescribe después, y todo eso pasa **antes** de que EdgeUpdate corra durante el OOBE.
- **Decisión:** se abandona la vía de la región. Edge se frena **matando EdgeUpdate** en la fase 7,
  offline: servicios `edgeupdate` + `edgeupdatem` a `Start=4`, tareas `MicrosoftEdgeUpdateTask*` borradas,
  `ClientState`/`Clients` de Edge Stable limpiados, y el refuerzo en caliente de `SetupComplete.cmd`.
  La región queda en **Argentina (11)** en todos los hives, sin trucos.
- **Porqué:** el vector real de la reinstalación era `MicrosoftEdgeUpdate.exe /ua /installsource
  windowsupdate_zdp`. Sin EdgeUpdate ejecutable, esa vía no existe — y no depende de que Microsoft
  decida honrar una policy. Se elimina el mecanismo, no se lo negocia.
- **COSTO REAL Y ASUMIDO:** EdgeUpdate es también quien actualiza **WebView2**, que queda clavado en la
  versión de la imagen. Es un componente que renderiza web, o sea superficie de ataque. **Hay que
  mantenerlo a mano**, cada tanto:
  ```powershell
  winget upgrade Microsoft.EdgeWebView2Runtime
  ```
  No es opcional: es la contrapartida de haber elegido este camino.
- **Lección:** perseguir la región era pelear en el terreno que elige Microsoft, con dos subsistemas
  (locale y GeoID) compitiendo por la misma clave. Sacar el ejecutable que hace el trabajo es una
  decisión que no se puede revertir desde el otro lado. Cuando una defensa depende de que el adversario
  coopere, no es una defensa.

## D18 — `RunSynchronous` va en `Microsoft-Windows-Deployment`, no en `Shell-Setup`

- **Contexto:** con el pass `windowsPE` ya arreglado, la segunda instalación abortó a mitad de camino con
  *"The computer restarted unexpectedly or encountered an unexpected error"*.
- **Evidencia** (`C:\Windows\Panther\setuperr.log`):
  ```
  [setup.exe] SMI data results dump: Source = Name: Microsoft-Windows-Shell-Setup, ... /settings/RunSynchronous
  [setup.exe] SMI data results dump: Description = Setting is not defined in this component.
  The provided unattend file is not valid; hrResult = 0x80220001
  Windows could not parse or process unattend answer file [C:\WINDOWS\Panther\unattend.xml] for pass [specialize].
  ```
- **Causa:** `RunSynchronous` no existe en el componente `Microsoft-Windows-Shell-Setup`. Pertenece a
  `Microsoft-Windows-Deployment`. Un setting en el componente equivocado **no se ignora**: invalida el
  archivo entero y aborta la instalación.
- **Detalle importante:** este error **ya estaba en el archivo original**. Nunca se manifestó porque el
  unattend se descartaba antes de leerse (D14). Al arreglar aquello, este salió a la luz. Dos defectos
  apilados: el de arriba escondía al de abajo.
- **Decisión:** la fase 8 valida la ubicación de los settings conocidos (`RunSynchronous`, `RunAsynchronous`,
  `UserAccounts`, `OOBE`, `UserData`) y aborta antes de buildear. La guarda se probó contra un XML con el
  error deliberado. Además se sacó el `RunSynchronousCommand` de BypassNRO: era redundante con
  `<UserAccounts>` y en 25H2 ya no hace nada. Menos comandos, menos superficie de falla.
- **Lección:** arreglar el bug de arriba destapa el de abajo. Después de cada fix hay que volver a probar
  de punta a punta, no asumir que el resto seguía sano.

## D17 — La ISO se arma con `efisys.bin` (CON prompt), y no es negociable

- **Contexto:** con `efisys.bin` el medio muestra *"Press any key to boot from CD or DVD"* y aborta con
  `The boot loader failed` si nadie aprieta una tecla en ~5 segundos. En la VM eso parecía una ISO rota
  (no lo era). Se probó cambiarlo por `efisys_noprompt.bin` para que arrancara solo.
- **Decisión:** **revertido.** Se queda `efisys.bin`, con prompt.
- **Porqué:** ese prompt no es un capricho de Microsoft — es el mecanismo que hace que los reinicios
  **intermedios** del setup no vuelvan a bootear del medio. Windows reinicia varias veces durante la
  instalación; sin el prompt, cada reinicio relanza el instalador desde cero. Loop infinito. Con prompt,
  nadie aprieta nada en los reinicios y arranca del disco, que es lo correcto.
- **Costo aceptado:** en el día D hay que apretar una tecla al bootear del USB. Una sola vez.
- **Lección:** la molestia visible (un prompt) estaba tapando una función invisible (romper el ciclo de
  arranque). Antes de sacar algo que "molesta", preguntarse para qué está.

## Fuentes viejas a portar (raíz de CodeByPittana)

`plan-debloat-completo.md` (10 fases, tabla anticheat), `01/02/03/04-*.md`, `debloat-master.ps1`,
`debloat.ps1`, `reinstalar-apps.ps1`. Todo post-install → hay que ADAPTAR a offline, no copiar tal cual.
