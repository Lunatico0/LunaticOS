# Contrato de personalizacion de LunaticOS

> Este documento es la FUENTE DE VERDAD para todo lo que toque tema, color, wallpaper
> y para todo lo que pueda bloquear Settings. Fue escrito despues de medir en una
> maquina real y de leer el codigo de los proyectos que ya resolvieron esto
> (cschneegans/unattend-generator, AutoDarkMode, gists de AveYo y GuyPaddock,
> foros de NTLite y elevenforum).
>
> Si vas a modificar personalizacion: leelo entero ANTES. Las decisiones de aca no
> son estilisticas, cada una arregla un bug que llego al usuario.

## 0. El objetivo, en una linea

Windows arranca lindo y **QUEDA TUYO**: todo se aplica como *default* o como *tema*,
nunca como *policy*. El usuario cambia lo que quiera desde Settings.

---

## 1. Formato de bytes de los colores (BUG REAL, medido)

Dos valores de la MISMA clave del registro usan formatos DISTINTOS. Escribir ARGB
en todos hacia que el acento saliera de otro color y que partes de la UI tomaran
colores diferentes entre si.

Para un color `#RRGGBB`:

| Valor de registro | Formato | DWORD | Ejemplo `#14B8A6` |
|---|---|---|---|
| `HKCU\Software\Microsoft\Windows\DWM\AccentColor` | **ABGR** | `0xFFBBGGRR` | `0xFFA6B814` |
| `HKCU\Software\Microsoft\Windows\DWM\AccentColorInactive` | **ABGR** | `0xFFBBGGRR` | `0xFFA6B814` |
| `HKCU\...\Explorer\Accent\AccentColorMenu` | **ABGR** | `0xFFBBGGRR` | `0xFFA6B814` |
| `HKCU\...\Explorer\Accent\StartColorMenu` | **ABGR** | `0xFFBBGGRR` | `0xFFA6B814` |
| `HKCU\Software\Microsoft\Windows\DWM\ColorizationColor` | **ARGB** | `0xC4RRGGBB` | `0xC414B8A6` |
| `HKCU\Software\Microsoft\Windows\DWM\ColorizationAfterglow` | **ARGB** | `0xC4RRGGBB` | `0xC414B8A6` |
| `.theme` -> `[VisualStyles] ColorizationColor` | **ARGB** | `0XC4RRGGBB` | `0XC414B8A6` |
| `HKCU\...\Explorer\Accent\AccentPalette` | bytes | 8 x `RR GG BB 00` | ver 1.2 |

### 1.1 Como se verifico

Dump del registro de una maquina Win11 real con acento `#4C4A48`:

```
DWM\AccentColor       = 0xFF484A4C   -> bytes LE: 4C 4A 48 FF -> ABGR -> #4C4A48  OK
DWM\ColorizationColor = 0xC44C4A48   -> ARGB (alpha C4)       -> #4C4A48          OK
AccentPalette idx 3   = 4C 4A 48 00  -> RGBA                  -> #4C4A48          OK
```

Y el default de fabrica de Windows es `AccentColor=0xFFD77800` = `#0078D7`, el azul
conocido. Cierra por los dos lados. `unattend-generator/resource/SetColorTheme.ps1`
construye el DWORD con `[BitConverter]::ToUInt32(@($R,$G,$B,$A))`, o sea
little-endian de R,G,B,A = `0xAABBGGRR`, que es lo mismo.

### 1.2 AccentPalette

32 bytes = 8 entradas de 4 bytes, cada una `RR GG BB 00` (el alpha es **0x00**, no FF).

| idx | bytes | que es |
|---|---|---|
| 0 | 0-3 | mas claro (light3) |
| 1 | 4-7 | light2 |
| 2 | 8-11 | light1 |
| 3 | **12-15** | **EL ACENTO BASE** (= `AccentColor`) |
| 4 | 16-19 | dark1 (= `StartColorMenu`) |
| 5 | 20-23 | dark2 |
| 6 | 24-27 | dark3 |
| 7 | 28-31 | `#107C10` FIJO, el verde de Windows. NO deriva del acento. |

