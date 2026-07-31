# Dia D — respaldo y reinstalacion de C:

> Tu caso concreto, relevado el 2026-07-31. **No es una guia genérica.**
> Plan: desconectar fisicamente D: y E:, formatear e instalar solo en el NVMe (C:),
> reconectar los otros dos y que todo vuelva a funcionar como estaba.
>
> Checklist de la instalacion en si: `docs\dia-d.md`. Este documento es sobre **no
> perder nada**.

## Tu hardware, como esta hoy

| Letra | Disco | Modelo | Tamano | Tabla | Que tiene |
|---|---|---|---|---|---|
| **C:** | disco 2 | WDC WDS480G2G0C (NVMe) | 447 GB | **GPT** | Windows. **ES EL QUE SE FORMATEA** |
| **D:** | disco 1 | TOSHIBA MQ01ABD100 (HDD) | 932 GB | MBR | Desktop, Documents, Downloads, Music, Pictures, Videos, SteamLibrary, Riot |
| **E:** | disco 0 | KINGSTON SA400S37240G (SSD) | 224 GB | MBR | `E:\Workspace` — tu trabajo |

**Ojo con esto:** tu perfil tiene 6 carpetas redirigidas a D: y **ninguno de los tres
discos tiene etiqueta** (solo E: dice "Local Disk"). Los dos puntos importan mas abajo.

---

## PARTE 1 — Antes de apagar

### 1.1 Etiquetar los discos (hacelo PRIMERO, es lo que evita el peor lio)

Sin etiqueta, cuando reconectes los discos y las letras cambien, no vas a tener forma
rapida de saber cual es cual. Con etiqueta lo ves de un vistazo en el Explorador.

- [x] Correr en PowerShell **como Administrador**:
  ```powershell
  Set-Volume -DriveLetter D -NewFileSystemLabel "DATOS-HDD"
  Set-Volume -DriveLetter E -NewFileSystemLabel "TRABAJO-SSD"
  ```

### 1.2 Anotar el mapa de discos y particiones

- [x] Guardar la foto del estado actual **en D: o E:**, no en C::
  ```powershell
  New-Item -ItemType Directory -Force -Path "E:\_migracion" | Out-Null
  Get-Disk | Format-List > "E:\_migracion\discos.txt"
  Get-Partition | Format-List >> "E:\_migracion\discos.txt"
  Get-Volume | Format-List >> "E:\_migracion\discos.txt"
  ```

### 1.3 Guardar la configuracion de las carpetas redirigidas

Estas 6 carpetas de tu perfil apuntan a D:. Al formatear C: se pierde **la
redireccion**, no los archivos:

```
Desktop    -> D:\Desktop          Documents -> D:\Documents
Downloads  -> D:\Downloads        Music     -> D:\Music
Pictures   -> D:\Pictures         Videos    -> D:\Videos
```

- [x] Exportar las dos claves que las definen:
  ```powershell
  reg export "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" "E:\_migracion\user-shell-folders.reg" /y
  reg export "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" "E:\_migracion\shell-folders.reg" /y
  ```
- [x] **NO importes esos .reg despues sin leerlos.** El usuario nuevo puede llamarse
      distinto y las rutas de AppData no van a coincidir. Sirven como **referencia**
      para rehacer la redireccion a mano (paso 3.3).

### 1.4 BitLocker — YA VERIFICADO, no tenes que hacer nada

Medido el 2026-07-31: los tres discos estan `FullyDecrypted` con proteccion `Off`.
**No hay cifrado**, asi que podes desconectar D: y E: sin riesgo de no poder leerlos
despues.

Si en algun momento activas BitLocker, volvé a chequear esto antes de desconectar
nada:
```powershell
Get-BitLockerVolume | Select-Object MountPoint, VolumeStatus, ProtectionStatus
```

### 1.5 Respaldar lo de Claude (tu memoria de trabajo)

Son dos carpetas, y las dos estan en C::

- [ ] **`C:\Users\Administrator\.claude`** (782 MB) — configuracion, `CLAUDE.md`,
      skills, agents, plugins, sesiones e historial.
