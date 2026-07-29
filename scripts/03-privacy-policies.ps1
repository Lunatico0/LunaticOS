#requires -Version 5.1
<#
  Fase 3 -- Privacidad y policies de maquina (SOFTWARE hive, offline).

  ===========================================================================
  LAS POLICIES TIENEN UN COSTO, Y ACA SE PAGA EXPLICITAMENTE.

  Una policy en HKLM\SOFTWARE\Policies\... sobrevive a los feature updates mejor
  que un toggle de Settings. Esa es la ventaja, y es real.

  El precio es que BLOQUEA la opcion en la UI: Settings la muestra en gris y
  aparece el cartel "Algunas configuraciones estan administradas por tu
  organizacion". Eso es exactamente lo que le paso al usuario en el build del
  2026-07-29: Settings bloqueado y la personalizacion dejo de ser reversible.
  El objetivo del proyecto es lo contrario: un Windows que arranca lindo y QUEDA
  TUYO.

  Por eso las policies estan partidas en dos grupos:

    GRUPO A -- se aplican siempre.
      Telemetria, Copilot, Recall/AI, advertising ID y activity feed. Ninguna de
      estas toca la UI de personalizacion. Son el nucleo del debloat.

    GRUPO B -- OPT-IN, desmarcado por defecto ($Flags.BlockCloudContent).
      Las tres de CloudContent. Confirmado en foros de la comunidad:
      DisableWindowsConsumerFeatures=1 DISPARA el cartel de organizacion y hace
      desaparecer opciones de Personalization > Background (Windows Spotlight).
      Quien las quiera las marca sabiendo el costo. Nadie se las come sin querer.

  Detalle y evidencia: docs\personalizacion-contrato.md, seccion 5.3.
  ===========================================================================

  OJO: en Win11 Pro, AllowTelemetry=0 es un PISO ("Required"), no cero real. El corte del
  flujo se completa deshabilitando el servicio DiagTrack (fase 4) y las scheduled tasks (fase 7).

  Y OJO CON LO QUE NO ESTA ACA: esta fase NUNCA escribe policies de Personalization,
  PersonalizationCSP, NoDispCPL, NoThemesTab ni ninguna de la seccion 5.1 del
  contrato. La fase 10 las BORRA activamente del hive, asi que escribirlas seria
  una guerra entre dos fases del mismo pipeline.

  Uso:  .\03-privacy-policies.ps1           # aplica
        .\03-privacy-policies.ps1 -DryRun   # muestra que haria
#>
param([switch]$DryRun)

. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\lib.ps1"

# ---------------------------------------------------------------------------
#  La lista se construye en una FUNCION y no inline, para que el self-test pueda
#  pedirla con cualquier combinacion de flags sin montar una imagen. Un chequeo
#  que necesita un build de 45 minutos para correr no se corre nunca.
#  Rutas relativas a la raiz del hive SOFTWARE (se antepone HKLM\OFF_SW en el loop).
# ---------------------------------------------------------------------------
function Get-PrivacyPolicies {
  param(
    [bool]$BlockCloudContent = $false,
    [bool]$DisableLocation   = $false,
    [bool]$ShowWeatherWidget = $true
  )

  # ---- GRUPO A: siempre. Ninguna toca la UI de personalizacion. ----
  $pol = @(
    # Telemetria
    @{k='Policies\Microsoft\Windows\DataCollection'; v='AllowTelemetry';                 d=0; g='A'}
    @{k='Policies\Microsoft\Windows\DataCollection'; v='DoNotShowFeedbackNotifications'; d=1; g='A'}
    @{k='Policies\Microsoft\Windows\DataCollection'; v='DisableOneSettingsDownloads';    d=1; g='A'}
    # Copilot
    @{k='Policies\Microsoft\Windows\WindowsCopilot'; v='TurnOffWindowsCopilot'; d=1; g='A'}
    # Recall / Windows AI
    @{k='Policies\Microsoft\Windows\WindowsAI'; v='DisableAIDataAnalysis'; d=1; g='A'}
    @{k='Policies\Microsoft\Windows\WindowsAI'; v='AllowRecallEnablement'; d=0; g='A'}
    # Advertising ID
    @{k='Policies\Microsoft\Windows\AdvertisingInfo'; v='DisabledByGroupPolicy'; d=1; g='A'}
    # Activity feed / timeline
    @{k='Policies\Microsoft\Windows\System'; v='EnableActivityFeed';    d=0; g='A'}
    @{k='Policies\Microsoft\Windows\System'; v='PublishUserActivities'; d=0; g='A'}
    @{k='Policies\Microsoft\Windows\System'; v='UploadUserActivities';  d=0; g='A'}
  )

  # ---- GRUPO B: opt-in. Estas son las que ensucian Settings. ----
  if ($BlockCloudContent) {
    $pol += @{k='Policies\Microsoft\Windows\CloudContent'; v='DisableWindowsConsumerFeatures';     d=1; g='B'}
    $pol += @{k='Policies\Microsoft\Windows\CloudContent'; v='DisableConsumerAccountStateContent'; d=1; g='B'}
    $pol += @{k='Policies\Microsoft\Windows\CloudContent'; v='DisableCloudOptimizedContent';       d=1; g='B'}
  }

  # ---- Location: RESPETA EL FLAG ----
  # BUG ARREGLADO (2026-07-29): esta policy se escribia SIEMPRE, ignorando
  # $Flags.DisableLocation. O sea: el flag venia desmarcado, su nota en la TUI
  # avisaba "CUIDADO: esto BLOQUEA el panel Privacidad > Ubicacion en gris", y se
  # aplicaba igual. El usuario recibia el bloqueo que habia rechazado
  # explicitamente, y encima choca con el clima de Widgets.
  # Un flag que no se consulta es peor que no tener flag: promete control y miente.
  if ($DisableLocation) {
    $pol += @{k='Policies\Microsoft\Windows\LocationAndSensors'; v='DisableLocation'; d=1; g='LOC'}
  }

  # ---- Widgets ----
  # Si NO se quiere el clima en la taskbar, se apagan por policy. Si se quiere
  # (default), se dejan de fabrica: en 25H2 el feed MSN viene OFF por defecto,
  # o sea clima sin ads. Esta policy no toca personalizacion.
  if (-not $ShowWeatherWidget) {
    $pol += @{k='Policies\Microsoft\Dsh'; v='AllowNewsAndInterests'; d=0; g='DSH'}
  }

  $pol
}