El indice 3 esta confirmado en `AutoDarkMode/AutoDarkModeSvc/Handlers/RegistryHandler.cs`
(`GetAccentColor` -> `palette.TryGetValue(3, ...)`).

**NO calcules esta paleta a mano.** Ver la seccion 2: el motor de temas de Windows la
deriva solo, y lo hace bien. Un escalado lineal en RGB (lo que haciamos) da colores
quemados que no coinciden con los que genera Settings.

### 1.3 Helper obligatorio

Toda conversion de color pasa por UNA sola funcion, en `scripts\lib.ps1`:

```powershell
function ConvertTo-AccentDwords([string]$Hex) {
  # '#14B8A6' o '14B8A6' -> @{ Abgr=[uint32]; Argb=[uint32]; R=..; G=..; B=..; Hex='14B8A6' }
}
```

Nadie escribe literales `0xFF...` de color en ningun otro archivo. Ese fue el bug.

---

## 2. Tema y acento: se aplican por `.theme`, NO por valores sueltos

### 2.1 La causa raiz de "el OOBE pisa el tema"

Al crear el perfil de usuario, Windows **aplica un tema**. Cual, lo dice esto:

```
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes
  InstallTheme       = C:\Windows\resources\Themes\aero.theme
  InstallThemeLight  = C:\Windows\resources\Themes\aero.theme
HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Themes   (idem)
```

Ese paso corre **DESPUES** de heredar `Users\Default\NTUSER.DAT`, y `aero.theme` trae
`SystemMode=Light`, `AppMode=Light` y `ColorizationColor=0XC40078D4`. Por eso se
perdian tema y acento y sobrevivia todo lo demas: lo demas no vive en un `.theme`.

### 2.2 La solucion: cambiarle el tema que instala

No se le pelea al OOBE con un RunOnce. Se genera `LunaticOS.theme` y se apunta
`InstallTheme` ahi. Ventajas:

- Windows aplica el tema con **su propio motor**, que deriva TODA la paleta correctamente.
- Es 100% reversible: es un tema, el usuario elige otro en Settings. No es una policy.
- Una sola fuente de verdad para el color.

### 2.3 Plantilla del `.theme`

Destino en la imagen: `Windows\Resources\Themes\LunaticOS.theme`.
Encoding: **ASCII puro, sin BOM** (los .theme del sistema son ANSI; nuestro contenido
no lleva acentos).

```ini
; LunaticOS
[Theme]
DisplayName=LunaticOS
SetLogonBackground=0

[Control Panel\Desktop]
Wallpaper=%SystemRoot%\Web\Wallpaper\LunaticOS\<archivo>
TileWallpaper=0
WallpaperStyle=10
Pattern=

[VisualStyles]
Path=%ResourceDir%\Themes\Aero\Aero.msstyles
ColorStyle=NormalColor
Size=NormalSize
AutoColorization=0
ColorizationColor=0XC414B8A6
SystemMode=Dark
AppMode=Dark
VisualStyleVersion=10

[boot]
SCRNSAVE.EXE=

[MasterThemeSelector]
MTSM=RJSPBS

[Sounds]
SchemeName=@%SystemRoot%\System32\mmres.dll,-800
```

Reglas de armado:
- `SystemMode` / `AppMode`: `Dark` si el usuario marco tema oscuro, si no `Light`.
- `ColorizationColor`: **ARGB** con alpha `C4`. Si el usuario no eligio acento, se
  omite la linea junto con `AutoColorization` y Windows usa su default.
- `Wallpaper`: se omite la seccion `[Control Panel\Desktop]` completa si no hay wallpaper propio.
- Si no hay ni tema ni acento ni wallpaper: **no se genera el .theme y no se toca `InstallTheme`.**

### 2.4 DOS CAPAS COHERENTES, no dos fuentes en conflicto

