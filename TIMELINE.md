# ⏱️ Timeline del día D — orden de ejecución

> Cronología operativa del cambio de placa madre + instalación de LunaticOS.
> **Este documento es el orden. Los detalles del "por qué" están en `docs\`.**
>
> Armado el 2026-07-31, actualizado el 2026-08-01. Leelo entero **una vez** antes de
> empezar la Fase 2.

---

# ✅ CHECKLIST RÁPIDO

> Una pantalla. Cada línea linkea al detalle. **Si solo vas a mirar una cosa, mirá esto.**

### Ya está hecho — no lo repitas

- [x] 🔑 Licencia digital **vinculada a la cuenta Microsoft** → [Fase 0](#fase-0--️-pc-vieja--lo-que-ya-está-hecho-)
- [x] Discos etiquetados · mapa de particiones · carpetas redirigidas exportadas
- [x] BitLocker verificado — **no hay cifrado**, se pueden desconectar los discos
- [x] Respaldos en `E:\_migracion` — **37.243 archivos / 9,94 GB**
- [x] Navegadores respaldados · **Firefox Sync activo y al día**
- [x] Configs de apps + VS Code (39 extensiones)
- [x] **ISO regenerada** (7,44 GB) · en la notebook · hash verificado
- [x] **BIOS F13b + drivers** bajados · en la notebook · copia en `E:\_migracion\drivers-b560m`
- [x] 🔧 **Pendrive listo para flashear** — `BIOS-GB`, FAT32, `gigabyte.bin` en la raíz
- [x] Repo publicado en <https://github.com/Lunatico0/LunaticOS>

### Falta — en este orden

| # | Qué | Dónde | Detalle |
|:-:|---|---|---|
| 1 | ⚠️ **Robocopy final de Claude** (con Claude CERRADO) | 🖥️ PC-VIEJA | [Fase 1.3 bis](#13-bis-️-el-último-paso-antes-de-apagar--el-robocopy-de-claude) · [`docs/restaurar-claude.md`](docs/restaurar-claude.md) |
| 2 | Apagar · desconectar **D: y E:** · dejar solo el NVMe | 🔧 | [Fase 3](#fase-3--desarmar-y-montar-1-h) |
| 3 | Montar placa + CPU + RAM + **GPU** (el 11400F no tiene video) | 🔧 | [Fase 3](#fase-3--desarmar-y-montar-1-h) |
| 4 | **Flashear la BIOS** — `Del` → `F8` → Q-Flash | 🔧 | [Fase 4](#fase-4--placa-nueva--flashear-la-bios) · [`docs/bios-update.md`](docs/bios-update.md) |
| 5 | **Después** de flashear: Secure Boot + TPM + CSM off + AHCI | 🔧 | [Fase 5](#fase-5--placa-nueva--configurar-la-bios) |
| 6 | Grabar la ISO al pendrive con **Rufus** (no Ventoy) | 💻 NOTEBOOK | [Fase 6](#fase-6--notebook--grabar-la-iso-al-pendrive) |
| 7 | Instalar — `F12` → UEFI del pendrive | 🔧 | [Fase 7](#fase-7--placa-nueva--instalar-30-40-min) |
| 8 | Contraseña · drivers · activación | 🔧 | [Fase 8](#fase-8--primer-arranque-antes-de-reconectar-los-discos) |
| 9 | Reconectar discos · letras · carpetas · **restaurar Claude** | 🔧 | [Fase 9](#fase-9--reconectar-los-otros-discos-y-reordenar) · [`docs/restaurar-claude.md`](docs/restaurar-claude.md) |
| 10 | Verificación final · `winget import` · Valorant | 🔧 | [Fase 10](#fase-10--verificación-final-y-reinstalación) |

### Los tres números que vas a necesitar

```
SHA256 de la ISO   4E9DB8D7E14D7A57A89C2BEEDADDF4044B22BC68ED84D3E7D6609D3BED0BA451
BIOS a instalar    F13b  (11,58 MB · 2025/06/10 · checksum 1510)
Disco a formatear  NVMe WDC WDS480G2G0C · 447 GB · el UNICO conectado al instalar
```

### Si algo se rompe

| Problema | Ir a |
|---|---|
| La BIOS no ve el pendrive / Q-Flash Plus no titila | [`docs/bios-update.md`](docs/bios-update.md) — *Si algo sale mal* |
| La placa no postea, no da imagen | [Fase 4 camino B](#camino-b--la-placa-no-da-imagen-o-queda-en-bucle) |
| El instalador pide idioma o product key | El unattend no se aplicó → [`docs/dia-d.md`](docs/dia-d.md) |
| Valorant tira `VAN9001` | Secure Boot y/o TPM apagados → [Fase 5](#fase-5--placa-nueva--configurar-la-bios) |
| Windows no activa | [Fase 8](#fase-8--primer-arranque-antes-de-reconectar-los-discos) |
| Claude perdió skills / MCP / memoria | [`docs/restaurar-claude.md`](docs/restaurar-claude.md) |

### Mapa de documentos

| Archivo | Para qué |
|---|---|
| **`TIMELINE.md`** *(este)* | El orden. Empezá acá. |
| [`docs/bios-update.md`](docs/bios-update.md) | BIOS y pendrive: los tres caminos de flasheo y sus fallas |
| [`docs/dia-d-respaldo.md`](docs/dia-d-respaldo.md) | No perder nada: respaldos, licencia, reconectar discos |
| [`docs/dia-d.md`](docs/dia-d.md) | La instalación en sí y qué verificar |
| [`docs/restaurar-claude.md`](docs/restaurar-claude.md) | Dejar Claude como estaba: reglas, skills, MCP, memoria |
| [`PROXIMA-SESION.md`](PROXIMA-SESION.md) | Handoff autosuficiente — **leelo si abrís Claude en la notebook** |
| [`docs/decisiones.md`](docs/decisiones.md) | El "por qué" de cada decisión técnica del proyecto |

> 📌 **Nota para el futuro:** `TIMELINE.md`, `docs/bios-update.md`, `docs/dia-d-respaldo.md`
> y `docs/restaurar-claude.md` describen **este** hardware y **este** caso. A otra persona
> no le sirven igual. Cuando el día D termine, se borran — el resto del repo (el pipeline)
> es genérico y se queda.

---

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
- [x] **Configs de apps** — hecho: Macro Deck, SteelSeries, Razer, Figma, Discord,
      droidcam, codex y VS Code (`settings.json` + 39 extensiones) en
      `E:\_migracion\configs-apps`.
- [x] **Máquinas virtuales** — no hay nada que hacer: `LunaticOS-Test` y `Debloat-Test`
      viven en `E:\Workspace\...\work\`, o sea **en E:, que no se formatea**. Y son
      descartables.
- [x] **Navegadores** — Firefox Sync está **activo y al día**, así que los marcadores
      personales ya están en la nube. Igual se respaldaron los perfiles completos de
      Firefox y Chrome en `E:\_migracion\navegadores`.
      ⚠️ Las contraseñas de **Chrome** están cifradas con **DPAPI** (atadas al usuario y a
      la máquina): **no se van a poder descifrar** con el usuario nuevo. Las de Firefox sí,
      porque `logins.json` se descifra con `key4.db` y los dos se copiaron juntos.

### 1.3 bis ⚠️ EL ÚLTIMO PASO ANTES DE APAGAR — el robocopy de Claude

**Corrélo recién cuando no vayas a usar Claude más.** Detalle completo en
[`docs/restaurar-claude.md`](restaurar-claude.md).

1. Cerrá Claude Code del todo (ninguna ventana, ningún proceso).
2. Abrí **PowerShell** (no hace falta admin).
3. Pegá los tres comandos:

  ```powershell
  robocopy "$env:USERPROFILE\.claude" "E:\_migracion\claude\.claude" /E /R:1 /W:1 /NFL /NDL
  robocopy "$env:LOCALAPPDATA\engram" "E:\_migracion\claude\engram" /E /R:1 /W:1 /NFL /NDL
  Copy-Item "$env:USERPROFILE\.claude.json" "E:\_migracion\claude\claude.json" -Force
  ```

4. En el resumen, la columna **`Failed` tiene que decir 0**.

- [ ] Corrido con Claude **cerrado**, `Failed = 0`

**Qué hace:** copia tus reglas, skills, agents, plugins, configuración de MCP e historial.
Es **incremental** — solo lo que cambió, tarda segundos.

**Por qué va último:** `engram` es una base SQLite en **un solo archivo**. Copiarla con
Claude corriendo puede llevarse una copia a mitad de escritura: una base rota que parece
sana hasta que la abrís.

> ⚠️ **Son TRES rutas, no una.** `.claude.json` es un archivo **suelto**, hermano de la
> carpeta `.claude` — un robocopy de la carpeta **no lo agarra**. Ya nos pasó.

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
- [ ] **Restaurar Claude** — paso a paso en [`docs/restaurar-claude.md`](restaurar-claude.md),
      con la tabla de qué puede fallar y qué hacer. Con Claude Code **cerrado**:
  ```powershell
  robocopy "E:\_migracion\claude\.claude" "$env:USERPROFILE\.claude" /E /R:1 /W:1 /NFL /NDL
  robocopy "E:\_migracion\claude\engram" "$env:LOCALAPPDATA\engram" /E /R:1 /W:1 /NFL /NDL
  Copy-Item "E:\_migracion\claude\claude.json" "$env:USERPROFILE\.claude.json" -Force
  ```
      ⚠️ El usuario nuevo **no se llama `Administrator`**: los plugins guardan `installPath`
      absoluto y hay que reinstalar los que no carguen. El login de Claude se vuelve a pedir.

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