# Con dot-source se cargan las funciones y NO se corre la fase. Asi el self-test
# puede pedir la lista con cualquier combinacion de flags sin imagen montada.
if ($MyInvocation.InvocationName -eq '.') { return }

$mount = $CFG.Mount
if (-not (Test-Path (Join-Path $mount 'Windows'))) {
  Write-Host "ERROR: no hay imagen montada en $mount" -ForegroundColor Red; exit 1
}

$blockCloud = [bool]$Flags.BlockCloudContent
$disableLoc = [bool]$Flags.DisableLocation
$weather    = [bool]$Flags.ShowWeatherWidget

$pol = @(Get-PrivacyPolicies -BlockCloudContent $blockCloud -DisableLocation $disableLoc -ShowWeatherWidget $weather)

Write-Host "== Fase 3: privacidad / policies (SOFTWARE hive) ==" -ForegroundColor Cyan

# El usuario tiene que VER en el log si pago el costo o no. Un bloqueo silencioso
# es lo que nos hizo perder una sesion entera buscando de donde salia el cartel.
if ($blockCloud) {
  Write-Host "  OJO: BlockCloudContent esta ACTIVADO." -ForegroundColor Yellow
  Write-Host "       Las 3 policies de CloudContent ponen el cartel 'administradas por tu" -ForegroundColor Yellow
  Write-Host "       organizacion' en Settings y ocultan opciones de Personalization >" -ForegroundColor Yellow
  Write-Host "       Background (Windows Spotlight). Lo elegiste vos; queda documentado aca." -ForegroundColor Yellow
} else {
  Write-Host "  (CloudContent NO se toca: son las policies que bloquean Settings. Se activan" -ForegroundColor DarkGray
  Write-Host "   marcando 'Bloquear contenido sugerido' en la TUI.)" -ForegroundColor DarkGray
}
if (-not $disableLoc) {
  Write-Host "  (Ubicacion NO se bloquea por policy: DisableLocation esta desmarcado.)" -ForegroundColor DarkGray
}
if (-not $weather) {
  Write-Host "  (Widgets DESACTIVADOS por ShowWeatherWidget=false)" -ForegroundColor DarkGray
}

if ($DryRun) {
  $pol | ForEach-Object { Write-Step ("[dry][{0}] {1}\{2} = {3}" -f $_.g, $_.k, $_.v, $_.d) 'DarkGray' }
  Write-Step ("[dry] total: {0} policies" -f $pol.Count) 'DarkGray'
  return
}

Use-OfflineHive -HivePath (Join-Path $mount 'Windows\System32\config\SOFTWARE') -MountKey 'OFF_SW' -Action {
  param($root)
  foreach ($x in $pol) {
    Invoke-Reg add "$root\$($x.k)" /v $x.v /t REG_DWORD /d $x.d /f
  }
  $nA = @($pol | Where-Object { $_.g -eq 'A' }).Count
  $nB = @($pol | Where-Object { $_.g -eq 'B' }).Count
  Write-Step ("aplicadas {0} policies de privacidad (grupo A: {1}, CloudContent opt-in: {2})" -f $pol.Count, $nA, $nB) 'Green'
}