**CORREGIDO el 2026-07-29 (segunda vuelta).** Este apartado decia antes que el `.theme`
era la fuente unica del color y que el RunOnce no debia escribir ningun valor de color.
**Eso fue un error de diseno mio y costo un build entero:** el `.theme` no se aplicaba, asi
que nadie escribia el color y el acento quedaba en el azul de fabrica.

Lo correcto:

- El `.theme` lleva `ColorizationColor` (ARGB) y `AutoColorization=0`.
- El hive DEFAULT y el RunOnce **tambien** escriben los valores de color, en su formato
  (tabla de la seccion 1).
- **No es duplicacion peligrosa porque las dos capas derivan del MISMO hex a traves del
  MISMO helper** (`ConvertTo-AccentDwords`). El bug original no era tener dos capas: era
  tener dos capas con formatos de bytes distintos calculados a mano en dos lugares.

Y hace falta la segunda capa porque el no-op de Windows es por VALOR (ver 2.10).

### 2.5 SON TRES RAMAS, NO DOS: `InstallThemeDark` era el bug

**MEDIDO en el build del 2026-07-29 20:32 (VM instalada):** el tema salio en modo oscuro
pero con el acento AZUL de fabrica, y nuestro `LunaticOS.theme` parecia ignorado.
No estaba ignorado: **se aplico OTRO**.

```
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes
  InstallTheme       = ...\aero.theme
  InstallThemeDark   = ...\dark.theme     <-- ESTA NO LA ESCRIBIAMOS
  InstallThemeLight  = ...\aero.theme
```

Son **TRES** valores, y nosotros escribiamos dos. Como el hive DEFAULT ya traia
`AppsUseLightTheme=0` / `SystemUsesLightTheme=0`, Windows tomo la rama **Dark** y aplico
el `dark.theme` de fabrica, que trae `ColorizationColor=0XC40078D4` (el azul) y
`Wallpaper=img19.jpg`. De ahi salia el azul, y el `Custom.theme` que Windows genero para
el usuario lo dejo escrito.

**Hay que escribir las TRES en las DOS ramas del hive = 6 valores.**

Y por que el modo oscuro quedaba escrito pero la UI se veia clara: staff de NTLite lo
confirma en dos hilos -- el aprovisionamiento del usuario nuevo corre justo antes del
primer logon e **ignora o pisa** las settings HKCU de escritorio del hive Default. Quien
traduce registro -> colores es el **motor de temas**, y ese solo corre **cuando se aplica
un tema**. Escribir los valores no aplica nada. Por eso el usuario tuvo que forzar un
ciclo de apply a mano (ver 2.7) para que el oscuro apareciera.

### 2.6 Aplicar el tema en el primer login: `IThemeManager2::AddAndSelectTheme`

`InstallTheme*` es necesario pero **no suficiente**. En el primer login hay que APLICAR el
tema, y el metodo esta MEDIDO en una maquina real (build 22631, PowerShell 5.1):
`hr=0x00000000`, **856 ms**, **NO abre Settings**, y de UNA sola llamada dejo escritos
`DWM\AccentColor`, `ColorizationColor`, `ColorizationAfterglow`, `AccentColorMenu`,
`StartColorMenu`, `AccentPalette` y `CurrentTheme`.

```
CLSID  9324da94-50ec-4a14-a770-e90ca03e7c8f
IID    c1e8c83e-845d-4d95-81db-e283fdffc000
CoCreateInstance ctx = 0x17   ->   Init(0)   ->   AddAndSelectTheme(path, PACK_SILENT)
PACK_SILENT = 1 << 2
```

Reglas de uso, todas con evidencia:

- **Thread STA obligatorio.**
- Corre en **contexto de usuario** (RunOnce del hive DEFAULT), no offline.
- **NO hace falta** broadcast `ImmersiveColorSet` ni reiniciar Explorer.
- `AddAndSelectTheme` y **no** `SetCurrentTheme(idx)`: toma un PATH y no depende de
  matchear un `DisplayName` localizado ("Windows (dark)" vs "Windows (oscuro)").