- [ ] **`C:\Users\Administrator\AppData\Local\engram`** — **la memoria persistente
      del proyecto.** Es lo que hace que yo vuelva sabiendo lo que hicimos. Sin esto
      arranco de cero.
  ```powershell
  robocopy "$env:USERPROFILE\.claude" "E:\_migracion\claude\.claude" /E /R:1 /W:1 /NFL /NDL
  robocopy "$env:LOCALAPPDATA\engram" "E:\_migracion\claude\engram" /E /R:1 /W:1 /NFL /NDL
  ```
- [ ] `.claude\.credentials.json` viene ahi adentro: **tratalo como una contrasena.**
      No lo subas a ningun repo.

### 1.6 Respaldar el resto de lo que vive en C:

Tu `AppData` pesa **88 GB**. No lo copies entero: la mayor parte es cache que se
regenera. Lo que si conviene:

- [ ] **Navegadores** — exportar marcadores desde el navegador (y si usas cuenta, con
      sincronizar alcanza).
- [ ] **Claves SSH / GPG y configs de git**:
  ```powershell
  robocopy "$env:USERPROFILE\.ssh"    "E:\_migracion\perfil\.ssh"    /E /NFL /NDL
  Copy-Item "$env:USERPROFILE\.gitconfig" "E:\_migracion\perfil\" -ErrorAction SilentlyContinue
  ```
- [ ] **Lista de lo instalado**, para reinstalar rapido despues:
  ```powershell
  winget list > "E:\_migracion\programas-instalados.txt"
  winget export -o "E:\_migracion\winget-export.json" --include-versions
  ```
- [ ] **Lo que arranca solo** (para no volver a llenarlo de porqueria):
  ```powershell
  reg export "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" "E:\_migracion\autoruns-hkcu.reg" /y
  reg export "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" "E:\_migracion\autoruns-hklm.reg" /y
  ```
- [ ] **Configs de apps que no sincronizan** y que uses en serio: revisa a mano
      `%APPDATA%` y `%LOCALAPPDATA%` de las que te importen (Macro Deck, SteelSeries,
      Razer, Figma, etc.).
- [ ] Si tenes **maquinas virtuales** en C:, acordate de que estan ahi. Las de este
      proyecto (`LunaticOS-Test`, `Debloat-Test`) son descartables.

### 1.7 Licencia de Windows — EL PASO MAS URGENTE, y hay que hacerlo HOY

**Confirmaste que vas a cambiar la placa.** Eso cambia todo lo de la licencia.

Tu Windows es **Retail, activado, con licencia digital**. La clave que tiene puesta es
la generica publica: **lo que activa es el hardware, no la clave.** Y al cambiar la
placa, ese hardware deja de existir.

> **Cambiar la placa DESVINCULA la licencia digital.** Si no la vinculas a una cuenta
> Microsoft ANTES, del otro lado no hay nada que recuperar: te queda pelearla con
> soporte, y hay casos reales que terminan comprando una licencia nueva.
>
> **Esto se hace mientras esta maquina TODAVIA arranca y esta activada.** Despues del
> cambio ya es tarde.

- [ ] **HOY, antes de tocar la placa:** `Configuracion > Cuentas > Tu informacion >
      Iniciar sesion con una cuenta Microsoft en su lugar`.
- [ ] Verificar que quedo vinculada: `Configuracion > Sistema > Activacion` tiene que
      decir **"Windows esta activado con una licencia digital vinculada a su cuenta
      Microsoft"**. Si dice solo "licencia digital" **sin** la parte de la cuenta,
      **no esta vinculada todavia.**
- [ ] Anotar con que cuenta Microsoft la vinculaste. Sin esa cuenta el vinculo no sirve.
- [ ] **Despues del cambio de placa**, si no activa solo: `Configuracion > Sistema >
      Activacion > Solucionar problemas > Cambie el hardware de este dispositivo
      recientemente` → iniciar sesion → elegir esta PC.
- [ ] **No pongas nada en `clave-windows.txt`** de LunaticOS: no tenes una clave propia
      que poner, y la generica ya esta por defecto.

