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
- [x] **Fase 7 — SetupComplete.cmd + autounattend.xml** (cuenta local, teclado ES+EN, quitar Edge, tasks telemetría).
- [x] **Fase 8 — commit del WIM + rearmar ISO** booteable (oscdimg).

## RESULTADO ✅ — ISO generada (2026-07-27)

`work\Win11_25H2_Pro_debloat.iso` (7.44 GB) — Windows 11 **Pro 25H2** debloateado, booteable UEFI+BIOS.
Verificado: install.wim = solo Pro, autounattend en raíz, boot sectors presentes.

**Correcciones sobre el plan original:** Widgets/clima CONSERVADOS (toggle `ShowWeatherWidget`, feed MSN
off por defecto en 25H2); Edge (navegador) se quita en el 1er arranque vía SetupComplete preservando WebView2.

## Fuentes viejas a portar (raíz de CodeByPittana)

`plan-debloat-completo.md` (10 fases, tabla anticheat), `01/02/03/04-*.md`, `debloat-master.ps1`,
`debloat.ps1`, `reinstalar-apps.ps1`. Todo post-install → hay que ADAPTAR a offline, no copiar tal cual.