- **TRAMPA CRITICA -- no-op silencioso:** si el `.theme` es "el mismo" que el actual,
  Windows **no hace nada y devuelve `hr=0`**. Hay que darle un `ThemeId` GUID **nuevo** y
  un nombre de archivo distinto en cada build, o el segundo intento no aplica nada y el
  codigo de retorno miente. AutoDarkMode resuelve lo mismo nudgeando +-1 un canal.
- `AutoColorization=0` en el `.theme` es **obligatorio**: si no, Windows recalcula el
  acento a partir del wallpaper y pisa el color elegido.

**Descartado con evidencia:** `rundll32 ... desk.cpl desk,@Themes /Action:OpenTheme`
(= `ITheme::OpenTheme`) **ignora el flag silencioso y abre la UI**. El propio codigo de
AutoDarkMode lo comenta: *"This does not work"*.

**Descartado:** bajar a los ordinales no documentados de `uxtheme.dll`
(`RefreshImmersiveColorPolicyState` y companhia). Medido: el mapeo de ordinales que circula
**no se sostiene** en 22631 (los ord 49 y 138 devolvieron lo contrario a lo esperado). Y
no hace falta.

### 2.7 El truco del alto contraste: NO USARLO

Aplicar un tema de alto contraste y volver al default SI fuerza el ciclo de apply -- asi
fue como el usuario logro ver el modo oscuro. Pero tiene tres efectos colaterales que
arruinan justamente lo que queremos:

1. blanquea `CurrentTheme`,
2. fuerza el wallpaper a un color solido y no siempre lo devuelve,
3. pone **`AutoColorization=1`**, o sea Windows recalcula el acento desde el wallpaper.

El apply de 2.6 consigue lo mismo sin ningun dano.

### 2.8 El acento exacto: `AccentPalette` se escribe DESPUES del apply

**MEDIDO:** con `ColorizationColor=0XC414B8A6` (teal `#14B8A6`), `AccentColor` queda exacto
pero **`AccentPalette[3]` sale `#008979`**: Windows normaliza el color a su rampa de
luminancias. Si se quiere el teal exacto en Start y taskbar, hay que escribir
`AccentPalette` a mano **despues** del apply (probado: sobrevive).

**NO intentes derivar los 8 tonos con una formula:** no hay algoritmo publicado exacto.
Se hardcodea la rampa o se acepta la normalizacion de Windows.

Sobre el alpha de cada entrada: es padding a efectos practicos. Settings escribe `0x00`,
el motor de temas a veces `0xFF`, WinPaletter siempre `255`, y funciona igual.

### 2.9 Ojo con los falsos positivos de la comunidad

Circulan hilos que dicen "en 25H2 el modo oscuro se revierte solo a los 5 segundos".
**No es del sistema operativo:** es PowerToys 0.95.0 *Light Switch*, arreglado en 0.95.1.
No perder una sesion con eso.

### 2.10 CUATRO trampas mas, todas MEDIDAS y todas activas en los builds fallidos

Bisecadas en una maquina real. Cada una fallaba EN SILENCIO, y dos de ellas explican por
que el modo oscuro quedaba escrito en el registro pero la UI se dibujaba clara.

**A. `AddAndSelectTheme` devuelve `E_FAIL` si el `.theme` no trae una linea `Wallpaper=`.**
Bisecado byte a byte:

```
sin seccion [Control Panel\Desktop]      -> hr=0x80004005  E_FAIL
seccion presente pero vacia              -> hr=0x80004005  E_FAIL
seccion con solo Pattern=                -> hr=0x80004005  E_FAIL
seccion con Wallpaper= (valor VACIO)     -> hr=0x00000000  OK
seccion con Wallpaper=<ruta inexistente> -> hr=0x00000000  OK
```

La version anterior de la fase 10 omitia la seccion entera cuando no habia wallpaper
propio, que es **el caso por defecto del proyecto**. O sea el apply fallaba siempre.
**La seccion `[Control Panel\Desktop]` con una linea `Wallpaper=` va SIEMPRE.** Sin
wallpaper propio se usa el de fabrica del modo (`img19.jpg` en Dark, `img0.jpg` en Light),
que es lo que hacen `dark.theme` y `aero.theme`.