Si preferis volver a cuenta local despues de instalar, se puede: el vinculo de la
licencia queda hecho igual. Primero vincula, despues decidis como te logueas.

### 1.8 Ultimo chequeo antes de apagar

- [ ] Que el respaldo este **en E: o D:**, no en C:. Verificalo con los ojos.
- [ ] La ISO de LunaticOS grabada en el pendrive con **Ventoy** (copiar el `.iso`).
- [ ] Anotá en papel: **el NVMe (WDC, 447 GB) es el que se formatea.**

---

## PARTE 2 — Instalacion

- [ ] Apagar y **desconectar fisicamente** el HDD Toshiba (D:) y el SSD Kingston (E:).
- [ ] Dejar conectado **solo el NVMe WDC**.
- [ ] BIOS: **Secure Boot ON + TPM 2.0 ON** (sin esto Vanguard tira VAN9001 y Valorant
      no abre).
- [ ] Bootear el pendrive e instalar. En "Select location to install Windows" vas a ver
      **un solo disco**: por eso se desconectan los otros — es imposible equivocarse.
- [ ] Si aparece un cartel **`OOBEZDP`** ("Something went wrong"): apretá **Skip**. Es
      el parche de dia cero del OOBE y no afecta nada.
- [ ] Dejar que termine solo (cuenta local `pato`, teclado ES, tema oscuro + acento
      teal ya vienen aplicados).
- [ ] **Antes de reconectar los otros discos**, instalá los drivers: chipset y LAN de
      Gigabyte, y AMD Adrenalin para la RX 9060 XT.

---

## PARTE 3 — Despues de instalar: reconectar y reordenar

### 3.1 Reconectar y arreglar las letras

Apagá, conectá los otros dos discos y arrancá. **Las letras casi seguro no van a
coincidir**: en la instalacion nueva Windows las asigna por orden de deteccion, y tu
Kingston era el disco 0.

- [ ] Ver que letra tomo cada uno (aca sirven las etiquetas del paso 1.1):
  ```powershell
  Get-Volume | Where-Object DriveLetter | Select-Object DriveLetter, FileSystemLabel, Size
  ```
- [ ] Reasignar a mano, con `diskpart` o desde *Administracion de discos*:
  ```
  diskpart
    list volume
    select volume <n>            REM el que dice DATOS-HDD
    assign letter=D
    select volume <n>            REM el que dice TRABAJO-SSD
    assign letter=E
    exit
  ```
- [ ] **Si la letra esta ocupada**, liberala primero (`remove letter=X`) y despues
      asignala. El orden importa.

### 3.2 Verificar que los datos esten

- [ ] `D:\Desktop`, `D:\Documents`, `D:\Downloads`, `D:\Music`, `D:\Pictures`,
      `D:\Videos`, `D:\SteamLibrary` y `E:\Workspace` tienen que estar intactos.

### 3.3 Volver a redirigir las carpetas del perfil

