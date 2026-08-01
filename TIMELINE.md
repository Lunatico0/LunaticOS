# ⏱️ Timeline del día D — orden de ejecución

> Cronología operativa del cambio de placa madre + instalación de LunaticOS.
> **Este documento es el orden. Los detalles del "por qué" están en `docs\`.**
>
> Armado el 2026-07-31. Leelo entero **una vez** antes de empezar la Fase 2.

## Leyenda — dónde se hace cada cosa

| Marca | Significa |
|---|---|
| 🖥️ **PC-VIEJA** | La máquina actual, todavía armada y andando. Después de la Fase 3 **ya no existe**. |
| 💻 **NOTEBOOK** | La notebook. Es la que graba la ISO al final. Tiene Claude. |
| 🔧 **PLACA-NUEVA** | La B560M AORUS ELITE ya montada, sin sistema operativo. |
| 🔴 | **Punto de no retorno.** Antes de cruzarlo, verificá que la fase anterior esté completa. |

---

## FASE 0 — 🖥️ PC-VIEJA · Lo que ya está hecho ✅

No hay nada que hacer acá. Está listado para que sepas de dónde venís.

- [x] Discos etiquetados (`DATOS-HDD`, `TRABAJO-SSD`) — paso 1.1
- [x] Mapa de discos y particiones guardado en `E:\_migracion` — paso 1.2
- [x] Carpetas redirigidas exportadas a `.reg` (como **referencia**, no para importar) — paso 1.3
- [x] BitLocker verificado: los tres discos `FullyDecrypted`, protección `Off` — paso 1.4
- [x] 🔑 **Licencia digital vinculada a la cuenta Microsoft** — paso 1.7
      *Verificado: Activation state `Active` + "linked to your Microsoft account".*
      **Este era el único paso con reloj corriendo. Ya está cerrado.**
- [x] Repo publicado en <https://github.com/Lunatico0/LunaticOS>
- [x] Respaldos automatizables corridos a `E:\_migracion`: `winget-export.json`,
      `programas-instalados.txt`, `autoruns-*.reg`, `.ssh`, `.gitconfig`,
      `claude\.claude`, `claude\engram`, `iso-sha256.txt`
- [x] **ISO regenerada** el 31/07 22:32 (la anterior no tenía el commit `4f51f02`).
- [x] **ISO en la notebook, hash verificado con `sha256sum` → OK.**
- [x] **BIOS F13b + drivers** (chipset ×3, audio, lan) bajados y también en la notebook.
      Copia local en `E:\_migracion\drivers-b560m` — 13 archivos verificados.
- [x] Carpetas de trabajo del pendrive salvadas en `E:\pendrive-backup`
      (`Artemisa.Presupuestador`, `Codigo Gestion Cubiertas`, `pasteleria`).
      Las 6 ISOs viejas se descartaron por decisión del usuario: son re-descargables.
- [x] 🔧 **PENDRIVE LISTO PARA FLASHEAR** — `F:` etiquetado `BIOS-GB`, **FAT32**, **una
      sola partición de 16 GB** (el resto sin asignar; Rufus recupera el disco entero
      después). En la raíz: `gigabyte.bin` + `B560MAORUSELITE.F13b` + `Efiflash.efi` +
      `EFI\BOOT\` para el camino por UEFI shell.

      > `Clear-Disk` falla con "Failed" aunque el proceso esté elevado. Se resuelve
      > quitando las letras de unidad primero y usando **`diskpart`** (`clean` →
      > `create partition primary size=16384` → `format fs=fat32 quick`).

---

## FASE 1 — 🖥️ PC-VIEJA · Lo que falta antes de desarmar

⚠️ **Todo esto necesita la PC vieja andando.** Una vez que la desarmes, no hay vuelta atrás.

### 1.1 Pasar la ISO a la notebook — EL PASO QUE NO SE PUEDE OLVIDAR

La ISO pesa **7,5 GB** y **no está en el repo** (`work/` y `*.iso` están en `.gitignore`).
Clonar el repo te da los scripts, **no la ISO**.

- [ ] Compartir por red la carpeta `work\` (o copiar por cable) y llevar
      `Win11_25H2_Pro_debloat.iso` a la 💻 NOTEBOOK.
- [ ] **Verificar el hash en la notebook.** El de origen ya está calculado — tamaño
      **7,44 GB**, y queda acá para que no dependas de `E:\_migracion\iso-sha256.txt`:

  ```
  4E9DB8D7E14D7A57A89C2BEEDADDF4044B22BC68ED84D3E7D6609D3BED0BA451
  ```

  > ISO **regenerada el 31/07 22:32**. La anterior era del 30/07 23:24 y le faltaba el
  > commit `4f51f02` (nombre de usuario elegible / lo pide el OOBE). Si ves el hash
  > `2A5F4574...` en algún lado, es de la ISO vieja: **está mal**.

  ```powershell
  (Get-FileHash "C:\ruta\donde\quedo\Win11_25H2_Pro_debloat.iso" -Algorithm SHA256).Hash
  ```
- [ ] ⚠️ **Los dos hashes tienen que ser IDÉNTICOS.** Una ISO que llegó cortada no se nota
      hasta la mitad de la instalación, con la PC vieja ya desarmada.

### 1.2 Llevar el contexto de trabajo a la notebook

- [ ] 💻 En la notebook: `git clone https://github.com/Lunatico0/LunaticOS.git`
- [ ] Copiar también `E:\_migracion\claude\` a la notebook si querés retomar con la memoria
      completa. Si no, **`PROXIMA-SESION.md` del repo es autosuficiente** — está escrito
      para eso.
- [ ] Abrir Claude **dentro de la carpeta del repo clonado**.

### 1.3 Cerrar los respaldos a mano

Lo automatizable ya corrió. Esto no se puede scriptear:

- [ ] **Marcadores del navegador** — exportar (o confirmar que la sincronización está al día).
- [ ] **Configs de apps que no sincronizan** y que usás en serio: Macro Deck, SteelSeries,
      Razer, Figma. Revisá `%APPDATA%` y `%LOCALAPPDATA%` de esas.
- [ ] **Máquinas virtuales en C:**, si tenés alguna que te importe. Las del proyecto
      (`LunaticOS-Test`, `Debloat-Test`) son descartables.
- [ ] ⚠️ **Repetir el robocopy de `.claude` y `engram` con Claude Code CERRADO.** Es
      incremental, tarda segundos. La copia hecha con Claude abierto puede tener archivos
      de sesión en uso e incompletos.
  ```powershell
  robocopy "$env:USERPROFILE\.claude" "E:\_migracion\claude\.claude" /E /R:1 /W:1 /NFL /NDL
  robocopy "$env:LOCALAPPDATA\engram" "E:\_migracion\claude\engram" /E /R:1 /W:1 /NFL /NDL
  ```
- [ ] ⚠️ `.claude\.credentials.json` viene ahí adentro: **tratalo como una contraseña.**

### 1.4 Vaciar el pendrive

- [ ] Copiar todo lo del pendrive a `E:\pendrive-backup`:
  ```powershell
  New-Item -ItemType Directory -Force -Path "E:\pendrive-backup" | Out-Null
  robocopy "F:\" "E:\pendrive-backup" /E /R:1 /W:1 /NFL /NDL /XD "System Volume Information"
  ```
- [ ] **Verificarlo con los ojos.** El formateo que viene no se deshace.

### 1.5 Último chequeo antes de apagar

- [ ] Todo el respaldo está en **E: o D:**, no en C:. Miralo.
- [ ] La ISO **ya en la notebook y con hash verificado**.
- [ ] Anotá **en papel**: *el NVMe (WDC, 447 GB) es el que se formatea.*
- [ ] Tené a mano en la notebook los **drivers de chipset y LAN** de la B560M AORUS ELITE.
      Si Windows no trae el driver de red, quedás sin internet y sin poder bajarlo.

---

## FASE 2 — 🖥️ PC-VIEJA · Preparar el pendrive para la BIOS

Referencia completa: **`docs\bios-update.md`**.

- [ ] Bajar la **última BIOS** de la página oficial y **anotar la versión**:
      <https://www.gigabyte.com/Motherboard/B560M-AORUS-ELITE-rev-1x/support>
- [ ] ⚠️ Leer las notas de las versiones intermedias: Gigabyte a veces exige una versión
      puente antes de saltar a la última.
- [ ] **Descomprimir el `.zip`.** Q-Flash no abre comprimidos.
- [ ] Formatear el pendrive en **FAT32, UNA sola partición**.
      ⚠️ Windows **no ofrece FAT32 arriba de 32 GB**. El pendrive es de 58,7 GB, así que:
      **Rufus → dispositivo → "Non bootable" → FAT32.** *(Una sola operación, recomendado.)*
- [ ] Copiar el `.bin` a la **raíz** y **renombrarlo `gigabyte.bin`**.
      Dejá al lado una copia con el nombre original.
- [ ] **Nada más en el pendrive.** Ni ISO, ni Ventoy, ni carpetas.

> Renombrarlo a `gigabyte.bin` sirve para **los dos caminos** de flasheo: Q-Flash normal
> deja elegir el archivo de una lista, y Q-Flash Plus lo exige con ese nombre exacto.

---

## 🔴 PUNTO DE NO RETORNO

**No cruces esta línea si no está tildado todo lo de arriba.** Después de acá la PC vieja
no existe más y el único camino es hacia adelante.

Repasá las tres que duelen:
1. ✅ ¿La licencia está vinculada? *(sí, ya verificado)*
2. ¿La ISO está **en la notebook** y el hash **coincide**?
3. ¿El respaldo está en **E: o D:**, y lo viste con tus ojos?

---

## FASE 3 — 🔧 Desarmar y montar (~1 h)

- [ ] Apagar, **cortar la corriente de la fuente** y esperar.
- [ ] **Desconectar físicamente** el HDD Toshiba (D:) y el SSD Kingston (E:).
      Dejar conectado **solo el NVMe WDC**.
      *Así, al instalar, ves un solo disco: es imposible equivocarse.*
- [ ] Montar la placa nueva: CPU **i5-11400F**, RAM, y **la GPU discreta**.
      ⚠️ El 11400F **no tiene video integrado**: sin GPU no hay imagen ni para entrar a la BIOS.
- [ ] **Monitor conectado a la GPU**, no a las salidas de la placa.

---

## FASE 4 — 🔧 PLACA-NUEVA · Flashear la BIOS

⚠️ **Que no se corte la luz.** Si tenés UPS, enchufá la PC ahí. Un corte a mitad de
flasheo brickea la placa: es lo único verdaderamente irreversible del día.

### Camino A — la placa da imagen *(lo más probable)*

El chipset B560 salió junto con Rocket Lake, así que lo esperable es que postee de fábrica.

- [ ] Entrar al setup con `Del` → **Q-Flash** (`F8` o desde el menú).
- [ ] Elegir el archivo del pendrive → confirmar.
- [ ] **No tocar nada** hasta que reinicie solo.

### Camino B — la placa NO da imagen, o queda en bucle

Es BIOS demasiado vieja para el 11400F. Para esto existe Q-Flash Plus.

- [ ] Conectar **solo la fuente**. No hace falta CPU, ni RAM, ni GPU.
- [ ] Pendrive en el **puerto USB del panel trasero marcado para Q-Flash Plus**
      (es uno específico — está identificado en el manual).
- [ ] Apretar el **botón Q-Flash Plus**. La luz empieza a titilar: está flasheando.
- [ ] **Terminó cuando la luz deja de titilar.** Puede tardar varios minutos.
      **No apagues, no desenchufes, no aprietes de nuevo.**

### Verificar

- [ ] La pantalla principal de la BIOS muestra la **versión nueva**.
- [ ] Reconoce el **i5-11400F** por nombre y **toda** la RAM.

---

## FASE 5 — 🔧 PLACA-NUEVA · Configurar la BIOS

⚠️ **En este orden y no al revés: flashear resetea la BIOS a defaults.** Si configurás
antes de flashear, perdés todo y no te vas a acordar qué tocaste.

Detalle en `docs\dia-d.md` sección 3.

- [ ] **Secure Boot: ENABLED** (en Windows UEFI mode, no "Other OS" ni Setup Mode).
- [ ] **TPM 2.0: ENABLED** → en Intel se llama **Intel PTT**.
- [ ] ⚠️ **Estos dos son innegociables** (regla de oro **D5**): Vanguard los exige. Sin
      ellos Valorant tira `VAN9001` y no abre.
- [ ] **CSM: DISABLED** (boot UEFI puro).
- [ ] Modo del disco: **AHCI** (no RAID).
- [ ] Guardar y salir con `F10`.

---

## FASE 6 — 💻 NOTEBOOK · Grabar la ISO al pendrive

- [ ] **Rufus** → la ISO → esquema **GPT** · sistema destino **UEFI (no CSM)**.
- [ ] ⚠️ **Rufus, no Ventoy.** Rufus es la opción **probada** de este proyecto. Ventoy monta
      la ISO como disco virtual y puede no exponer el `autounattend.xml` en la raíz del
      medio. Ver `docs\dia-d.md` sección 2.
- [ ] ⚠️ El `install.wim` pesa más de 4 GB: Rufus lo parte solo o formatea NTFS.
      **Dejalo hacer lo suyo — no lo fuerces a FAT32 a mano.**
- [ ] ⚠️ Rufus ofrece "customizar" la instalación (saltear cuenta MS, quitar requisitos).
      **Rechazá TODO.** Inyecta su propio unattend y **pisa el nuestro**, que ya hace eso
      y está probado.

---

## FASE 7 — 🔧 PLACA-NUEVA · Instalar (~30-40 min)

- [ ] `F12` al arrancar → boot menu → la entrada **UEFI** del pendrive.
- [ ] ⚠️ **Apretá una tecla** cuando diga *"Press any key to boot from CD or DVD"*.
      Tenés unos 5 segundos.
- [ ] ⚠️ **En los reinicios siguientes NO toques ninguna tecla.** Windows reinicia varias
      veces durante la instalación; si volvés a bootear del USB, empieza de cero.
- [ ] En *"Select location to install Windows"* vas a ver **un solo disco** (por eso se
      desconectaron los otros). Elegí la partición a mano.
      ⚠️ **El particionado no está automatizado a propósito.**
- [ ] Si aparece un cartel **`OOBEZDP`** (*"Something went wrong"*): apretá **Skip**.
      Es el parche de día cero del OOBE y no afecta nada.
- [ ] **No debería preguntar** idioma, teclado, product key, EULA, edición, cuenta
      Microsoft ni red. Si pregunta alguna de esas, el unattend no se aplicó → ver
      `docs\dia-d.md`, sección *"Si algo sale mal"*.
- [ ] Dejar que termine solo. Cuenta local, teclado ES, tema oscuro y acento ya vienen
      aplicados.

---

## FASE 8 — 🔧 Primer arranque, antes de reconectar los discos

- [ ] 🔑 **Poné una contraseña YA.** El usuario nace **sin password a propósito** (no se
      hardcodea un secreto en una ISO). `Settings → Accounts → Sign-in options`.
- [ ] **Instalar drivers primero**, con los otros discos todavía desconectados:
      chipset y LAN de Gigabyte, y el driver de la GPU.
- [ ] Verificar que hay **red**. Si no hay ni Ethernet ni Wi-Fi, instalá el driver que
      bajaste en la Fase 1.5.
- [ ] **Activación:** debería activarse solo. Si no:
      `Settings → System → Activation → Solucionar problemas → Cambié el hardware de este
      dispositivo recientemente` → iniciar sesión con **la cuenta Microsoft a la que
      vinculaste la licencia** → elegir esta PC.
- [ ] Verificar Secure Boot y TPM **desde el SO**, no desde la BIOS:
  ```powershell
  Confirm-SecureBootUEFI
  (Get-Tpm).TpmPresent
  (Get-Tpm).TpmReady
  ```
  Esperado: `True` / `True` / `True`.

---

## FASE 9 — 🔧 Reconectar los otros discos y reordenar

Detalle en `docs\dia-d-respaldo.md` PARTE 3.

- [ ] Apagar, reconectar el HDD Toshiba y el SSD Kingston.
- [ ] **Reasignar las letras** (acá sirven las etiquetas del paso 1.1):
      `DATOS-HDD` → **D:**, `TRABAJO-SSD` → **E:**.
      Si la letra está ocupada, liberala primero (`remove letter=X`).
- [ ] Verificar que los datos están: `D:\Desktop`, `D:\Documents`, `D:\Downloads`,
      `D:\Music`, `D:\Pictures`, `D:\Videos`.
- [ ] **Redirigir las carpetas del perfil por la INTERFAZ**, no por registro.
      *(El registro es lo que rompe los permisos.)* Orden sugerido: Documents, Downloads,
      Desktop, Pictures, Music, Videos. Cuando pregunte si mover los archivos: **sí**.
- [ ] ⚠️ **NO importes los `.reg` exportados.** El usuario nuevo se llama distinto y las
      rutas de AppData no coinciden. Son **referencia** para rehacerlo a mano.
- [ ] **Restaurar Claude** con Claude Code **cerrado**: copiar de vuelta `.claude` y
      `engram` desde `E:\_migracion\claude\`.
      ⚠️ El usuario nuevo **no se llama `Administrator`**: si algo adentro tiene rutas
      absolutas al perfil viejo, hay que ajustarlo.

---

## FASE 10 — Verificación final y reinstalación

- [ ] Correr la checklist de `docs\dia-d.md` sección 6 (formatos es-AR, teclado ES LatAm,
      Edge bloqueado, **WebView2 presente**, **EdgeUpdate vivo**, sin OneDrive/Copilot).
- [ ] **Poné Firefox/Chrome como predeterminado** (`Settings → Apps → Default apps`).
      Con Edge bloqueado, sin esto ningún link abre.
- [ ] Región en **Argentina**: `Get-WinHomeLocation`.
- [ ] Restaurar el stack: `winget import "E:\_migracion\winget-export.json"`.
      **No repongas lo que no usabas.**
- [ ] Instalar VALORANT + FACEIT + Steam y **confirmar que ARRANCAN**.
- [ ] Revisar `$ServicesOptional` en `scripts\config.ps1` si te falta algo (impresora,
      Bluetooth, VR).

---

## Cuánto tarda cada cosa (estimado)

| Fase | Tiempo | Necesita |
|---|---|---|
| 1 — Pasar ISO + respaldos a mano | 30-60 min | 🖥️ PC-VIEJA + red |
| 2 — Pendrive FAT32 + BIOS | 15 min | 🖥️ PC-VIEJA + internet |
| 3 — Desarmar y montar | ~1 h | Destornillador y paciencia |
| 4 — Flashear | 5-15 min | **Corriente estable** |
| 5 — Configurar BIOS | 10 min | — |
| 6 — Rufus | 10-15 min | 💻 NOTEBOOK |
| 7 — Instalar | 30-40 min | — |
| 8 — Drivers + activación | 30 min | Red |
| 9 — Reconectar y reordenar | 30-45 min | — |
| 10 — Verificar y reinstalar | Lo que quieras | Red |

## Si algo sale mal

| Qué pasó | Dónde mirar |
|---|---|
| Q-Flash no ve el pendrive | Está en NTFS o exFAT → tiene que ser **FAT32**. `docs\bios-update.md` |
| Q-Flash Plus no titila | Puerto equivocado, no está renombrado `gigabyte.bin`, o hay más de una partición |
| La placa no da imagen tras flashear | Limpiar CMOS (jumper o quitar la pila) y reintentar |
| El unattend no se aplicó | `C:\Windows\Panther\setupact.log` — buscá `UnattendSearch` |
| La instalación abortó a mitad | `C:\Windows\Panther\setuperr.log` |
| Edge volvió | `C:\ProgramData\Microsoft\EdgeUpdate\Log\MicrosoftEdgeUpdate.log` |
| Valorant tira `VAN9001` | Secure Boot y/o TPM apagados → Fase 5 |
| No activa Windows | Fase 8, con la cuenta Microsoft correcta |
