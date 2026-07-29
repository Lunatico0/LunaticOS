#requires -Version 5.1
<#
  test-vm.ps1 - Probar la ISO generada en una VM Hyper-V, sin intervencion manual.

  Por que existe: cada bug que encontro este proyecto (D14, D18, D19, D20) salio de
  instalar la ISO en una VM y leer los logs. NO de revisar el codigo. Rehacer una ISO
  cuesta ~45 min; descubrir el problema en la mother real cuesta reinstalar.

  ===========================================================================
  EL TECLADO SINTETICO SIRVE PARA EL FIRMWARE, NO PARA EL SETUP.
  Esta distincion costo un test entero: leela antes de tocar el bloque -Boot.

  FUNCIONA en el firmware UEFI. La ISO usa efisys.bin, o sea pide "Press any key
  to boot from CD or DVD" y aborta con "The boot loader failed" si nadie aprieta
  nada en ~5 segundos (D17). Mandar Enter por WMI durante ~25s tras Start-VM SI
  pasa ese prompt:
      Msvm_Keyboard.TypeKey(0x0D)   en root\virtualization\v2

  NO FUNCIONA una vez que arranco WinPE. En "Select location to install Windows 11"
  no llega absolutamente nada. Se probaron cinco variantes, todas con
  ReturnValue=0 y CERO efecto:
      TypeKey(0x0D) | ALT+N via PressKey/ReleaseKey | TypeKey(0x09) TAB x3
      TypeScancodes(0x0F/0x8F) | todo lo anterior con vmconnect.exe abierto
  El TAB es la prueba limpia: el foco no se movio ni un pixel. `ReturnValue=0` es
  una MENTIRA UTIL -- WMI acepta la llamada y descarta el evento.

  COMO SE APRENDIO (y por que el loop no se toca): en una corrida se saco este loop
  creyendo que era inutil, razonando que "con un VHDX vacio el prompt no aparece
  porque no hay otro dispositivo booteable". FALSO: el boot siguiente murio con
  "The boot loader failed" en el SCSI DVD. El prompt aparece igual, y el loop era
  lo unico que lo pasaba. Correlacion mal leida en las dos direcciones.

  EN EL SO YA INSTALADO el teclado vuelve a funcionar para ATAJOS (Win, Win+R,
  Escape), pero NO para escribir texto: `TypeText` y los VK de letras dejan el
  campo vacio. Y `PowerShell Direct` no sirve con password vacio ("The credential
  is invalid").

  CONSECUENCIA: el test NO es 100% desatendido. Hay UN clic humano, en la seleccion
  de disco. Es coherente con D14 (el particionado se deja a mano a proposito, para
  no formatear el disco equivocado).
  ===========================================================================

  Uso:
    .\test-vm.ps1 -Reset       # VHDX limpio + ISO en el DVD + boot del DVD
    .\test-vm.ps1 -Boot        # arranca y manda Enter 25s (pasa el prompt de boot)
    .\test-vm.ps1 -Shot        # screenshot de la pantalla de la VM -> PNG
    .\test-vm.ps1 -Verify      # VM apagada: monta el VHDX y audita el resultado
    .\test-vm.ps1 -Reset -Boot # el flujo tipico -> despues UN clic en "Next"
    . .\test-vm.ps1            # dot-source: SOLO carga las funciones de auditoria
#>
param(
  [switch]$Create,              # crea la VM desde cero (Gen2 + TPM + Secure Boot)
  [switch]$Reset,
  [switch]$Boot,
  [switch]$Shot,
  [switch]$Verify,
  [switch]$Enter,               # manda UN Enter. OJO: NO funciona en el setup (ver header)
  [switch]$Destroy,             # borra la VM y su VHDX
  [string]$VMName  = 'LunaticOS-Test',
  [int]$RamGB      = 6,
  [int]$Cpus       = 4,
  [int]$DiskGB     = 64,
  [int]$KeySeconds = 25         # cuanto tiempo mandar Enter para pasar el prompt de boot
)

. "$PSScriptRoot\config.ps1"
# lib.ps1 trae Use-OfflineHive (load/unload BLINDADO: un hive que queda cargado
# bloquea el VHDX) y ConvertTo-AccentDwords, la UNICA conversion de color del repo
# (contrato 1.3). El -Verify calcula el color ESPERADO con ese helper en vez de
# reimplementar la conversion: si el instrumento hace su propia cuenta, puede
# equivocarse igual que el producto y darle la razon al bug.
. "$PSScriptRoot\lib.ps1"

$iso  = Join-Path $CFG.Root 'work\Win11_25H2_Pro_debloat.iso'
# El VHDX lleva el nombre de la VM: si no, dos VMs de test se pelean por el mismo
# archivo y -Reset de una te borra el disco de la otra.
$vhdx = Join-Path $CFG.Root "work\$VMName.vhdx"
$ns   = 'root\virtualization\v2'

function Get-VmCim {
  Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$VMName'"
}

# ===========================================================================
#  FUNCIONES DE AUDITORIA DEL DISCO INSTALADO
#
#  Estan ACA, fuera del bloque -Verify, por una razon medida: en este proyecto
#  el instrumento de medicion fallo mas veces que el producto. Dos casos reales:
#  un -Verify que comparaba contra un criterio YA DESCARTADO (dio FALLO falso), y
#  un test que buscaba la FIRMA EXACTA de un bug en vez de su CLASE -- y dio verde
#  con el bug presente. Un chequeo que no se puede correr contra un hive de prueba
#  no se puede probar, y un test que no se prueba es una mentira con formato de OK.
#
#  Dot-sourceando este archivo se cargan SOLO estas funciones, asi se las puede
#  correr contra hives sembrados a mano con reg.exe, sin VM y sin ISO:
#
#      . .\test-vm.ps1
#      Test-AccentAlignment -WantHex '#14B8A6' -AccentColor 0xFF14B8A6L
#
#  REGLA QUE GOBIERNA TODO ESTE BLOQUE: si el bug es de CLASE, se mide la CLASE.
#  La lista literal del contrato es lo que sabemos HOY. La clase es lo que nos va
#  a morder manana.
# ===========================================================================

# ---------------------------------------------------------------------------
# Lee un arbol del registro y devuelve UN objeto por valor: Key, Name, Type, Data.
#
# Se parsea reg.exe y NO se usa el provider de PowerShell a proposito: el provider
# deja handles abiertos sobre la colmena cargada y despues el unload falla. Un hive
# que queda cargado bloquea el VHDX.
#
# reg.exe sangra los valores con CUATRO espacios (a cualquier profundidad) y separa
# nombre / tipo / dato tambien con cuatro. Por eso el corte es por el separador de
# 4 y no por espacio: hay nombres de valor con espacios simples adentro.
# ---------------------------------------------------------------------------
function Get-RegTree {
  param([Parameter(Mandatory)][string]$Key, [switch]$Recurse)
  $cmd = @('query', $Key)
  if ($Recurse) { $cmd += '/s' }
  $raw = & reg.exe @cmd 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $raw) { return @() }
  $res = New-Object System.Collections.Generic.List[object]
  $cur = $Key
  foreach ($line in $raw) {
    $l = "$line"
    if ($l -match '^HKEY_') { $cur = $l.Trim(); continue }
    if ($l -match '^\s{4}(.+?)\s{4}(REG_[A-Z_]+)\s{4}(.*)$') {
      $res.Add([pscustomobject]@{ Key = $cur; Name = $Matches[1]; Type = $Matches[2]; Data = $Matches[3] })
    }
    elseif ($l -match '^\s{4}(.+?)\s{4}(REG_[A-Z_]+)\s*$') {
      $res.Add([pscustomobject]@{ Key = $cur; Name = $Matches[1]; Type = $Matches[2]; Data = '' })
    }
  }
  return $res.ToArray()
}

# Solo los NOMBRES DE CLAVE de un arbol. Hace falta aparte porque una clave sin
# valores no aparece en Get-RegTree, y una clave de policy VACIA sigue siendo la
# clase del bug: si no se lista, pasa invisible.
function Get-RegKeyList {
  param([Parameter(Mandatory)][string]$Key, [switch]$Recurse)
  $cmd = @('query', $Key)
  if ($Recurse) { $cmd += '/s' }
  $raw = & reg.exe @cmd 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $raw) { return @() }
  $out = @()
  foreach ($line in $raw) { $l = "$line"; if ($l -match '^HKEY_') { $out += $l.Trim() } }
  return $out
}

# Un solo valor de una clave (sin recursion). $null si no existe.
function Get-RegEntry {
  param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Name)
  $e = @(Get-RegTree -Key $Key | Where-Object { $_.Name -eq $Name })
  if ($e.Count -eq 0) { return $null }
  return $e[0]
}

# Un REG_DWORD como [uint32]. NO como [int]: los colores ARGB con alpha FF pasan de
# 2^31 y un Int32 los da NEGATIVO. Ese cast fallo dos veces en este repo.
function Get-RegU32 {
  param($Entry)
  if (-not $Entry) { return $null }
  if ("$($Entry.Data)" -match '^0x([0-9a-fA-F]+)$') { return [Convert]::ToUInt32($Matches[1], 16) }
  return $null
}

# REG_BINARY: reg.exe lo imprime como un chorro de hex sin separadores.
function Convert-HexStringToBytes {
  param([string]$Hex)
  $h = ("$Hex" -replace '[^0-9A-Fa-f]', '')
  if ($h.Length -lt 2) { return @() }
  $n = [int][Math]::Floor($h.Length / 2)
  $b = New-Object byte[] $n
  for ($i = 0; $i -lt $n; $i++) { $b[$i] = [Convert]::ToByte($h.Substring($i * 2, 2), 16) }
  return $b
}

# ---------------------------------------------------------------------------
# COLOR: siempre en hex legible, nunca en decimal ni en DWORD crudo.
# Un "4288685588" en pantalla no le dice nada a nadie. Un
# "#A6B814 (esperaba #14B8A6)" se entiende al instante -- y es exactamente el bug
# que tuvimos.
# ---------------------------------------------------------------------------
function Format-ColorHex {
  param([int]$R, [int]$G, [int]$B)
  return ('#{0:X2}{1:X2}{2:X2}' -f ($R -band 0xFF), ($G -band 0xFF), ($B -band 0xFF))
}