Windows nuevo va a tener `Desktop`, `Documents`, etc. en `C:\Users\pato\`. Hay que
apuntarlas de vuelta a D:.

- [ ] **Hacelo por la interfaz, no por registro** (el registro es lo que rompe los
      iconos y el acceso rapido): por cada una de las 6 carpetas, click derecho en
      `C:\Users\pato\<Carpeta>` → **Propiedades → Ubicacion → Mover** → elegir
      `D:\<Carpeta>`.
- [ ] Cuando pregunte si mover los archivos, decí **que si** (el destino ya tiene los
      tuyos; los de la carpeta nueva estan vacios).
- [ ] Orden sugerido: Documents, Downloads, Desktop, Pictures, Music, Videos.
      Dejá **Desktop para el final**: mientras lo movés, el escritorio parpadea.
- [ ] Referencia de como estaba: `E:\_migracion\user-shell-folders.reg` (abrilo con el
      Notepad, **no lo importes**).

### 3.4 Restaurar Claude

- [ ] Copiar de vuelta las dos carpetas, **con Claude Code cerrado**:
  ```powershell
  robocopy "E:\_migracion\claude\.claude" "$env:USERPROFILE\.claude" /E /R:1 /W:1 /NFL /NDL
  robocopy "E:\_migracion\claude\engram" "$env:LOCALAPPDATA\engram" /E /R:1 /W:1 /NFL /NDL
  ```
- [ ] Abrir Claude Code **dentro de `E:\Workspace\CodeByPittana\win11-debloat-iso`** y
      pedirle que recupere memoria. Si engram volvio bien, tiene que saber de los
      cuatro bugs del tema, del E2E y de todo lo de estas dos sesiones.
- [ ] Ojo: el usuario nuevo se llama **`pato`**, no `Administrator`. Si algo dentro de
      `.claude` guardo rutas absolutas con el usuario viejo, hay que corregirlo.

### 3.5 Reinstalar programas

- [ ] Los que estan en D: (Steam, Riot/Valorant, Macro Deck, WizTree, CrystalMark,
      TapMap) **tienen los archivos pero perdieron el registro**. En general:
  - **Steam**: instalalo en C: y despues *Agregar biblioteca* → `D:\SteamLibrary`.
    No hay que volver a descargar los juegos.
  - **Valorant / Riot**: reinstalar el cliente. Vanguard necesita instalarse de nuevo.
  - El resto: reinstalar sobre la misma carpeta suele alcanzar.
- [ ] Restaurar el stack con `winget import "E:\_migracion\winget-export.json"`, o a
      mano desde `programas-instalados.txt`.
- [ ] **No repongas lo que no usabas.** De tus 7 programas de arranque, `Gyazo` y
      `AMDNoiseSuppression` ya los sacamos y no los extranaste.

### 3.6 Verificacion final

- [ ] Activacion: `Configuracion > Sistema > Activacion` dice **Activado**.
      Recien ahi Settings > Personalizacion deja de estar en gris.
- [ ] Tema oscuro y acento teal aplicados, y **podes cambiarlos** desde Settings.
- [ ] Sin el cartel *"Algunas configuraciones estan administradas por tu organizacion"*.
- [ ] Las 6 carpetas del perfil apuntan a D:, y el escritorio tiene tus cosas.
- [ ] Valorant y FACEIT **arrancan** (es la prueba de que Secure Boot y TPM quedaron bien).
- [ ] Medí el consumo en reposo y comparalo con lo de hoy:
      `Ghost Spectre: 18550 MB / 20,9% CPU  ·  LunaticOS en VM: 1888 MB / 0,9% CPU`.

---

## Lo que se pierde igual, y esta bien

- Historial y cache de navegadores que no sincronicen.
- Licencias de apps atadas a la instalacion (hay que reactivarlas).
- Los 88 GB de `AppData`: en su mayoria cache que se regenera sola.
- Cualquier cosa que hayas dejado en `C:\` fuera del perfil.

### Las carpetas sueltas que TENES hoy en la raiz de C:

Relevadas el 2026-07-31. Revisalas una por una antes de formatear:

| Carpeta | Que hacer |
|---|---|
| `C:\XboxGames` | **REVISAR.** Juegos instalados en C:. Si hay partidas guardadas locales, respaldalas |
| `C:\Tools` | **REVISAR.** Suena a herramientas tuyas |
| `C:\Ghost Toolbox` | **REVISAR.** Es del Ghost Spectre. Si tiene algo que quieras conservar, copialo |
| `C:\PCMonitor` | Revisar si lo usas |
| `C:\.cache` | Cache, se regenera |
| `C:\AMD`, `C:\symcache`, `C:\CrashForensics` | Cache de drivers y volcados. Se van |
| `C:\inetpub` | IIS. Si no lo usas, se va |
| `C:\Documents and Settings` | Junction vieja de compatibilidad. Se va |

- [ ] Comando para ver cual pesa y vale la pena:
  ```powershell
  foreach ($d in 'XboxGames','Tools','Ghost Toolbox','PCMonitor') {
    $p = "C:\$d"
    if (Test-Path $p) {
      $gb = [math]::Round((Get-ChildItem $p -Recurse -File -Force -EA SilentlyContinue |
             Measure-Object Length -Sum).Sum / 1GB, 2)
      Write-Output ("{0,-16} {1} GB" -f $d, $gb)
    }
  }
  ```