Esto invalida la regla de la seccion 2.3 que decia "se omite la seccion completa si no hay
wallpaper propio". NO se omite nunca.

**B. `New-Item -Path <clave-del-registro> -Force` BORRA TODOS LOS VALORES de la clave si ya
existe.** Comprobado: clave con 2 valores -> queda vacia.

El script del primer login hacia `New-Item -Force` antes de cada `Set-ItemProperty`, asi
que el item `acento-en-taskbar` (que escribe `ColorPrevalence` en
`Themes\Personalize`) **le borraba el `AppsUseLightTheme` y el `SystemUsesLightTheme` que
acababa de escribir `tema-oscuro`**. Y un valor AUSENTE significa CLARO.
**Nuestro propio RunOnce borraba el modo oscuro.**
Nunca uses `New-Item -Force` sobre una clave del registro que pueda existir: crea la clave
solo si falta.

**C. El no-op de Windows es por VALOR, no por tema.** La seccion 2.6 decia que alcanzaba
con un `ThemeId` nuevo. No alcanza: se piso `AccentColor` dejando `ColorizationColor` bien,
se reaplico, y `hr=0` con el modo corregido pero **el color NO**. Con `ThemeId` nuevo,
igual. Por eso el apply necesita una cadena de tres niveles:

1. apply del `.theme`,
2. si el color no quedo: apply con `ThemeId` nuevo generado en runtime,
3. si tampoco: escribir los 6 DWORD de color y el modo a mano (mismos numeros, mismo helper).

**D. `[PreserveSig]` en la declaracion de `AddAndSelectTheme`.** Sin eso, un `E_FAIL` real
llega como `COMException` y el `hr` que se loguea queda en `0xFFFFFFFF`: **el log miente
justo donde mas importa.** Con `[PreserveSig]` se lee el HRESULT de verdad.

---

## 3. Reparto de responsabilidades

| Que | Donde se escribe |
|---|---|
| Tema claro/oscuro, color de acento, wallpaper | **`.theme`** + `InstallTheme` |
| `EnableTransparency`, `ColorPrevalence` (Personalize y DWM) | hive DEFAULT (`Users\Default\NTUSER.DAT`) |
| `Explorer\Advanced` (TaskbarAl, ShowSecondsInSystemClock, UseCompactMode, LaunchTo, TaskbarSi) | hive DEFAULT |
| `Control Panel\Desktop` (MenuShowDelay, WindowMetrics\MinAnimate) | hive DEFAULT |
| Menu contextual clasico (`Software\Classes\CLSID\...`) | **solo RunOnce** — vive en `UsrClass.dat`, no en NTUSER.DAT |
| `DisableStartupSound` | hive SOFTWARE (es de maquina) |
| Reaplicacion de todo lo de usuario | RunOnce del hive DEFAULT |

---

## 4. RunOnce: NUNCA matar Explorer sin relanzarlo

`Stop-Process -Name explorer -Force` en el PRIMER login deja el escritorio gris sin
shell: en esa sesion el shell **no respawnea solo**. Es el issue #329 de
`cschneegans/unattend-generator`, con exactamente el codigo que teniamos.

### 4.1 Refresco sin matar nada (lo preferido)

```powershell
Add-Type -Namespace Win32 -Name Native -MemberDefinition @'
[DllImport("user32.dll", CharSet=CharSet.Auto, SetLastError=true)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam,
  string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
[UIntPtr]$r = [UIntPtr]::Zero
# HWND_BROADCAST=0xFFFF  WM_SETTINGCHANGE=0x1A  SMTO_ABORTIFHUNG=0x2
[Win32.Native]::SendMessageTimeout([IntPtr]0xFFFF, 0x1A, [UIntPtr]::Zero,
  'ImmersiveColorSet', 0x2, 3000, [ref]$r) | Out-Null
```