# Un DWORD de color leido con UN formato concreto. Los dos formatos existen y son
# de la MISMA clave del registro (contrato 1):
#   ABGR = 0xAABBGGRR -> AccentColor, AccentColorInactive, AccentColorMenu, StartColorMenu
#   ARGB = 0xAARRGGBB -> ColorizationColor, ColorizationAfterglow, .theme
# Escribir el mismo DWORD en los dos es el bug que llego al usuario.
function Convert-DwordToColor {
  param(
    [Parameter(Mandatory)]$Dword,
    [Parameter(Mandatory)][ValidateSet('ABGR', 'ARGB')][string]$Layout
  )
  # [uint64] antes de desplazar: en PowerShell un -shr sobre un valor con el bit 31
  # prendido puede irse por el lado del signo. Con uint64 no hay bit de signo en juego.
  $v  = [uint64]$Dword
  $b0 = [int]($v -band 0xFF)
  $b1 = [int](($v -shr 8)  -band 0xFF)
  $b2 = [int](($v -shr 16) -band 0xFF)
  $a  = [int](($v -shr 24) -band 0xFF)
  if ($Layout -eq 'ABGR') { $r = $b0; $g = $b1; $bl = $b2 }
  else                    { $bl = $b0; $g = $b1; $r = $b2 }
  return [pscustomobject]@{
    Hex = (Format-ColorHex $r $g $bl); R = $r; G = $g; B = $bl; Alpha = $a
    Raw = ('0x{0:X8}' -f [uint32]$Dword); Layout = $Layout
  }
}

# Los 8 tonos del AccentPalette en hex, para dumpear. El indice 3 es el acento
# base; el 7 es el verde fijo de Windows (#107C10) y NO deriva del acento.
function Get-AccentPaletteColors {
  param($Bytes)
  $b = @($Bytes)
  $out = @()
  for ($i = 0; ($i + 3) -lt $b.Count; $i += 4) {
    $out += (Format-ColorHex $b[$i] $b[$i + 1] $b[$i + 2])
  }
  return $out
}

