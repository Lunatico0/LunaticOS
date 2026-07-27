# 🌙 Handoff — retomar mañana (2026-07-27)

> Contexto para la próxima sesión de Claude. **Abrí Claude DENTRO de esta carpeta**
> (`E:\Workspace\CodeByPittana\win11-debloat-iso`) — es un repo git único, así engram
> resuelve el proyecto sin el error de "ambiguous project" que tuvimos hoy.

## ✅ Estado: ISO GENERADA y verificada

- **Resultado:** `work\Win11_25H2_Pro_debloat.iso` (7.5 GB) — Windows 11 **Pro 25H2** debloateado,
  booteable UEFI+BIOS. Verificado: install.wim = solo Pro, autounattend en raíz, boot sectors OK.
- **Repo:** 9 commits. Pipeline completo `scripts\00..08-*.ps1` + `config.ps1` (toggles) + `lib.ps1`.
- **El "por qué" de cada decisión:** `docs\decisiones.md`. **Inventario appx:** `docs\inventario-appx.md`.

## 🔜 Pendiente (en orden)

1. **Probar la ISO en una VM** (ANTES de tocar la Gigabyte). Ver pasos abajo.
2. Si la VM valida OK → grabar a USB (**Ventoy** — solo copiás el .iso al pendrive; o Rufus) e **instalar en la mother nueva**.
3. Checklist día D (abajo).

## 🖥️ Cómo probar en VM (Hyper-V, ya viene en Win11 Pro)

La VM DEBE tener **TPM 2.0 + Secure Boot** (Win11 los exige, y así el test es fiel a la mother real).

```powershell
# (Admin) Si Hyper-V no está habilitado, esto pide reinicio:
# Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All

$iso = "E:\Workspace\CodeByPittana\win11-debloat-iso\work\Win11_25H2_Pro_debloat.iso"
$vhd = "E:\Workspace\CodeByPittana\win11-debloat-iso\work\test-vm.vhdx"

New-VM -Name "Debloat-Test" -Generation 2 -MemoryStartupBytes 6GB -NewVHDPath $vhd -NewVHDSizeBytes 64GB
Set-VM -Name "Debloat-Test" -ProcessorCount 4
# TPM + Secure Boot (clave para Win11):
Set-VMKeyProtector -VMName "Debloat-Test" -NewLocalKeyProtector
Enable-VMTPM -VMName "Debloat-Test"
# Montar la ISO y bootear desde ahí:
Add-VMDvdDrive -VMName "Debloat-Test" -Path $iso
$dvd = Get-VMDvdDrive -VMName "Debloat-Test"
Set-VMFirmware -VMName "Debloat-Test" -FirstBootDevice $dvd
Start-VM -Name "Debloat-Test"; vmconnect.exe localhost "Debloat-Test"
```

**Qué verificar en la VM:**
- [ ] Instala bien y llega al OOBE.
- [ ] En el OOBE aparece la **opción de cuenta local** (BypassNRO). Si NO: `Shift+F10` → `start ms-cxh:localonly`.
- [ ] Teclado **español** (probá la ñ y tildes), UI en inglés.
- [ ] **Clima/Widgets** en la taskbar, **sin** noticias/ads.
- [ ] NO está: OneDrive, Copilot, bloat (Bing, Solitaire, etc.).
- [ ] **Edge navegador** desaparece tras el 1er arranque (SetupComplete); Store abre igual (WebView2 intacto).
- [ ] Xbox / Game Bar presente; Terminal, Store, winget OK.

> Limpieza de la VM de prueba: `Stop-VM Debloat-Test -TurnOff; Remove-VM Debloat-Test -Force; Remove-Item $vhd`

## 🔧 Checklist día D (instalar en la Gigabyte)

1. Grabar ISO a USB (Ventoy: copiar el .iso al pendrive).
2. **BIOS: Secure Boot ON + TPM 2.0 ON** (sin esto Vanguard tira VAN9001 y Valorant no abre).
3. Instalar (disco a mano; cuenta local; teclado ya configurado).
4. **Drivers primero** (manual): Gigabyte (chipset/LAN/audio) + AMD Adrenalin (RX 9060 XT).
5. Correr `..\reinstalar-apps.ps1` (está en la raíz de CodeByPittana) → stack por winget.
6. Instalar VALORANT (playvalorant.com) + FACEIT + Steam y **confirmar que ARRANCAN**.
7. Memory Integrity / Core Isolation **OFF** (para FPS — decisión del plan).

## 🧠 Para guardar en engram mañana (copiá esto estando dentro de la carpeta)

**Título:** Debloat ISO Win11 25H2 Pro completado — pipeline offline reproducible
**Tipo:** project
**Contenido:** ISO generada en `work\Win11_25H2_Pro_debloat.iso` (7.5 GB). Pipeline offline scripteado
(00→08) sobre install.wim, editando appx/features/hives con el DISM del ADK 24H2 + oscdimg. Decisiones:
Widgets/clima conservados (toggle `ShowWeatherWidget`), Edge navegador se quita en SetupComplete
preservando WebView2, cuenta local por BypassNRO (sin password en la ISO), región AR + teclado ES/EN,
Pro, 25H2 (no 26H2 preview por anticheat). Aprendizajes: hives offline con reg.exe + descarga siempre
(GC+reintentos); TaskbarDa protegido offline → Widgets por policy Dsh; .ps1 en ASCII puro (PS 5.1);
paths a DISM como variable entre comillas (no expr inline → error 87). Fuente de verdad: `docs\decisiones.md`.
**Próximo:** validar en VM Hyper-V (TPM+SecureBoot) → grabar USB Ventoy → instalar en Gigabyte.