Esto es lo que usa AutoDarkMode (`DwmRefreshHandler.Broadcast`). Alcanza para tema,
colores y la mayoria de los tweaks.

### 4.2 Si hace falta reiniciar el shell (menu contextual)

Solo el menu contextual clasico necesita reinicio de Explorer. Si se hace, es
OBLIGATORIO relanzarlo con verificacion:

```powershell
$habia = [bool](Get-Process explorer -ErrorAction SilentlyContinue)
if ($habia) {
  Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    if (Get-Process explorer -ErrorAction SilentlyContinue) { break }
    Start-Process explorer.exe -ErrorAction SilentlyContinue
  }
}
```

Un `Start-Sleep 3` seguido de un `if` es una carrera, no una garantia.

### 4.3 Donde vive el RunOnce

En el hive de usuario DEFAULT, no en HKLM:

```
Users\Default\NTUSER.DAT -> Software\Microsoft\Windows\CurrentVersion\RunOnce
```

Asi corre para **cada usuario nuevo**, no solo para el primero que loguea (que es lo
que hace el de HKLM). Es lo que hace `unattend-generator` (`modifier/UserOnce.cs`).
El prefijo `AA` se conserva: RunOnce corre alfabetico y secuencial, y la
personalizacion tiene que ir antes del instalador de programas (`ZZ`, 20+ min).

---

## 5. Lo que BLOQUEA Settings — prohibido escribir

### 5.1 Nunca, bajo ningun concepto

| Clave | Que rompe |
|---|---|
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization\*` | tema/color/lockscreen en gris |
| `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP\*` | el usuario NO puede cambiar fondo ni lockscreen |
| `HKCU\...\CurrentVersion\Policies\ActiveDesktop\NoChangingWallpaper` | no se puede cambiar el fondo |
| `HKCU o HKLM\...\CurrentVersion\Policies\System\NoDispCPL` | mata el panel entero |
| ...`\Policies\System\NoDispAppearancePage`, `NoDispBackgroundPage`, `NoColorChoice`, `NoThemesTab`, `SetVisualStyle` | bloquean pestanas puntuales |

`unattend-generator` usa `PersonalizationCSP` para el lock screen. **Nosotros no.**
Aplica la imagen pero deja al usuario sin poder cambiarla.

### 5.2 Limpieza defensiva

La fase de personalizacion **borra** esas claves del hive offline si existen. Cuesta
milisegundos y garantiza el objetivo del proyecto sin importar de donde vino la imagen.

### 5.3 El cartel "administradas por tu organizacion"

Confirmado en foros de comunidad: `DisableWindowsConsumerFeatures=1` lo dispara, y
ademas hace desaparecer opciones de Personalization > Background (Spotlight).

Las policies de privacidad se parten en dos grupos:

- **Se quedan** (no tocan la UI de personalizacion): `DataCollection\*`,
  `WindowsCopilot\TurnOffWindowsCopilot`, `WindowsAI\*`, `AdvertisingInfo\*`, `System\*Activit*`.
- **Pasan a un flag OPCIONAL, desmarcado** (`BlockCloudContent`):
  `CloudContent\DisableWindowsConsumerFeatures`, `CloudContent\DisableConsumerAccountStateContent`,
  `CloudContent\DisableCloudOptimizedContent`. La nota de la TUI tiene que decir
  explicitamente que ponen el cartel de organizacion en Settings.

### 5.4 Windows sin activar

**No hay truco de registro para esto.** Sin activar, Personalization esta bloqueada por
diseno de licenciamiento (confirmado: *"It is required to activate Windows 11 before you
can choose an accent color"*). El unico arreglo real es activar. Ver seccion 6.

Ojo: el `.theme` aplicado por el sistema SI toma efecto sin activacion; lo que no se
puede es **cambiarlo desde la UI**.

### 5.5 Otros grises que no son culpa nuestra

- "Mostrar color de acento en Inicio y barra de tareas" esta en gris si el modo es
  **Light**. Solo aplica en Dark. La nota de la TUI tiene que decirlo.
- El modo de alto contraste tambien deshabilita la eleccion de acento.

---

## 6. Clave de producto

Hoy `config\autounattend.xml` tiene la clave generica publica de Pro
(`VK7JG-NPHTM-C97JM-9MPGT-3V66T`). Esa clave **fija la edicion pero NO activa**, y sin
activacion Personalization queda en gris.

Contrato:

- La clave real va en **`clave-windows.txt`** en la raiz del repo, **gitignored**.
  Una linea, formato `XXXXX-XXXXX-XXXKX-XXXXX-XXXXX`. Se ignoran lineas vacias y las
  que empiezan con `#`.
