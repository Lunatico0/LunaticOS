# Inventario APPX provisioned — Windows 11 25H2 Pro (imagen real)

> 47 paquetes provisioned en `install.wim` (index 1, Pro). Clasificados contra el perfil de Pittana
> (dev pesado + FPS competitivo, medido en `uso.csv`). Cada ítem es un **toggle** en el script:
> el default es lo de acá, pero se activa/desactiva por flag.

## 🗑️ SACAR — default remove (19)

Bloat claro que no aparece en el uso real y coincide con el plan original.

| Paquete | Qué es |
|---|---|
| `Clipchamp.Clipchamp` | Editor de video |
| `Microsoft.BingNews` | Noticias Bing |
| `Microsoft.BingWeather` | Clima Bing |
| `Microsoft.GetHelp` | Asistente de ayuda MS |
| `Microsoft.MicrosoftOfficeHub` | Hub de Office (upsell 365) |
| `Microsoft.MicrosoftSolitaireCollection` | Solitario |
| `Microsoft.OutlookForWindows` | Outlook "new" (reincidente en updates) |
| `Microsoft.PowerAutomateDesktop` | Power Automate |
| `Microsoft.Todos` | Microsoft To-Do |
| `Microsoft.Windows.DevHome` | Dev Home (reincidente) |
| `Microsoft.WindowsFeedbackHub` | Feedback Hub |
| `MicrosoftCorporationII.QuickAssist` | Asistencia remota |
| `MicrosoftWindows.Client.WebExperience` | **Widgets** (News & Interests) |
| `MicrosoftWindows.CrossDevice` | Cross Device |
| `Microsoft.WindowsAlarms` | Alarmas y reloj |
| `Microsoft.MicrosoftStickyNotes` | Notas adhesivas |
| `Microsoft.WindowsSoundRecorder` | Grabadora de voz |
| `Microsoft.YourPhone` | Phone Link (vincular Android) |
| `MSTeams` | Teams **preinstalado** (reinstalás el de laburo por winget) |

## 🤔 DECIDIR — zona gris (3)

| Paquete | Qué es | Mi recomendación |
|---|---|---|
| `Microsoft.BingSearch` | Búsqueda web en el menú Inicio | **DEJAR el paquete** y matar el web-search por policy (`BingSearchEnabled=0`). Removerlo puede romper el search box; el efecto que querés se logra sin riesgo. |
| `Microsoft.ZuneMusic` | Reproductor multimedia nativo (Media Player) | **DEJAR.** Difiere de tu plan viejo: sin él no abrís un mp3/mp4 local. Es liviano. Spotify no reemplaza el reproductor de archivos locales. |
| `Microsoft.WindowsCamera` | App de Cámara | **DEJAR** (liviano; por si conectás webcam física algún día — usás DroidCam pero cuesta poco tenerla). |

## 🛡️ BLINDADO — NUNCA remover (25)

- **Dependencias / sistema:** `Microsoft.DesktopAppInstaller` (winget), `Microsoft.WindowsStore`,
  `Microsoft.StorePurchaseApp`, `Microsoft.SecHealthUI` (Windows Security), `Microsoft.ApplicationCompatibilityEnhancements`.
- **Apps que usás / útiles:** `Microsoft.WindowsTerminal`, `Microsoft.WindowsNotepad`,
  `Microsoft.WindowsCalculator`, `Microsoft.Paint`, `Microsoft.ScreenSketch` (Snipping), `Microsoft.Windows.Photos`.
- **Xbox completo (tu decisión):** `Microsoft.GamingApp`, `Microsoft.Xbox.TCUI`, `Microsoft.XboxGamingOverlay`,
  `Microsoft.XboxIdentityProvider`, `Microsoft.XboxSpeechToTextOverlay`.
- **Codecs (rompen reproducción de video/imágenes si se sacan):** `Microsoft.AV1VideoExtension`,
  `Microsoft.AVCEncoderVideoExtension`, `Microsoft.HEIFImageExtension`, `Microsoft.HEVCVideoExtension`,
  `Microsoft.MPEG2VideoExtension`, `Microsoft.RawImageExtension`, `Microsoft.VP9VideoExtensions`,
  `Microsoft.WebMediaExtensions`, `Microsoft.WebpImageExtension`.

## Estado del WIM

Montado en `work\mount` (index 1, Pro). Pendiente: aplicar remociones + hives + features + SetupComplete.
