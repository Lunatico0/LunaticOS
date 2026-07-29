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

### 2.4 UNA sola fuente de verdad para el color

Si el `.theme` lleva el color, **el RunOnce NO escribe ningun valor de color**
(`AccentColor`, `ColorizationColor`, `AccentPalette`, `AccentColorMenu`, `StartColorMenu`).
Dos fuentes = la desalineacion que teniamos. El `.theme` gana siempre.

### 2.5 A medir en la VM (no asumir)

Vaciar `InstallTheme` fue una tecnica valida en Win10 21H2 y **se reporta rota desde 22H2**.
Nosotros no la usamos: apuntamos `InstallTheme` a nuestro tema, que es lo que hacen los OEM.
**Hay que verificar en la VM que 25H2 lo respeta.** Si no lo respeta, el plan B es el
RunOnce aplicando el `.theme`, y en ese caso vale la seccion 2.4 al reves.

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