- La fase que inyecta el runtime reemplaza el `<Key>` del autounattend con esa clave.
- **La clave NUNCA se escribe en `perfil.json`.** El perfil es compartible; la licencia no.
- Si el archivo no existe: se usa la generica y se AVISA claro, en el preflight y al
  terminar el build, que Personalization va a estar bloqueada hasta activar.

---

## 7. Los tests tienen que medir la CLASE del bug

Leccion de las dos sesiones anteriores: el instrumento fallo mas veces que el producto.
Un test que busca la firma exacta de un bug da verde con el bug presente.

Tests obligatorios en `LunaticOS.ps1 -SelfTest`:

1. **Color resultante, no rango del entero.** Dado `#14B8A6`, que el ABGR sea
   `0xFFA6B814` y el ARGB `0xC414B8A6`. El test viejo solo verificaba que el DWORD
   entrara en uint32 — y daba OK con los bytes invertidos.
2. **Ningun literal de color** fuera de `ConvertTo-AccentDwords`: que no exista
   `0x[0-9A-F]{8}` en `config\personalizacion.ps1`.
3. **Ningun `Stop-Process ... explorer`** sin bucle de relanzamiento en el script
   generado por la fase 10.
4. **Ninguna clave de la seccion 5.1** escrita por ninguna fase (grep sobre todos los
   `scripts\*.ps1` y `config\*.ps1`).
5. **El `.theme` generado parsea**: secciones `[Theme]`, `[VisualStyles]` presentes,
   `SystemMode`/`AppMode` en `Dark|Light`, `ColorizationColor` con formato `0X` + 8 hex.
6. **`InstallTheme` e `InstallThemeLight`** se escriben en las DOS ramas
   (`SOFTWARE\...` y `SOFTWARE\WOW6432Node\...`).

Y en `scripts\test-vm.ps1 -Verify`, sobre el disco instalado:

7. Dump de **TODAS** las policies presentes bajo `HKLM\SOFTWARE\Policies` y
   `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies`, para que un bloqueo no
   vuelva a pasar desapercibido.
8. Comparar el **color real** del hive del usuario contra el pedido en el perfil.
9. Verificar que ninguna clave de la seccion 5.1 existe en el disco instalado.

---

## 8. Fuentes

Todo lo de aca esta medido o leido de codigo en produccion, no de documentacion generica:

- Dump del registro de una maquina Win11 25H2 real (formato de bytes, AccentPalette, InstallTheme).
- Lectura de `C:\Windows\Resources\Themes\dark.theme` y de un `Custom.theme` activo (formato .theme).
- `cschneegans/unattend-generator`: `resource/SetColorTheme.ps1`, `modifier/Personalization.cs`,
  `modifier/UserOnce.cs`, issue #329 (matar explorer en el primer login).
- `AutoDarkMode/Windows-Auto-Night-Mode`: `RegistryHandler.cs` (indice 3 del AccentPalette),
  `DwmRefreshHandler.cs` (broadcast ImmersiveColorSet), `IThemeManager2/Tm2Handler.cs`.
- Gist de AveYo "Pitch Black Theme.reg" (set completo de valores de tema y logon).
- Gist de GuyPaddock "Creating default Windows Theme" + foros NTLite (InstallTheme).
- elevenforum (Shawn Brink): activacion requerida para el acento; acento en taskbar solo en Dark.