# ---------------------------------------------------------------------------
# EL TEST QUE FALTABA (contrato 7.8).
#
# El test viejo del acento solo verificaba que el DWORD entrara en uint32: daba OK
# con los bytes invertidos. Este compara el COLOR RESULTANTE, en hex, contra el que
# pidio el perfil, leyendo cada valor con el formato que Windows usa para ESE valor.
#
# Tres cosas se miden, no una:
#   1. cada valor contra el color pedido;
#   2. si el valor leido AL REVES da el color pedido -> los bytes estan invertidos,
#      que es el bug historico, y se dice con esas palabras;
#   3. si los valores no coinciden ENTRE SI -> desalineacion de formato, mismo bug
#      visto desde el otro lado.
#
# Cuando un valor difiere y NO es una inversion de bytes, esto NO canta bug: el
# .theme es la fuente del color y el motor de temas de Windows deriva tonos propios.
# Se informa QUE difiere y COMO (delta por canal) para que el humano decida. Un
# veredicto binario sin contexto es como se toman las decisiones equivocadas.
# ---------------------------------------------------------------------------
function Test-AccentAlignment {
  param(
    [Parameter(Mandatory)][string]$WantHex,
    $PaletteBytes      = $null,
    $AccentColor       = $null,
    $ColorizationColor = $null,
    $AccentColorMenu   = $null
  )
  $out = New-Object System.Collections.Generic.List[object]

  if (-not (Get-Command ConvertTo-AccentDwords -ErrorAction SilentlyContinue)) {
    $out.Add(@{ Level = 'FALLA'; Text = ('lib.ps1 no expone ConvertTo-AccentDwords (contrato 1.3): ' +
        'no puedo calcular el color esperado. NO invento un veredicto -- este chequeo queda SIN CORRER.') })
    return $out.ToArray()
  }
  $exp  = ConvertTo-AccentDwords $WantHex
  $want = Format-ColorHex $exp.R $exp.G $exp.B

  $obs = New-Object System.Collections.Generic.List[object]

  # AccentPalette: el acento base es el INDICE 3 (bytes 12-15, formato RR GG BB 00),
  # confirmado en AutoDarkMode (RegistryHandler.GetAccentColor -> palette[3]).
  $pb = @($PaletteBytes)
  if ($pb.Count -ge 16) {
    $obs.Add([pscustomobject]@{
      Name = 'Accent\AccentPalette[3]'; Layout = 'RR GG BB 00'; Raw = ''
      Hex = (Format-ColorHex $pb[12] $pb[13] $pb[14])
      Swapped = (Format-ColorHex $pb[14] $pb[13] $pb[12])
      R = [int]$pb[12]; G = [int]$pb[13]; B = [int]$pb[14]
      Alpha = [int]$pb[15]; WantAlpha = 0x00
    })
  }
  elseif ($pb.Count -gt 0) {
    $out.Add(@{ Level = 'FALLA'; Text = ('AccentPalette tiene {0} bytes y son 32 (8 tonos x 4): ' +
        'el indice 3 no se puede leer.') -f $pb.Count })
  }

  foreach ($v in @(
      @{ Name = 'DWM\AccentColor';         Dword = $AccentColor;       Layout = 'ABGR'; WantAlpha = 0xFF }
      @{ Name = 'DWM\ColorizationColor';   Dword = $ColorizationColor; Layout = 'ARGB'; WantAlpha = 0xC4 }
      @{ Name = 'Accent\AccentColorMenu';  Dword = $AccentColorMenu;   Layout = 'ABGR'; WantAlpha = 0xFF }
    )) {
    if ($null -eq $v.Dword) { continue }
    $bien  = Convert-DwordToColor -Dword $v.Dword -Layout $v.Layout
    $otro  = Convert-DwordToColor -Dword $v.Dword -Layout $(if ($v.Layout -eq 'ABGR') { 'ARGB' } else { 'ABGR' })
    $obs.Add([pscustomobject]@{
      Name = $v.Name; Layout = $v.Layout; Raw = $bien.Raw
      Hex = $bien.Hex; Swapped = $otro.Hex
      R = $bien.R; G = $bien.G; B = $bien.B
      Alpha = $bien.Alpha; WantAlpha = [int]$v.WantAlpha
    })
  }

  foreach ($o in $obs) {
    $det = if ($o.Raw) { ' [{0} leido como {1}]' -f $o.Raw, $o.Layout } else { ' [bytes {0}]' -f $o.Layout }
    if ($o.Hex -eq $want) {
      $out.Add(@{ Level = 'OK'; Text = ('{0} = {1}{2}' -f $o.Name, $o.Hex, $det) })
    }
    elseif ($o.Swapped -eq $want) {
      $out.Add(@{ Level = 'FALLA'; Text = ('{0}: {1} (esperaba {2}){3}' -f $o.Name, $o.Hex, $want, $det) })
      $out.Add(@{ Level = 'FALLA'; Text = ('  LOS BYTES ESTAN INVERTIDOS: leido al reves da {0}. ' -f $want) +
          'Es EL BUG HISTORICO del contrato 1 -- se escribio el formato de la otra fila de la tabla.' })
    }
    else {
      $out.Add(@{ Level = 'OJO'; Text = ('{0}: {1} (esperaba {2}){3}  delta R={4} G={5} B={6}' -f `
              $o.Name, $o.Hex, $want, $det, ('{0:+#;-#;0}' -f ($o.R - [int]$exp.R)),
            ('{0:+#;-#;0}' -f ($o.G - [int]$exp.G)), ('{0:+#;-#;0}' -f ($o.B - [int]$exp.B))) })
    }
    if ($o.Alpha -ne $o.WantAlpha) {
      $out.Add(@{ Level = 'OJO'; Text = ('  {0}: alpha 0x{1:X2} (el contrato dice 0x{2:X2})' -f $o.Name, $o.Alpha, $o.WantAlpha) })
    }
  }

  $hexes = @($obs | ForEach-Object { $_.Hex } | Sort-Object -Unique)
  if ($hexes.Count -gt 1) {
    $out.Add(@{ Level = 'FALLA'; Text = ('los valores de color NO COINCIDEN ENTRE SI -> ' +
        (($obs | ForEach-Object { "$($_.Name)=$($_.Hex)" }) -join '  ')) })
    $out.Add(@{ Level = 'FALLA'; Text = 'DESALINEACION DE FORMATO DE BYTES (contrato 1): dos valores de la ' +
        'misma clave usan formatos distintos (AccentColor=ABGR, ColorizationColor=ARGB) y aca no cierran. ' +
        'Es el bug historico: partes de la UI toman colores diferentes entre si.' })
  }
  elseif ($hexes.Count -eq 1 -and $hexes[0] -ne $want) {
    $out.Add(@{ Level = 'OJO'; Text = ('los valores COINCIDEN ENTRE SI en {0} pero el perfil pidio {1}: ' -f $hexes[0], $want) +
        'NO es desalineacion de formato.' })
    $out.Add(@{ Level = 'OJO'; Text = 'el .theme es la fuente del color y el motor de temas deriva tonos propios: ' +
        'compara esto con [VisualStyles] ColorizationColor del .theme ANTES de cantar bug. Si el .theme dice el ' +
        'color pedido y el hive dice otro, es un bug nuestro; si el .theme ya dice este, es derivacion legitima.' })
  }
  elseif ($hexes.Count -eq 0) {
    $out.Add(@{ Level = 'FALLA'; Text = 'no hay NI UN valor de color en el hive del usuario, ni el default de ' +
        'fabrica de Windows (0xFFD77800 = #0078D7). Este hive no parece de un perfil ya logueado: el color queda SIN MEDIR.' })
  }
  return $out.ToArray()
}

# ---------------------------------------------------------------------------
# QUE ROMPE CADA CLAVE de la seccion 5.1. El mensaje tiene que decir el panel que
# se cae, no solo el nombre: "NoDispCPL presente" no le dice nada a quien lo lee
# tres semanas despues.
# ---------------------------------------------------------------------------
function Get-SettingsBlockerImpact {
  return @{
    'NoDispCPL'            = 'mata el panel entero de Personalization / Display'
    'NoDispAppearancePage' = 'bloquea Personalization > Themes/Colors (apariencia)'
    'NoDispBackgroundPage' = 'bloquea Personalization > Background (fondo)'
    'NoColorChoice'        = 'bloquea la eleccion del color de acento'
    'NoThemesTab'          = 'bloquea la pestana Themes'
    'SetVisualStyle'       = 'fuerza el visual style: el usuario no puede cambiar el tema'
    'NoChangingWallpaper'  = 'no se puede cambiar el fondo de escritorio'
  }
}

# ---------------------------------------------------------------------------
# EL JUICIO (contrato 7.9): ninguna clave de la 5.1 puede existir en el disco.
#
# Y ACA ESTA LA PARTE QUE IMPORTA: no busca solo la lista literal. La lista es lo
# que sabemos hoy; la CLASE es lo que nos va a morder manana. Un test que busca la
# firma exacta de un bug ya nos dio verde con el bug presente.
#
#   FALLA    -> esta en el contrato 5.1. Sin matices.
#   SOSPECHA -> NO esta en la lista pero es de la misma familia: cualquier policy
#               bajo una rama Personalization, o cuyo nombre empiece con NoDisp /
#               NoChanging / NoThemes / Wallpaper. Se marca para que un bloqueo
#               nuevo no vuelva a pasar desapercibido.
#
# Recibe la salida de Get-RegTree (los objetos Key/Name), asi se puede correr
# contra un hive sembrado a mano.
# ---------------------------------------------------------------------------
function Get-SettingsBlockerFindings {
  param($Entries)
  $impacto = Get-SettingsBlockerImpact
  $out = New-Object System.Collections.Generic.List[object]
  # OJO CON EL foreach: se itera $Entries DIRECTO y no @($Entries). Medido en PS 5.1:
  # envolver un System.Collections.Generic.List[object] con @() tira "Argument types
  # do not match" -- con List[string] y con ArrayList funciona, con List[object] NO.
  # El foreach directo anda con array, con lista y con un objeto solo, y con $null no
  # itera. Esto revento el -Verify entero en el banco de pruebas antes de salir.
  foreach ($e in $Entries) {
    if (-not $e) { continue }
    $key  = "$($e.Key)"
    $name = "$($e.Name)"
    # 'Ruta' y NO 'Where': en una hashtable, .Where es un metodo intrinseco de
    # PowerShell y $f.Where devuelve el METODO, no el valor de la clave.
    $ruta = if ($name) { "$key\$name" } else { $key }

    # --- LISTA CONOCIDA (contrato 5.1) ---
    if ($key -match '\\Policies\\(.+\\)?Personalization(\\|$)') {
      $out.Add(@{ Level = 'FALLA'; Ruta = $ruta
        Text = "$ruta  ->  policy de Personalization: deja tema, color y lockscreen EN GRIS" }); continue
    }
    if ($key -match 'PersonalizationCSP(\\|$)') {
      $out.Add(@{ Level = 'FALLA'; Ruta = $ruta
        Text = "$ruta  ->  PersonalizationCSP: el usuario NO puede cambiar fondo ni lockscreen" }); continue
    }
    if ($name -and $impacto.ContainsKey($name)) {
      $out.Add(@{ Level = 'FALLA'; Ruta = $ruta
        Text = "$ruta  ->  $($impacto[$name])" }); continue
    }
    if ($key -match '\\Policies\\(.+\\)?Control Panel\\Desktop(\\|$)' -and $name -match '^Wallpaper') {
      $out.Add(@{ Level = 'FALLA'; Ruta = $ruta
        Text = "$ruta  ->  wallpaper impuesto por policy: el usuario no lo puede cambiar" }); continue
    }

    # --- LA CLASE, no la instancia ---
    if ($key -match 'Personalization') {
      $out.Add(@{ Level = 'SOSPECHA'; Ruta = $ruta
        Text = "$ruta  ->  policy bajo una rama Personalization que NO esta en la lista del contrato 5.1" }); continue
    }
    if ($name -match '^(NoDisp|NoChanging|NoThemes)') {
      $out.Add(@{ Level = 'SOSPECHA'; Ruta = $ruta
        Text = "$ruta  ->  se llama como las policies que bloquean paneles (NoDisp/NoChanging/NoThemes) y NO esta en la lista" }); continue
    }
    if ($name -match '^Wallpaper') {
      $out.Add(@{ Level = 'SOSPECHA'; Ruta = $ruta
        Text = "$ruta  ->  policy que impone el fondo de escritorio" }); continue
    }
  }
  return $out.ToArray()
}

# ---------------------------------------------------------------------------
# Escanea UNA rama de policies del hive cargado y devuelve el inventario: un item
# por valor, mas un item por clave VACIA.
#
# Las rutas se traducen del mount (HKEY_LOCAL_MACHINE\VRF_USR\...) a la ruta REAL
# del disco instalado (HKCU\...). Un reporte que nombra la ruta del mount obliga a
# traducir mentalmente y es asi como se leen mal los resultados.
# ---------------------------------------------------------------------------
function Get-PolicyBranchEntries {
  param(
    [Parameter(Mandatory)][string]$FullKey,      # la clave dentro del hive cargado
    [Parameter(Mandatory)][string]$MountPrefix,  # HKEY_LOCAL_MACHINE\VRF_USR
    [Parameter(Mandatory)][string]$RealPrefix,   # HKCU
    [Parameter(Mandatory)][string]$Label
  )
  $vals = @(Get-RegTree    -Key $FullKey -Recurse)
  $keys = @(Get-RegKeyList -Key $FullKey -Recurse)
  $rx   = '^' + [regex]::Escape($MountPrefix)
  $conValores = @($vals | ForEach-Object { $_.Key } | Sort-Object -Unique)
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($v in $vals) {
    $out.Add([pscustomobject]@{
      Branch = $Label; Name = $v.Name; Type = $v.Type; Data = $v.Data
      Key = ($v.Key -replace $rx, $RealPrefix)
    })
  }
  foreach ($k in $keys) {
    if ($conValores -contains $k) { continue }
    $out.Add([pscustomobject]@{
      Branch = $Label; Name = ''; Type = '(clave sin valores)'; Data = ''
      Key = ($k -replace $rx, $RealPrefix)
    })
  }
  return [pscustomobject]@{ Label = $Label; Entries = $out.ToArray(); Values = $vals.Count; Keys = $keys.Count }
}

# ---------------------------------------------------------------------------
# Una seccion de un .ini / .theme como diccionario ordenado. $null si no esta.
# ---------------------------------------------------------------------------
function Get-IniSection {
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Section)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $dentro = $false
  $res = [ordered]@{}
  foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
    $l = "$line".Trim()
    if ($l -match '^\[(.+)\]$') { $dentro = ($Matches[1] -eq $Section); continue }
    if (-not $dentro -or $l -eq '' -or $l.StartsWith(';')) { continue }
    $i = $l.IndexOf('=')
    if ($i -lt 1) { continue }
    $res[$l.Substring(0, $i).Trim()] = $l.Substring($i + 1).Trim()
  }
  if ($res.Count -eq 0) { return $null }
  return $res
}

# ---------------------------------------------------------------------------
# InstallTheme / InstallThemeLight en las DOS ramas (contrato 2.1 y 7.6).
#
# Si esta en una sola, el bug es SILENCIOSO: por la rama que quedo apuntando a
# aero.theme vuelve el azul de fabrica y nadie sabe por que. Por eso "esta en una
# de las dos" es FALLA y no un aviso.
# ---------------------------------------------------------------------------
function Get-InstallThemeFindings {
  param(
    [Parameter(Mandatory)][string]$SoftwareRoot,
    [Parameter(Mandatory)][string]$ExpectedPath,
    [bool]$ThemeExpected = $true
  )
  $out = New-Object System.Collections.Generic.List[object]
  $ramas = @('Microsoft\Windows\CurrentVersion\Themes',
             'WOW6432Node\Microsoft\Windows\CurrentVersion\Themes')
  $apuntan = @(); $noApuntan = @()
  foreach ($rama in $ramas) {
    foreach ($valor in @('InstallTheme', 'InstallThemeLight')) {
      $e = Get-RegEntry -Key "$SoftwareRoot\$rama" -Name $valor
      $dato = if ($e) { "$($e.Data)" } else { '' }
      $etiqueta = "$rama\$valor"
      if ($dato -and ($dato -eq $ExpectedPath)) { $apuntan += $etiqueta }
      else { $noApuntan += ("{0} = {1}" -f $etiqueta, $(if ($dato) { $dato } else { '(no existe)' })) }
      if ($dato) { $out.Add(@{ Level = 'info'; Text = ("{0} = {1}" -f $etiqueta, $dato) }) }
    }
  }
  if (-not $ThemeExpected) {
    if ($apuntan.Count -gt 0) {
      $out.Add(@{ Level = 'OJO'; Text = ('DE MAS: el perfil no pidio tema, acento ni wallpaper y aun asi ' +
          'InstallTheme apunta a LunaticOS.theme ({0} de 4 valores)' -f $apuntan.Count) })
    }
    else {
      $out.Add(@{ Level = 'OK'; Text = 'InstallTheme de fabrica: correcto, el perfil no pidio tema/acento/wallpaper' })
    }
    return $out.ToArray()
  }
  if ($apuntan.Count -eq 4) {
    $out.Add(@{ Level = 'OK'; Text = 'InstallTheme e InstallThemeLight apuntan a LunaticOS.theme en LAS DOS ramas' })
  }
  elseif ($apuntan.Count -eq 0) {
    $out.Add(@{ Level = 'FALLA'; Text = 'InstallTheme no apunta a LunaticOS.theme en NINGUNA rama: al crear el ' +
        'perfil Windows aplica aero.theme (Light + azul de fabrica) y el tema y el acento se pierden' })
  }
  else {
    $out.Add(@{ Level = 'FALLA'; Text = ('InstallTheme incompleto: {0} de 4 valores apuntan a LunaticOS.theme. ' -f $apuntan.Count) +
        'Falta ' + ($noApuntan -join ' ; ') + ' -- por esa rama vuelve el azul y el bug es SILENCIOSO' })
  }
  return $out.ToArray()
}

# ---------------------------------------------------------------------------
# ACTIVACION (contrato 5.4 y 6). Sin activar, Personalization esta en gris por
# LICENCIAMIENTO y no por culpa nuestra. Confundir esas dos causas es exactamente
# lo que ya nos paso, asi que el -Verify tiene que poder distinguirlas.
#
# OFFLINE NO SE PUEDE SABER si Windows quedo activado: el estado vive en
# tokens.dat y en HKLM\SYSTEM\WPA, que son blobs opacos. Aca se reporta la
# EVIDENCIA que si se puede leer y se dice claro que no alcanza. No se inventa
# un resultado: un "activado: OK" falso es peor que no medir nada.
#
# La clave de producto NO se imprime nunca (contrato 6: el perfil es compartible,
# la licencia no). Solo se dice si es una generica publica -- que fija la edicion
# y NO activa -- o si es propia.
# ---------------------------------------------------------------------------
function Get-ActivationFindings {
  param([Parameter(Mandatory)][string]$SoftwareRoot, [Parameter(Mandatory)][string]$Drive)
  $out = New-Object System.Collections.Generic.List[object]
  $cv = "$SoftwareRoot\Microsoft\Windows NT\CurrentVersion"
  $ed = Get-RegEntry -Key $cv -Name 'EditionID'
  $pn = Get-RegEntry -Key $cv -Name 'ProductName'
  $dv = Get-RegEntry -Key $cv -Name 'DisplayVersion'
  $out.Add(@{ Level = 'info'; Text = ('edicion: {0} / EditionID={1} / {2}' -f `
        $(if ($pn) { $pn.Data } else { '?' }), $(if ($ed) { $ed.Data } else { '?' }), $(if ($dv) { $dv.Data } else { '?' })) })

  # Claves genericas publicas: fijan la edicion durante el setup y NO activan.
  $genericas = @{
    'VK7JG-NPHTM-C97JM-9MPGT-3V66T' = 'Pro (generica publica)'
    '2B87N-8KFHP-DKV6R-Y2C8J-PKCKT' = 'Pro N (generica publica)'
    'YTMG3-N6DKC-DKB77-7M9GH-8HVX7' = 'Home (generica publica)'
    'NW6C2-QMPVW-D7KKK-3GKT6-VCFB2' = 'Education (generica publica)'
    'W269N-WFGWX-YVC9B-4J6C9-T83GX' = 'Enterprise (cliente KMS)'
  }
  $bk = Get-RegEntry -Key "$SoftwareRoot\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform" `
                     -Name 'BackupProductKeyDefault'
  if ($bk -and "$($bk.Data)".Trim()) {
    $k = "$($bk.Data)".Trim()
    if ($genericas.ContainsKey($k)) {
      $out.Add(@{ Level = 'OJO'; Text = ('la imagen se instalo con la clave {0}: fija la edicion y NO ACTIVA. ' -f $genericas[$k]) +
          'Personalization va a estar en gris por LICENCIAMIENTO, no por nuestras policies (contrato 5.4). ' +
          'Se arregla poniendo la clave real en clave-windows.txt (contrato 6), no con registro.' })
    }
    else {
      $out.Add(@{ Level = 'info'; Text = 'hay una clave de producto propia configurada (no la imprimo: la ' +
          'licencia no se loguea, contrato 6). Que active o no hay que confirmarlo DENTRO de la VM.' })
    }
  }
  else {
    $out.Add(@{ Level = 'info'; Text = 'no hay BackupProductKeyDefault en el hive SOFTWARE' })
  }

  $tok = "$Drive\Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\WSLicense\tokens.dat"
  if (Test-Path -LiteralPath $tok) {
    $out.Add(@{ Level = 'info'; Text = ('tokens.dat presente ({0:N0} bytes). Es el store de licencias, ' -f (Get-Item -LiteralPath $tok).Length) +
        'pero es un blob opaco: su presencia NO prueba activacion.' })
  }
  else {
    $out.Add(@{ Level = 'info'; Text = 'no hay tokens.dat (el store de licencias todavia no se creo)' })
  }

  $out.Add(@{ Level = 'OJO'; Text = 'LA ACTIVACION NO SE PUEDE MEDIR OFFLINE. El estado vive en tokens.dat y en ' +
      'HKLM\SYSTEM\WPA (blobs opacos), y PowerShell Direct no sirve con password vacio (ver el header de este ' +
      'archivo). NO invento un resultado: si Personalization sale en gris, corre ESTO dentro de la VM antes de ' +
      'culpar al debloat:  slmgr /xpr' })
  return $out.ToArray()
}

# ---------------------------------------------------------------------------
# Que pidio el perfil, deducido de los VALORES que escriben los items del catalogo
# y NO de sus Key. Un test que busca la key 'tema-oscuro' da verde el dia que
# alguien la renombre o agregue 'tema-claro'. La definicion real de "oscuro" es
# AppsUseLightTheme/SystemUsesLightTheme = 0: eso es la clase.
# ---------------------------------------------------------------------------
function Get-VerifyRequestedMode {
  param($Items)
  $modo = ''
  # Iteracion directa, sin @(): ver la nota de Get-SettingsBlockerFindings.
  foreach ($it in $Items) {
    foreach ($r in $it.Regs) {
      if (-not $r) { continue }
      if (@('AppsUseLightTheme', 'SystemUsesLightTheme') -contains "$($r.v)") {
        $modo = if ("$($r.d)" -eq '0') { 'Dark' } else { 'Light' }
      }
    }
  }
  return $modo
}

# El acento pedido sale de la PROPIEDAD Accent del item (contrato 1.3), no de un
# patron sobre la Key: 'acento-en-taskbar' empieza igual y NO es un color.
function Get-VerifyRequestedAccent {
  param($Items)
  $a = @($Items | Where-Object { $_.Accent })
  if ($a.Count -gt 0) { return "$($a[0].Accent)" }
  return ''
}

# Imprime un finding con el color que le corresponde al nivel.
function Write-Finding {
  param($Finding)
  $lvl = "$($Finding.Level)"
  $color = switch ($lvl) {
    'OK'       { 'Green' }
    'FALLA'    { 'Red' }
    'SOSPECHA' { 'Magenta' }
    'OJO'      { 'Yellow' }
    default    { 'DarkGray' }
  }
  Write-Host ("  {0,-9} {1}" -f $lvl, $Finding.Text) -ForegroundColor $color
}

# ---------------------------------------------------------------------------
# Dot-source = SOLO cargar las funciones, sin tocar ninguna VM. Es lo que hace
# posible probar los chequeos contra hives sembrados a mano (mismo patron que
# 10-personalizar.ps1). InvocationName vale '.' unicamente al dot-sourcear.
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -eq '.') { return }

if (-not ($Create -or $Reset -or $Boot -or $Shot -or $Verify -or $Enter -or $Destroy)) {
  Write-Host "Nada que hacer. Usa -Create / -Reset / -Boot / -Enter / -Shot / -Verify / -Destroy" -ForegroundColor Yellow
  Write-Host "Flujo tipico:  .\test-vm.ps1 -Create -Boot   ->  un clic en Next  ->  -Shot  ->  -Verify" -ForegroundColor DarkGray
  return
}

# --------------------------------------------------------------------------
# DESTROY: borrar la VM y su disco
# --------------------------------------------------------------------------
if ($Destroy) {
  $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
  if ($vm) {
    if ($vm.State -ne 'Off') { Stop-VM -Name $VMName -TurnOff -Force; Start-Sleep -Seconds 3 }
    Remove-VM -Name $VMName -Force
    Write-Host "  VM $VMName borrada" -ForegroundColor Green
  } else { Write-Host "  (no existe la VM $VMName)" -ForegroundColor DarkGray }
  if (Test-Path $vhdx) { Remove-Item $vhdx -Force; Write-Host "  VHDX borrado" -ForegroundColor Green }
  return
}

# --------------------------------------------------------------------------
# CREATE: VM nueva, Gen2, con TPM 2.0 y Secure Boot
# --------------------------------------------------------------------------
if ($Create) {
  Write-Host "== Creando la VM $VMName ==" -ForegroundColor Cyan
  if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: no esta el modulo de Hyper-V. Activalo con:" -ForegroundColor Red
    Write-Host "  Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All" -ForegroundColor Yellow
    exit 1
  }
  if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    Write-Host "  la VM ya existe -> uso -Reset para dejarla en cero" -ForegroundColor Yellow
  } else {
    if (Test-Path $vhdx) { Remove-Item $vhdx -Force }
    New-Item -ItemType Directory -Force -Path (Split-Path $vhdx) | Out-Null

    # GENERACION 2 obligatoria: Gen1 no tiene UEFI, y sin UEFI no hay Secure Boot
    # ni TPM. Windows 11 no instala, y Vanguard tampoco arranca (regla D5).
    New-VM -Name $VMName -Generation 2 -MemoryStartupBytes ($RamGB * 1GB) `
           -NewVHDPath $vhdx -NewVHDSizeBytes ($DiskGB * 1GB) | Out-Null
    Set-VM -Name $VMName -ProcessorCount $Cpus -AutomaticCheckpointsEnabled $false
    Write-Host "  VM creada: Gen2, $RamGB GB RAM, $Cpus vCPU, VHDX $DiskGB GB dinamico" -ForegroundColor Green

    # Red: el Default Switch da internet por NAT sin configurar nada. Hace falta,
    # porque los programas se instalan por winget en el primer arranque.
    $sw = Get-VMSwitch -Name 'Default Switch' -ErrorAction SilentlyContinue
    if ($sw) { Connect-VMNetworkAdapter -VMName $VMName -SwitchName 'Default Switch'; Write-Host "  red: Default Switch (NAT con internet)" -ForegroundColor Green }
    else     { Write-Host "  ! sin 'Default Switch': la VM va a quedar sin internet y winget no va a poder instalar nada" -ForegroundColor Yellow }
  }

  # Secure Boot + TPM: sin esto el test NO representa a la maquina real.
  Set-VMFirmware -VMName $VMName -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
  try {
    $sec = Get-VMSecurity -VMName $VMName
    if (-not $sec.TpmEnabled) {
      if (-not $sec.KeyProtector -or $sec.KeyProtector.Length -le 4) {
        Set-VMKeyProtector -VMName $VMName -NewLocalKeyProtector
      }
      Enable-VMTPM -VMName $VMName
    }
  } catch { Write-Host "  ! no pude habilitar TPM: $($_.Exception.Message)" -ForegroundColor Yellow }

  $fw = Get-VMFirmware -VMName $VMName; $sec = Get-VMSecurity -VMName $VMName
  Write-Host "  SecureBoot=$($fw.SecureBoot)  TPM=$($sec.TpmEnabled)" -ForegroundColor Green
  if (-not $Reset) { $Reset = $true }   # recien creada: hay que ponerle la ISO igual
}

# --------------------------------------------------------------------------
# ENTER: una sola tecla. El setup pide confirmar el disco a mano (a proposito, D14).
# --------------------------------------------------------------------------
if ($Enter) {
  $vmc = Get-VmCim
  $kbd = Get-CimAssociatedInstance -InputObject $vmc -ResultClassName Msvm_Keyboard -ErrorAction SilentlyContinue
  if (-not $kbd) { Write-Host "ERROR: no encontre el Msvm_Keyboard de la VM" -ForegroundColor Red; exit 1 }
  Invoke-CimMethod -InputObject $kbd -MethodName TypeKey -Arguments @{ keyCode = [uint16]0x0D } | Out-Null
  Write-Host "Enter enviado." -ForegroundColor Green
}

# --------------------------------------------------------------------------
# RESET: VHDX en blanco, ISO montada, DVD primero en el boot order
# --------------------------------------------------------------------------
if ($Reset) {
  Write-Host "== Reset de la VM $VMName ==" -ForegroundColor Cyan
  if (-not (Test-Path $iso)) { Write-Host "ERROR: no existe $iso" -ForegroundColor Red; exit 1 }

  $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
  if (-not $vm) { Write-Host "ERROR: no existe la VM '$VMName'." -ForegroundColor Red; exit 1 }

  if ($vm.State -ne 'Off') {
    Write-Host "  apagando la VM (force)..."
    Stop-VM -Name $VMName -TurnOff -Force
    Start-Sleep -Seconds 3
  }

  # VHDX desde cero: una instalacion sobre restos de la anterior no prueba nada.
  Get-VMHardDiskDrive -VMName $VMName | Remove-VMHardDiskDrive
  if (Test-Path $vhdx) { Remove-Item $vhdx -Force; Write-Host "  VHDX viejo borrado" }
  New-VHD -Path $vhdx -SizeBytes 64GB -Dynamic | Out-Null
  Add-VMHardDiskDrive -VMName $VMName -Path $vhdx
  Write-Host "  VHDX nuevo: 64 GB dinamico" -ForegroundColor Green

  # DVD con la ISO recien generada
  if (-not (Get-VMDvdDrive -VMName $VMName)) { Add-VMDvdDrive -VMName $VMName }
  Set-VMDvdDrive -VMName $VMName -Path $iso
  $dvd = Get-VMDvdDrive -VMName $VMName
  Set-VMFirmware -VMName $VMName -FirstBootDevice $dvd
  Write-Host "  DVD -> $(Split-Path $iso -Leaf) (primero en el boot order)" -ForegroundColor Green

  # Requisitos de Windows 11 y de Vanguard (regla de oro D5): sin esto el test no
  # representa a la maquina real.
  $fw = Get-VMFirmware -VMName $VMName
  if ($fw.SecureBoot -ne 'On') {
    Set-VMFirmware -VMName $VMName -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
  }
  $tpm = Get-VMSecurity -VMName $VMName
  if (-not $tpm.TpmEnabled) {
    try {
      if (-not $tpm.KeyProtector -or $tpm.KeyProtector.Length -le 4) {
        Set-VMKeyProtector -VMName $VMName -NewLocalKeyProtector
      }
      Enable-VMTPM -VMName $VMName
    } catch { Write-Host "  ! no pude habilitar TPM: $($_.Exception.Message)" -ForegroundColor Yellow }
  }
  $fw  = Get-VMFirmware -VMName $VMName
  $sec = Get-VMSecurity  -VMName $VMName
  Write-Host "  SecureBoot=$($fw.SecureBoot)  TPM=$($sec.TpmEnabled)" -ForegroundColor Green
  Write-Host "Reset OK." -ForegroundColor Green
}

# --------------------------------------------------------------------------
# BOOT: arrancar y pasar el prompt "Press any key"
# --------------------------------------------------------------------------
if ($Boot) {
  Write-Host "== Arrancando $VMName ==" -ForegroundColor Cyan
  if ((Get-VM -Name $VMName).State -ne 'Running') { Start-VM -Name $VMName }

  # NO SAQUES ESTE LOOP. Es lo unico que pasa el prompt "Press any key to boot from
  # CD or DVD"; sin el, el boot muere con "The boot loader failed" (probado a la mala).
  # Y TIENE que cortar despues del primer boot: Windows reinicia varias veces durante
  # el setup y, si seguimos mandando Enter, cada reinicio vuelve a bootear del DVD y
  # el instalador arranca de cero. Loop infinito -- justo lo que el prompt evita (D17).
  $vmc = Get-VmCim
  $kbd = Get-CimAssociatedInstance -InputObject $vmc -ResultClassName Msvm_Keyboard -ErrorAction SilentlyContinue
  if (-not $kbd) {
    Write-Host "  ! no encontre el Msvm_Keyboard: vas a tener que apretar una tecla a mano" -ForegroundColor Yellow
  } else {
    Write-Host "  mandando Enter ${KeySeconds}s para pasar el prompt de boot..."
    Write-Host "  (y NI UNO MAS, o cada reinicio del setup vuelve a bootear del DVD)" -ForegroundColor DarkGray
    $deadline = (Get-Date).AddSeconds($KeySeconds)
    while ((Get-Date) -lt $deadline) {
      try { Invoke-CimMethod -InputObject $kbd -MethodName TypeKey -Arguments @{ keyCode = [uint16]0x0D } | Out-Null } catch { }
      Start-Sleep -Milliseconds 500
    }
    Write-Host "  teclado liberado: el setup sigue solo." -ForegroundColor Green
  }
  Write-Host ""
  Write-Host "  ACCION MANUAL REQUERIDA (una sola, ver el header):" -ForegroundColor Yellow
  Write-Host "    1. Abri la consola:  vmconnect.exe localhost $VMName" -ForegroundColor Yellow
  Write-Host "    2. En 'Select location to install Windows 11' -> clic en Next" -ForegroundColor Yellow
  Write-Host "       El teclado sintetico NO funciona ahi. Tiene que ser un clic." -ForegroundColor DarkGray
  Write-Host ""
  Write-Host "  Despues sigue solo (~20-30 min). Progreso:  .\test-vm.ps1 -Shot"
  Write-Host "  Cuando termine:  Stop-VM $VMName  y luego  .\test-vm.ps1 -Verify"
}

# --------------------------------------------------------------------------
# SHOT: screenshot de la VM (sin pedirle capturas al usuario)
# --------------------------------------------------------------------------
if ($Shot) {
  Add-Type -AssemblyName System.Drawing
  # OJO: aca se usa WMI y no CIM a proposito. GetVirtualSystemThumbnailImage recibe el
  # TargetSystem por REFERENCIA, e Invoke-CimMethod no sabe convertir un [ref]CimInstance
  # a InstanceHandle: revienta con "Unable to cast object of type PSReference". Con
  # Get-WmiObject se pasa el __PATH como string y funciona.
  $vmw  = Get-WmiObject -Namespace $ns -Class Msvm_ComputerSystem -Filter "ElementName='$VMName'"
  $mgmt = Get-WmiObject -Namespace $ns -Class Msvm_VirtualSystemManagementService

  # La resolucion se le PREGUNTA a la VM, no se asume. Pedir un tamano que el video
  # head no tiene devuelve un buffer de largo distinto al que espera el bitmap, y el
  # Marshal.Copy se va de rango: AccessViolationException y muere el proceso entero.
  $vh = $vmw.GetRelated('Msvm_VideoHead') | Select-Object -First 1
  if ($vh -and $vh.CurrentHorizontalResolution -and $vh.CurrentVerticalResolution) {
    $w = [int]$vh.CurrentHorizontalResolution
    $h = [int]$vh.CurrentVerticalResolution
  } else {
    $w = 1024; $h = 768   # sin video head activo (VM recien arrancada): valor tipico
  }

  # El thumbnail se pide contra el SETTING DATA activo, no contra el ComputerSystem.
  $set  = $vmw.GetRelated('Msvm_VirtualSystemSettingData', 'Msvm_SettingsDefineState',
                          $null, $null, $null, $null, $false, $null) | Select-Object -First 1
  $res  = $mgmt.GetVirtualSystemThumbnailImage($set.__PATH, $w, $h)
  if (-not $res.ImageData) { Write-Host "ERROR: sin imagen (la VM esta apagada?)" -ForegroundColor Red; exit 1 }

  # El buffer viene en RGB565: 2 bytes por pixel. Hay que declararlo asi o sale basura.
  $bytes = [byte[]]$res.ImageData
  $bmp  = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
  $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
  $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
                        [System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
  # Guarda: nunca copiar mas de lo que entra en el bitmap. Si Hyper-V devolvio otro
  # tamano, preferimos una imagen parcial antes que corromper memoria.
  $capacity = $data.Stride * $h
  $len = [Math]::Min($bytes.Length, $capacity)
  if ($bytes.Length -ne $capacity) {
    Write-Host ("  ! buffer {0} bytes vs bitmap {1} ({2}x{3}) - copio {4}" -f `
                $bytes.Length, $capacity, $w, $h, $len) -ForegroundColor Yellow
  }
  [System.Runtime.InteropServices.Marshal]::Copy($bytes, 0, $data.Scan0, $len)
  $bmp.UnlockBits($data)
  $out = Join-Path $env:TEMP ("vm-{0}.png" -f (Get-Date -Format 'HHmmss'))
  $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  Write-Host "screenshot: $out" -ForegroundColor Green
}

# --------------------------------------------------------------------------
# VERIFY: auditar el disco instalado (VM APAGADA)
# --------------------------------------------------------------------------
if ($Verify) {
  Write-Host "== Auditoria del disco instalado ==" -ForegroundColor Cyan
  if ((Get-VM -Name $VMName).State -ne 'Off') {
    Write-Host "ERROR: apaga la VM primero (Stop-VM $VMName). Montar el VHDX de una VM" -ForegroundColor Red
    Write-Host "       encendida corrompe el disco." -ForegroundColor Red
    exit 1
  }

  $img = Mount-DiskImage -ImagePath $vhdx -Access ReadOnly -PassThru
  try {
    # La particion de Windows es la mas grande con letra asignada.
    $vol = $img | Get-Disk | Get-Partition | Get-Volume |
             Where-Object { $_.DriveLetter } | Sort-Object Size -Descending | Select-Object -First 1
    $d = "$($vol.DriveLetter):"
    Write-Host "  Windows montado en $d" -ForegroundColor DarkGray

    # OJO: el criterio cambio con D21. Edge SI puede estar en disco -- de hecho va a
    # estar, porque Windows Update lo trae junto con WebView2 (mismo instalador). Lo
    # que se verifica es que NO PUEDA EJECUTARSE y que NO SE VEA. Verificar "ausencia
    # de Edge" seria medir contra un objetivo que ya descartamos.
    Write-Host "`n--- IFEO: el navegador NO debe poder ejecutarse (esto es el fix real) ---" -ForegroundColor Cyan
    & reg.exe load HKLM\VRF_SW "$d\Windows\System32\config\SOFTWARE" 2>&1 | Out-Null
    $ifeo = 'HKLM\VRF_SW\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
    foreach ($e in @('msedge.exe','msedge_proxy.exe','msedge_pwa_launcher.exe')) {
      $q = (& reg.exe query "$ifeo\$e" /v Debugger 2>&1) -join "`n"
      if ($q -match 'Debugger') { Write-Host "  OK: $e bloqueado" -ForegroundColor Green }
      else                      { Write-Host "  FALLO: $e SIN bloqueo -> Edge se puede abrir" -ForegroundColor Red }
    }
    # WebView2 tiene que quedar LIBRE: si lo bloqueamos, se rompen la Store y Widgets.
    $q = (& reg.exe query "$ifeo\msedgewebview2.exe" /v Debugger 2>&1) -join "`n"
    if ($q -match 'Debugger') { Write-Host "  FALLO: msedgewebview2.exe bloqueado (rompe Store/Widgets)" -ForegroundColor Red }
    else                      { Write-Host "  OK: msedgewebview2.exe libre (correcto)" -ForegroundColor Green }
    & reg.exe unload HKLM\VRF_SW 2>&1 | Out-Null

    Write-Host "`n--- ACCESOS DIRECTOS de Edge: no deben verse ---" -ForegroundColor Cyan
    $lnks = @("$d\Users\Public\Desktop\Microsoft Edge.lnk",
              "$d\ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk")
    Get-ChildItem "$d\Users" -Directory -Force -EA SilentlyContinue | ForEach-Object {
      $lnks += "$($_.FullName)\Desktop\Microsoft Edge.lnk"
      $lnks += "$($_.FullName)\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk"
    }
    $vis = @($lnks | Select-Object -Unique | Where-Object { Test-Path $_ })
    if ($vis) { $vis | ForEach-Object { Write-Host "  QUEDO VISIBLE: $_" -ForegroundColor Yellow } }
    else      { Write-Host "  OK: ningun acceso directo de Edge" -ForegroundColor Green }

    Write-Host "`n--- WEBVIEW2: debe estar PRESENTE (si falta, Store y Widgets se rompen) ---" -ForegroundColor Cyan
    $wv = "$d\Program Files (x86)\Microsoft\EdgeWebView\Application"
    if (Test-Path $wv) { Write-Host "  OK: $wv" -ForegroundColor Green }
    else               { Write-Host "  FALLO: falta WebView2" -ForegroundColor Red }

    Write-Host "`n--- SERVICIOS edgeupdate: deben estar VIVOS (mantienen WebView2) ---" -ForegroundColor Cyan
    & reg.exe load HKLM\VRF_SYS "$d\Windows\System32\config\SYSTEM" 2>&1 | Out-Null
    foreach ($s in @('edgeupdate','edgeupdatem')) {
      $q = (& reg.exe query "HKLM\VRF_SYS\ControlSet001\Services\$s" /v Start 2>&1) -join "`n"
      $v = if ($q -match '0x(\d)') { $Matches[1] } else { '?' }
      switch ($v) {
        '2' { Write-Host "  OK: $s Automatic" -ForegroundColor Green }
        '3' { Write-Host "  OK: $s Manual" -ForegroundColor Green }
        '4' { Write-Host "  FALLO: $s Disabled -> WebView2 se queda sin parches" -ForegroundColor Red }
        default { Write-Host "  (no existe el servicio $s)" -ForegroundColor DarkGray }
      }
    }
    & reg.exe unload HKLM\VRF_SYS 2>&1 | Out-Null

    Write-Host "`n--- SERVICIOS de la fase 4: muestra (deben estar Disabled=0x4) ---" -ForegroundColor Cyan
    & reg.exe load HKLM\VRF_SY2 "$d\Windows\System32\config\SYSTEM" 2>&1 | Out-Null
    foreach ($s in @('DiagTrack','wisvc','SEMgrSvc','PushToInstall','PcaSvc','lfsvc')) {
      $q = (& reg.exe query "HKLM\VRF_SY2\ControlSet001\Services\$s" /v Start 2>&1) -join "`n"
      $v = if ($q -match '0x(\d)') { $Matches[1] } else { '?' }
      if ($v -eq '4') { Write-Host "  OK: $s Disabled" -ForegroundColor Green }
      else            { Write-Host "  OJO: $s Start=$v (esperado 4)" -ForegroundColor Yellow }
    }
    & reg.exe unload HKLM\VRF_SY2 2>&1 | Out-Null

    Write-Host "`n--- EDGEUPDATE corrio? (ahora es ESPERADO: mantiene WebView2) ---" -ForegroundColor Cyan
    $log = "$d\ProgramData\Microsoft\EdgeUpdate\Log\MicrosoftEdgeUpdate.log"
    if (Test-Path $log) {
      # Lo que importa no es que corra, sino CON QUE installsource. 'windowsupdate_zdp'
      # es Windows Update empujando el paquete; 'core'/'scheduler' es mantenimiento normal.
      $src = Select-String -Path $log -Pattern 'installsource (\w+)' -AllMatches |
               ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } |
               Group-Object | Sort-Object Count -Descending
      Write-Host "  EdgeUpdate corrio (esperado). installsource visto:" -ForegroundColor DarkGray
      $src | ForEach-Object { Write-Host ("    {0,-22} x{1}" -f $_.Name, $_.Count) }
    } else {
      Write-Host "  no hay log -> EdgeUpdate no corrio (WebView2 no se va a actualizar)" -ForegroundColor Yellow
    }

    Write-Host "`n--- UNATTEND: se proceso? ---" -ForegroundColor Cyan
    if (Test-Path "$d\Windows\Panther\unattend.xml") {
      Write-Host "  OK: existe Panther\unattend.xml (el unattend se aplico)" -ForegroundColor Green
    } else {
      Write-Host "  FALLO: no existe Panther\unattend.xml -> el unattend se descarto (ver D14)" -ForegroundColor Red
    }

    Write-Host "`n--- ERRORES del setup ---" -ForegroundColor Cyan
    $err = "$d\Windows\Panther\setuperr.log"
    if ((Test-Path $err) -and (Get-Item $err).Length -gt 0) {
      Get-Content $err -Tail 15 | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    } else { Write-Host "  sin errores registrados" -ForegroundColor Green }

    Write-Host "`n--- PERFILES de usuario (deberia estar 'pato') ---" -ForegroundColor Cyan
    Get-ChildItem "$d\Users" -Directory -Force -EA SilentlyContinue |
      Where-Object { $_.Name -notin @('Public','Default','Default User','All Users') } |
      ForEach-Object { Write-Host "  $($_.Name)" }

    # ------------------------------------------------------------------------
    #  PERSONALIZACION: lo que pidio el perfil vs lo que quedo en el hive
    # ------------------------------------------------------------------------
    # Esto es lo que distingue "Windows lo ignoro" de "nuestro script no lo escribio".
    # Sin este chequeo, un tema que no se aplica es indistinguible de un bug propio.
    Write-Host "`n--- PERSONALIZACION: perfil vs hive del usuario ---" -ForegroundColor Cyan
    $perfilPath = Join-Path $CFG.Root 'perfil.json'
    $pers = $null
    if (Test-Path $perfilPath) {
      try { $pers = (Get-Content $perfilPath -Raw | ConvertFrom-Json).personalizacion } catch { }
    }

    # El perfil.json guarda SOLO booleanos por Key: el hex del acento vive en el
    # catalogo. Sin el catalogo no hay contra que comparar el color, asi que se carga
    # (es un archivo de datos: define variables y no tiene efectos).
    $catPath = Join-Path $CFG.Root 'config\personalizacion.ps1'
    if (Test-Path $catPath) { . $catPath }
    $pickedItems = @()
    if ($pers -and $Global:PersonalizacionCatalog) {
      $pickedKeys  = @($pers.PSObject.Properties | Where-Object { $_.Value } | ForEach-Object { $_.Name })
      $pickedItems = @($Global:PersonalizacionCatalog | Where-Object { $pickedKeys -contains $_.Key })
    }
    $wantMode   = Get-VerifyRequestedMode   $pickedItems
    $wantAccent = Get-VerifyRequestedAccent $pickedItems

    # Wallpaper propio: se mira la MISMA carpeta que mira la fase 10, con el mismo
    # Get-ChildItem 'ruta\*' (con -Include y sin \* no filtra NADA y "no hay
    # wallpaper" sale mentira).
    $wpDirHost = Join-Path $CFG.Root $(if ($Global:WallpaperDir) { $Global:WallpaperDir } else { 'config\wallpaper' })
    $wantWp = ''
    if (Test-Path $wpDirHost) {
      $wpFile = Get-ChildItem (Join-Path $wpDirHost '*') -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.Extension -match '^\.(jpg|jpeg|png)$' } | Select-Object -First 1
      if ($wpFile) { $wantWp = $wpFile.Name }
    }
    # La fase 10 genera el .theme si hay tema, acento O wallpaper. Misma condicion aca:
    # si el instrumento usa otro criterio que el producto, mide otra cosa.
    $themeExpected = [bool]($wantMode -or $wantAccent -or $wantWp)
    Write-Host ("  el perfil pidio: tema={0} acento={1} wallpaper={2}" -f `
                $(if ($wantMode) { $wantMode } else { '(sin eleccion)' }),
                $(if ($wantAccent) { $wantAccent } else { '(ninguno)' }),
                $(if ($wantWp) { $wantWp } else { '(ninguno)' })) -ForegroundColor DarkGray
    if ($pickedItems.Count -eq 0) {
      Write-Host "  ! no pude resolver el perfil contra el catalogo: sin perfil.json o sin catalogo" -ForegroundColor Yellow
    }

    # Acumuladores del inventario de policies (contrato 7.7): se llenan desde los DOS
    # hives y se vuelcan juntos al final. Un solo archivo, un solo juicio.
    $polEntries  = New-Object System.Collections.Generic.List[object]
    $polSummary  = New-Object System.Collections.Generic.List[object]
    # Si un hive no se puede leer, el veredicto NO puede salir en verde: se anota
    # aca y el juicio final dice "SIN MEDIR". Un OK que en realidad es "no mire"
    # es peor que no tener el chequeo: es la mentira que ya nos costo un build.
    $scanErrors  = New-Object System.Collections.Generic.List[string]
    $script:hiveAppsLight = $null
    $script:hiveSysLight  = $null

    $userHive = Get-ChildItem "$d\Users" -Directory -Force -EA SilentlyContinue |
                  Where-Object { $_.Name -notin @('Public','Default','Default User','All Users','defaultuser0') } |
                  ForEach-Object { Join-Path $_.FullName 'NTUSER.DAT' } |
                  Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $userHive) {
      Write-Host "  (no encontre NTUSER.DAT de un usuario real)" -ForegroundColor Yellow
    } else {
      # Use-OfflineHive y NO un reg load/unload suelto: garantiza el unload aunque
      # algo de aca adentro reviente. Un hive que queda cargado BLOQUEA el VHDX, y
      # ahora este bloque hace bastante mas que cuatro queries.
      #
      # El try/catch es para que un hive ilegible no se lleve puesta la auditoria
      # entera -- pero se ANOTA el error: lo que no se pudo leer NO se da por bueno.
      try {
      Use-OfflineHive -HivePath $userHive -MountKey 'VRF_USR' -Action {
        param($root)
        function RegVal($sub, $name) {
          $q = (& reg.exe query "$root\$sub" /v $name 2>&1) -join "`n"
          if ($q -match '0x([0-9a-fA-F]+)') { return [Convert]::ToInt32($Matches[1], 16) }
          if ($q -match "$name\s+REG_SZ\s+(.*)")  { return $Matches[1].Trim() }
          return $null
        }
        $themes = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        $adv    = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

        $checks = @(
          @{ key='tema-oscuro';       desc='tema oscuro';           got=(RegVal $themes 'AppsUseLightTheme'); want=0 }
          @{ key='sin-transparencia'; desc='sin transparencia';     got=(RegVal $themes 'EnableTransparency'); want=0 }
          @{ key='taskbar-izquierda'; desc='taskbar a la izquierda';got=(RegVal $adv 'TaskbarAl');            want=0 }
          @{ key='reloj-segundos';    desc='segundos en el reloj';  got=(RegVal $adv 'ShowSecondsInSystemClock'); want=1 }
          @{ key='explorer-compacto'; desc='explorer compacto';     got=(RegVal $adv 'UseCompactMode');       want=1 }
          @{ key='acento-en-taskbar'; desc='acento en taskbar';     got=(RegVal $themes 'ColorPrevalence');   want=1 }
        )
        foreach ($c in $checks) {
          $pedido = if ($pers -and $null -ne $pers.($c.key)) { [bool]$pers.($c.key) } else { $null }
          $escrito = ($c.got -eq $c.want)
          if ($null -eq $pedido) { Write-Host ("  (no esta en el perfil) {0}" -f $c.desc) -ForegroundColor DarkGray; continue }
          if ($pedido -and $escrito) {
            Write-Host ("  OK       {0}: pedido y ESCRITO en el hive" -f $c.desc) -ForegroundColor Green
          } elseif ($pedido -and -not $escrito) {
            Write-Host ("  NO PEGO  {0}: lo pediste y el hive tiene {1} (esperado {2})" -f $c.desc, $c.got, $c.want) -ForegroundColor Red
          } elseif (-not $pedido -and $escrito) {
            Write-Host ("  DE MAS   {0}: NO lo pediste y quedo aplicado" -f $c.desc) -ForegroundColor Yellow
          } else {
            Write-Host ("  ok       {0}: no pedido, no aplicado" -f $c.desc) -ForegroundColor DarkGray
          }
        }
        # Menu contextual clasico: es la EXISTENCIA de la clave, no un valor
        $clsid = 'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
        & reg.exe query "$root\$clsid" 2>&1 | Out-Null
        $menuOk = ($LASTEXITCODE -eq 0)
        if ($pers -and $null -ne $pers.'menu-clasico') {
          if ([bool]$pers.'menu-clasico' -eq $menuOk) { Write-Host ("  OK       menu contextual clasico (clave presente={0})" -f $menuOk) -ForegroundColor Green }
          else { Write-Host ("  NO PEGO  menu contextual clasico: pedido={0} presente={1}" -f [bool]$pers.'menu-clasico', $menuOk) -ForegroundColor Red }
        }

        # El modo que quedo escrito en el hive: se compara contra el .theme mas abajo.
        $script:hiveAppsLight = RegVal $themes 'AppsUseLightTheme'
        $script:hiveSysLight  = RegVal $themes 'SystemUsesLightTheme'

        # ------------------------------------------------------------------
        #  COLOR REAL DEL ACENTO (contrato 7.8) -- el test que faltaba.
        # ------------------------------------------------------------------
        Write-Host "`n--- ACENTO: el color REAL del hive vs el que pidio el perfil ---" -ForegroundColor Cyan
        $dwm      = 'Software\Microsoft\Windows\DWM'
        $accentK  = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'
        $eAccent  = Get-RegEntry -Key "$root\$dwm"     -Name 'AccentColor'
        $eColor   = Get-RegEntry -Key "$root\$dwm"     -Name 'ColorizationColor'
        $eMenu    = Get-RegEntry -Key "$root\$accentK" -Name 'AccentColorMenu'
        $ePal     = Get-RegEntry -Key "$root\$accentK" -Name 'AccentPalette'
        $palBytes = if ($ePal) { Convert-HexStringToBytes $ePal.Data } else { @() }

        if (@($palBytes).Count -ge 4) {
          $tonos = Get-AccentPaletteColors $palBytes
          Write-Host ("  info      AccentPalette ({0} bytes): {1}" -f @($palBytes).Count, ($tonos -join ' ')) -ForegroundColor DarkGray
          Write-Host  "            (indice 3 = el acento base; el 7 es el verde fijo #107C10 de Windows)" -ForegroundColor DarkGray
        }
        # Lo que HAY, siempre en hex y siempre visible, pidiera o no el perfil un
        # acento: el veredicto viene abajo, pero el dato crudo no se esconde nunca.
        foreach ($vc in @(@{ n = 'DWM\AccentColor'; e = $eAccent; l = 'ABGR' },
                          @{ n = 'DWM\ColorizationColor'; e = $eColor; l = 'ARGB' },
                          @{ n = 'Accent\AccentColorMenu'; e = $eMenu; l = 'ABGR' })) {
          $u = Get-RegU32 $vc.e
          if ($null -eq $u) { Write-Host ("  info      {0}: no existe en el hive" -f $vc.n) -ForegroundColor DarkGray; continue }
          $c = Convert-DwordToColor -Dword $u -Layout $vc.l
          Write-Host ("  info      {0} = {1}  ({2} leido como {3})" -f $vc.n, $c.Hex, $c.Raw, $vc.l) -ForegroundColor DarkGray
        }

        if (-not $wantAccent) {
          Write-Host "  info      el perfil no pidio acento: no hay nada que comparar (arriba esta lo que quedo)" -ForegroundColor DarkGray
        } else {
          foreach ($f in (Test-AccentAlignment -WantHex $wantAccent `
                            -PaletteBytes $palBytes `
                            -AccentColor       (Get-RegU32 $eAccent) `
                            -ColorizationColor (Get-RegU32 $eColor) `
                            -AccentColorMenu   (Get-RegU32 $eMenu))) { Write-Finding $f }
        }

        # ------------------------------------------------------------------
        #  Policies del hive de USUARIO: inventario (se juzga al final)
        # ------------------------------------------------------------------
        foreach ($br in @(
            @{ Label = 'HKCU\Software\Policies';                                 Sub = 'Software\Policies' }
            @{ Label = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies'; Sub = 'Software\Microsoft\Windows\CurrentVersion\Policies' }
          )) {
          $r = Get-PolicyBranchEntries -FullKey "$root\$($br.Sub)" `
                 -MountPrefix 'HKEY_LOCAL_MACHINE\VRF_USR' -RealPrefix 'HKCU' -Label $br.Label
          foreach ($e in $r.Entries) { $polEntries.Add($e) }
          $polSummary.Add([pscustomobject]@{ Label = $r.Label; Values = $r.Values; Keys = $r.Keys })
        }
      }
      }
      catch {
        $scanErrors.Add('el hive de usuario (NTUSER.DAT)')
        Write-Host ("  ! no pude leer el hive de usuario: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-Host  "    si quedo uno cargado de una corrida que murio:  reg unload HKLM\VRF_USR" -ForegroundColor Yellow
      }
    }

    # ------------------------------------------------------------------------
    #  TEMA: el .theme generado + InstallTheme en las DOS ramas (contrato 2 y 7)
    # ------------------------------------------------------------------------
    Write-Host "`n--- TEMA: LunaticOS.theme e InstallTheme ---" -ForegroundColor Cyan
    $themeFile = "$d\Windows\Resources\Themes\LunaticOS.theme"
    $themeVS   = $null
    if (-not (Test-Path -LiteralPath $themeFile)) {
      if ($themeExpected) {
        Write-Finding @{ Level = 'FALLA'; Text = 'NO existe Windows\Resources\Themes\LunaticOS.theme y el perfil ' +
          'pidio tema, acento o wallpaper: Windows aplica aero.theme al crear el perfil (Light + azul) y se pierde todo' }
      } else {
        Write-Finding @{ Level = 'OK'; Text = 'no hay LunaticOS.theme y el perfil no pidio tema/acento/wallpaper: correcto' }
      }
    } else {
      Write-Finding @{ Level = 'OK'; Text = 'existe Windows\Resources\Themes\LunaticOS.theme' }
      $themeVS = Get-IniSection -Path $themeFile -Section 'VisualStyles'
      if (-not $themeVS) {
        Write-Finding @{ Level = 'FALLA'; Text = 'el .theme NO tiene seccion [VisualStyles]: sin ella Windows ' +
          'ignora el tema entero y no dice nada. Un BOM al principio del archivo produce exactamente esto (contrato 2.3)' }
      } else {
        Write-Host "  [VisualStyles] del .theme instalado:" -ForegroundColor DarkGray
        foreach ($k in $themeVS.Keys) { Write-Host ("      {0}={1}" -f $k, $themeVS[$k]) -ForegroundColor DarkGray }

        foreach ($mv in @('SystemMode', 'AppMode')) {
          $val = "$($themeVS[$mv])"
          if ($val -notmatch '^(Dark|Light)$') {
            Write-Finding @{ Level = 'FALLA'; Text = ("{0}='{1}' en el .theme: tiene que ser Dark o Light" -f $mv, $val) }
          } elseif ($wantMode -and $val -ne $wantMode) {
            Write-Finding @{ Level = 'FALLA'; Text = ("{0}={1} en el .theme y el perfil pidio {2}" -f $mv, $val, $wantMode) }
          }
        }

        # El color del .theme, EN HEX. Si el hive difiere de esto, es un bug nuestro;
        # si el hive difiere del perfil pero coincide con esto, es el motor de temas
        # derivando tonos -- y esa diferencia la tiene que poder ver el humano.
        $tc = "$($themeVS['ColorizationColor'])"
        if ($tc) {
          if ($tc -notmatch '^0X[0-9A-Fa-f]{8}$') {
            Write-Finding @{ Level = 'FALLA'; Text = ("ColorizationColor='{0}' en el .theme: el formato es 0X + 8 hex (ARGB con alpha C4)" -f $tc) }
          } else {
            $tcColor = Convert-DwordToColor -Dword ([Convert]::ToUInt32($tc.Substring(2), 16)) -Layout 'ARGB'
            Write-Finding @{ Level = 'info'; Text = ("el .theme declara ColorizationColor={0} -> {1}" -f $tc, $tcColor.Hex) }
            if ($wantAccent -and (Get-Command ConvertTo-AccentDwords -ErrorAction SilentlyContinue)) {
              $expTheme = (ConvertTo-AccentDwords $wantAccent).ThemeColor
              if ("$tc" -eq "$expTheme") {
                Write-Finding @{ Level = 'OK'; Text = ("el .theme lleva el acento pedido ({0})" -f $wantAccent) }
              } else {
                Write-Finding @{ Level = 'FALLA'; Text = ("el .theme lleva {0} y el perfil pidio {1} (seria {2}): " -f $tcColor.Hex, $wantAccent, $expTheme) +
                  'el color se desalineo ANTES de llegar al disco, o sea en la fase 10' }
              }
            }
          }
        } elseif ($wantAccent) {
          Write-Finding @{ Level = 'FALLA'; Text = 'el perfil pidio acento y el .theme no declara ColorizationColor: el color no va a llegar' }
        }

        # Y lo que el hive del usuario termino teniendo vs lo que declara el .theme.
        foreach ($p in @(
            @{ n = 'AppsUseLightTheme';    theme = "$($themeVS['AppMode'])";    got = $script:hiveAppsLight }
            @{ n = 'SystemUsesLightTheme'; theme = "$($themeVS['SystemMode'])"; got = $script:hiveSysLight }
          )) {
          if ($p.theme -notmatch '^(Dark|Light)$') { continue }
          $espera = if ($p.theme -eq 'Dark') { 0 } else { 1 }
          if ($null -eq $p.got) {
            Write-Finding @{ Level = 'OJO'; Text = ("el hive del usuario no tiene {0}: no puedo comparar contra el .theme" -f $p.n) }
          } elseif ([int]$p.got -eq $espera) {
            Write-Finding @{ Level = 'OK'; Text = ("Themes\Personalize\{0}={1} coincide con el .theme ({2})" -f $p.n, $p.got, $p.theme) }
          } else {
            Write-Finding @{ Level = 'FALLA'; Text = ("Themes\Personalize\{0}={1} y el .theme dice {2} (esperaba {3}): " -f $p.n, $p.got, $p.theme, $espera) +
              'el tema que quedo aplicado NO es el que declara el .theme -- si InstallTheme esta bien, 25H2 esta ignorando el tema (contrato 2.5)' }
          }
        }
      }
    }

    # ------------------------------------------------------------------------
    #  Hive SOFTWARE: InstallTheme (2 ramas), activacion e inventario de policies.
    #  TODO en UNA carga: cada load/unload es un riesgo de dejar el hive tomado.
    # ------------------------------------------------------------------------
    $itFindings  = New-Object System.Collections.Generic.List[object]
    $actFindings = New-Object System.Collections.Generic.List[object]
    try {
    Use-OfflineHive -HivePath "$d\Windows\System32\config\SOFTWARE" -MountKey 'VRF_POL' -Action {
      param($root)
      foreach ($f in (Get-InstallThemeFindings -SoftwareRoot $root `
                        -ExpectedPath 'C:\Windows\Resources\Themes\LunaticOS.theme' `
                        -ThemeExpected $themeExpected)) { $itFindings.Add($f) }
      foreach ($f in (Get-ActivationFindings -SoftwareRoot $root -Drive $d)) { $actFindings.Add($f) }
      foreach ($br in @(
          @{ Label = 'HKLM\SOFTWARE\Policies';                                         Sub = 'Policies' }
          @{ Label = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies';        Sub = 'Microsoft\Windows\CurrentVersion\Policies' }
          # PersonalizationCSP NO vive bajo Policies, pero es la clave de la 5.1 que
          # mas rompe: deja al usuario sin poder cambiar fondo ni lockscreen. Va al
          # inventario igual, porque el inventario existe para que nada pase invisible.
          @{ Label = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'; Sub = 'Microsoft\Windows\CurrentVersion\PersonalizationCSP' }
        )) {
        $r = Get-PolicyBranchEntries -FullKey "$root\$($br.Sub)" `
               -MountPrefix 'HKEY_LOCAL_MACHINE\VRF_POL' -RealPrefix 'HKLM\SOFTWARE' -Label $br.Label
        foreach ($e in $r.Entries) { $polEntries.Add($e) }
        $polSummary.Add([pscustomobject]@{ Label = $r.Label; Values = $r.Values; Keys = $r.Keys })
      }
    }
    }
    catch {
      $scanErrors.Add('el hive SOFTWARE de maquina')
      Write-Host ("  ! no pude leer el hive SOFTWARE: {0}" -f $_.Exception.Message) -ForegroundColor Red
      Write-Host  "    si quedo uno cargado de una corrida que murio:  reg unload HKLM\VRF_POL" -ForegroundColor Yellow
    }
    foreach ($f in $itFindings) { Write-Finding $f }

    Write-Host "`n--- ACTIVACION (sin activar, Personalization esta en gris por LICENCIA) ---" -ForegroundColor Cyan
    foreach ($f in $actFindings) { Write-Finding $f }

    # ------------------------------------------------------------------------
    #  POLICIES: INVENTARIO COMPLETO (contrato 7.7)
    #
    #  Esto es un INVENTARIO, no un juicio: se lista TODO lo que hay. El bloqueo de
    #  Settings que arruino el ultimo build paso desapercibido porque NADIE MEDIA las
    #  policies del disco instalado. El juicio viene en el bloque siguiente.
    # ------------------------------------------------------------------------
    Write-Host "`n--- POLICIES del disco instalado: INVENTARIO COMPLETO ---" -ForegroundColor Cyan
    foreach ($s in $polSummary) {
      Write-Host ("  {0,-66} {1,4} valores / {2,3} claves" -f $s.Label, $s.Values, $s.Keys) -ForegroundColor DarkGray
    }
    Write-Host ("  TOTAL: {0} entradas" -f $polEntries.Count) -ForegroundColor Cyan

    if ($polEntries.Count -gt 0) {
      $logDir = Join-Path $CFG.Root 'work\logs'
      New-Item -ItemType Directory -Force -Path $logDir | Out-Null
      $dumpFile = Join-Path $logDir ('verify-policies-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
      $lineas = New-Object System.Collections.Generic.List[string]
      $lineas.Add("# LunaticOS -- inventario COMPLETO de policies del disco instalado")
      $lineas.Add("# VHDX : $vhdx  (montado read-only en $d)")
      $lineas.Add("# fecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
      $lineas.Add(("# {0} entradas. Esto es un inventario, no un juicio: ver el bloque 5.1 del -Verify." -f $polEntries.Count))
      $lineas.Add('')
      foreach ($e in ($polEntries | Sort-Object Key, Name)) {
        if ($e.Name) { $lineas.Add(("{0}\{1} = [{2}] {3}" -f $e.Key, $e.Name, $e.Type, $e.Data)) }
        else         { $lineas.Add(("{0}   {1}" -f $e.Key, $e.Type)) }
      }
      # UTF8 sin BOM y no ASCII: el dump puede traer rutas con acentos del registro y
      # un inventario que pierde informacion no sirve para nada.
      [System.IO.File]::WriteAllLines($dumpFile, $lineas.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
      Write-Host ("  dump completo -> {0}" -f $dumpFile) -ForegroundColor Green

      $maxInline = 60
      if ($polEntries.Count -le $maxInline) {
        foreach ($e in ($polEntries | Sort-Object Key, Name)) {
          $t = if ($e.Name) { "{0}\{1} = [{2}] {3}" -f $e.Key, $e.Name, $e.Type, $e.Data } else { "{0}   {1}" -f $e.Key, $e.Type }
          if ($t.Length -gt 160) { $t = $t.Substring(0, 157) + '...' }
          Write-Host "    $t" -ForegroundColor DarkGray
        }
      } else {
        Write-Host ("  (son {0}: no las muestro todas, esta todo en el archivo)" -f $polEntries.Count) -ForegroundColor DarkGray
      }
    }

    # ------------------------------------------------------------------------
    #  LO QUE BLOQUEA SETTINGS (contrato 5.1 y 7.9): ESTO SI ES UN JUICIO.
    #
    #  Y no busca solo la lista literal: marca tambien la CLASE (cualquier policy
    #  bajo una rama Personalization, o que se llame NoDisp* / NoChanging* /
    #  NoThemes* / Wallpaper*). La lista es lo que sabemos hoy; la clase es lo que
    #  nos va a morder manana. Un test que busca la firma exacta de un bug ya nos
    #  dio verde con el bug presente: no otra vez.
    # ------------------------------------------------------------------------
    Write-Host "`n--- POLICIES QUE BLOQUEAN SETTINGS (contrato 5.1): esto NO puede existir ---" -ForegroundColor Cyan
    $blockers = @(Get-SettingsBlockerFindings $polEntries)
    foreach ($m in $scanErrors) {
      Write-Finding @{ Level = 'FALLA'; Text = ('no pude leer {0}: el veredicto de la 5.1 queda SIN MEDIR ahi. ' -f $m) +
        'NO lo doy por bueno -- un OK que en realidad es "no mire" es como se nos escapo el bloqueo del ultimo build.' }
    }
    if ($blockers.Count -eq 0) {
      if ($scanErrors.Count -eq 0) {
        Write-Finding @{ Level = 'OK'; Text = 'ninguna clave de la seccion 5.1 en el disco instalado, y ninguna ' +
          'policy sospechosa de la misma clase. Personalization queda EN MANOS DEL USUARIO.' }
      } else {
        Write-Finding @{ Level = 'OJO'; Text = 'sin hallazgos en lo que SI pude leer, pero falto un hive: esto NO es un OK.' }
      }
    } else {
      $fallas = @($blockers | Where-Object { $_.Level -eq 'FALLA' })
      $sosp   = @($blockers | Where-Object { $_.Level -eq 'SOSPECHA' })
      foreach ($b in $blockers) { Write-Finding $b }
      if ($fallas.Count -gt 0) {
        Write-Host ""
        Write-Host ("  ############  {0} POLICY(S) DE LA SECCION 5.1 EN EL DISCO INSTALADO  ############" -f $fallas.Count) -ForegroundColor Red
        Write-Host  "  Settings > Personalization va a estar roto o en gris, y NO es por falta de" -ForegroundColor Red
        Write-Host  "  activacion: es por estas claves. Hay que sacarlas (contrato 5.2)." -ForegroundColor Red
      }
      if ($sosp.Count -gt 0) {
        Write-Host ""
        Write-Host ("  {0} policy(s) SOSPECHOSA(S): no estan en la lista del contrato pero son de la misma" -f $sosp.Count) -ForegroundColor Magenta
        Write-Host  "  familia. Miralas a mano: si bloquean algo, van a la seccion 5.1 del contrato." -ForegroundColor Magenta
      }
    }

    # ------------------------------------------------------------------------
    #  PROGRAMAS: que dice el log del instalador
    # ------------------------------------------------------------------------
    Write-Host "`n--- PROGRAMAS (log del instalador de winget) ---" -ForegroundColor Cyan
    $appLog = "$d\ProgramData\LunaticOS\install-apps.log"
    if (Test-Path $appLog) {
      $lines = Get-Content $appLog
      $ok   = @($lines | Select-String -Pattern '^\s*\d+:\d+:\d+\s+  OK ' -AllMatches)
      $bad  = @($lines | Select-String -Pattern 'FALLO ')
      Write-Host ("  instalados OK: {0}   fallidos: {1}" -f $ok.Count, $bad.Count) -ForegroundColor $(if ($bad.Count) { 'Yellow' } else { 'Green' })
      $lines | Select-String -Pattern 'resumen:|winget todavia|sin red|ERROR' |
        Select-Object -Last 5 | ForEach-Object { Write-Host "    $($_.Line.Trim())" -ForegroundColor DarkGray }
      if ($bad.Count) { $bad | Select-Object -First 8 | ForEach-Object { Write-Host "    $($_.Line.Trim())" -ForegroundColor Yellow } }
    } else {
      Write-Host "  no hay log: el instalador no llego a correr (o todavia esta corriendo)" -ForegroundColor Yellow
    }
    $pend = Get-ChildItem "$d\Users" -Directory -Force -EA SilentlyContinue |
              ForEach-Object { Join-Path $_.FullName 'Desktop\LunaticOS - descargas pendientes.txt' } |
              Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($pend) { Write-Host "  lista de descargas manuales dejada en el escritorio" -ForegroundColor Green }

    Write-Host "`n--- BLOAT: appx que sacamos (no deberian aparecer) ---" -ForegroundColor Cyan
    $found = @()
    foreach ($a in @('Clipchamp','BingNews','MicrosoftOfficeHub','YourPhone','MSTeams','DevHome')) {
      if (Get-ChildItem "$d\Program Files\WindowsApps" -Directory -Filter "*$a*" -Force -EA SilentlyContinue) { $found += $a }
    }
    if ($found) { Write-Host "  presentes: $($found -join ', ')" -ForegroundColor Red }
    else        { Write-Host "  OK: ninguno de los removidos aparece" -ForegroundColor Green }
  }
  finally {
    Dismount-DiskImage -ImagePath $vhdx | Out-Null
    Write-Host "`nVHDX desmontado." -ForegroundColor DarkGray
  }
}
