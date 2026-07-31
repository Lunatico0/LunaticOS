# 🌙 Handoff — estado al 2026-07-31

> Contexto para la próxima sesión de Claude, **incluida la que se abra en la notebook**.
>
> **Abrí Claude DENTRO de la carpeta del repo.** Es un repo git único, así engram resuelve
> el proyecto sin el error de *"ambiguous project"*.
>
> ⚠️ **En la notebook no hay engram de este proyecto.** La memoria persistente vive en
> `%LOCALAPPDATA%\engram` de la PC principal y **no viaja por el repo**. Este documento es
> el reemplazo: está escrito para ser **autosuficiente**. Si querés la memoria completa,
> copiá esa carpeta a mano (ver `docs\dia-d-respaldo.md` paso 1.5).

---

## Qué es esto

**LunaticOS**: pipeline offline y reproducible que toma una ISO oficial de Windows 11 y
escupe una ISO debloateada, desatendida y personalizada. Todo scripteado en PowerShell 5.1,
sin herramientas de terceros, sin tocar el sistema en vivo.

- **TUI de entrada:** `LunaticOS.cmd` → `LunaticOS.ps1`
- **Pipeline:** `scripts\00-prepare-wim.ps1` → `11-apps.ps1`
- **Toggles y configuración:** `scripts\config.ps1`
- **El "por qué" de CADA decisión:** `docs\decisiones.md` ← **la fuente de verdad**

## ✅ Estado: ISO generada, verificada y probada en VM

- **Artefacto:** `work\Win11_25H2_Pro_debloat.iso` — **7,5 GB**, Windows 11 **Pro 25H2**,
  booteable UEFI+BIOS. Verificado: `install.wim` solo Pro, `autounattend.xml` en la raíz,
  boot sectors OK.
- ⚠️ **La ISO NO está en el repo y nunca va a estar.** `work/` y `*.iso` están en
  `.gitignore`. Clonar el repo te da **los scripts**, no la ISO. Si la necesitás en otra
  máquina: copiala por red, o reconstruila corriendo el pipeline (bajar la imagen oficial
  de Microsoft + ADK + horas de proceso).

---

## 🎯 Lo que está pasando ahora: cambio de placa madre

El usuario **confirmó** que cambia la placa. Eso reordenó todas las prioridades.

| Qué | Cuál |
|---|---|
| Mother nueva | GIGABYTE **B560M AORUS ELITE rev 1.x** (tiene botón Q-Flash Plus) |
| CPU | Intel **i5-11400F** — Rocket Lake 11ª gen, **sin gráficos integrados** |
| GPU | Discreta, **obligatoria** (sin ella no hay imagen ni para entrar a la BIOS) |
| Pendrive | SanDisk Cruzer Fit 58,7 GB — **el único que hay** |
| Notebook | Disponible, con Claude. **Es la que graba la ISO al final.** |

### Discos de la PC principal (relevado 2026-07-31)

| Letra | Disco | Modelo | Tamaño | Tabla | Rol |
|---|---|---|---|---|---|
| **C:** | 2 | WDC WDS480G2G0C (NVMe) | 447 GB | GPT | **EL QUE SE FORMATEA** |
| **D:** | 1 | TOSHIBA MQ01ABD100 (HDD) | 932 GB | MBR | 6 carpetas del perfil redirigidas, Steam, Riot |
| **E:** | 0 | KINGSTON SA400S37240G (SSD) | 224 GB | MBR | `E:\Workspace` — el trabajo, **y el repo** |

BitLocker: los tres discos `FullyDecrypted`, protección `Off`. **No hay cifrado** — se
pueden desconectar sin riesgo.

---

## ✅ Cerrado el 2026-07-31

- Pasos **1.1, 1.2, 1.3** (etiquetas de disco, mapa de particiones, export de carpetas
  redirigidas). El **1.4** (BitLocker) no requería acción: no hay cifrado.
- 🔑 **Paso 1.7 — licencia digital VINCULADA a la cuenta Microsoft.** Verificado:
  Activation state `Active` + *"activated with a digital license linked to your Microsoft
  account"*. **Era el único paso con reloj corriendo. Ya no hay riesgo de perder la
  licencia por el cambio de placa.**
- **Respaldos automatizables corridos a `E:\_migracion`** (verificados, ninguno vacío):
  `.claude` 776 MB / **6812 archivos completos**, `engram` 18 MB, `winget-export.json`,
  `programas-instalados.txt`, `autoruns-hkcu/hklm.reg`, `.ssh`, `.gitconfig`.
- **Hash de la ISO calculado** — 7,44 GB:
  `2A5F4574BC7689DB92C5C922DAF01223B920B005936C4CFFFFB2D7B883E0CE32`
- Repo publicado en <https://github.com/Lunatico0/LunaticOS>.

> ⚠️ `E:\_migracion\perfil\.ssh` contiene **claves privadas en texto plano**
> (`id_github_personal`, `id_vela1`). Está fuera del repo, pero tratá esa carpeta como una
> contraseña.

## 🔴 Pendiente, en orden

**El orden completo y ejecutable está en [`TIMELINE.md`](TIMELINE.md).** Resumen:

1. **Pasar la ISO a la notebook** (7,44 GB, por red) y **verificar el hash**. Sin esto hay
   que reconstruirla de cero con la PC principal ya desarmada.
2. **Clonar el repo en la notebook** y llevar `E:\_migracion\claude\` si se quiere la
   memoria completa de engram.
3. **Respaldos manuales**: marcadores del navegador, configs de Macro Deck / SteelSeries /
   Razer / Figma, VMs si importan. Y **repetir el robocopy de `.claude` + `engram` con
   Claude Code CERRADO** (es incremental, tarda segundos).
4. **Vaciar el pendrive** a `E:\pendrive-backup` y formatearlo **FAT32** con el firmware
   como `gigabyte.bin` — `docs\bios-update.md`.
5. **Desarmar, montar la placa, flashear, y RECIÉN DESPUÉS configurar Secure Boot + TPM.**
6. **Notebook: grabar la ISO con Rufus** (no Ventoy).
7. **Instalar** — `TIMELINE.md` fases 7 a 10.

---

## 🧠 El hallazgo que cambió el plan del pendrive

**Q-Flash de Gigabyte solo lee FAT32/16/12.** No lee NTFS y **no lee exFAT**. El pendrive
tenía Ventoy en MBR con la partición de datos en **exFAT** → la BIOS no iba a ver el
firmware ni sabiendo que estaba ahí.

Y no se arregla con particiones. El 11400F es 11ª gen: si la placa trae una BIOS de fábrica
que no lo soporta, **no da imagen**, y sin imagen no se entra al setup. El único camino ahí
es **Q-Flash Plus** (botón del panel trasero, flashea sin CPU/RAM/GPU) — que exige un
pendrive **FAT32 de una sola partición** con el archivo renombrado `gigabyte.bin`. Un
pendrive multipartición es justo lo que lo hace fallar.

**De ahí el plan de dos etapas:** el pendrive es FAT32 puro para la BIOS, y la ISO se graba
después desde la notebook con **Rufus**.

> **Efecto colateral bueno:** pasar a Rufus resuelve de paso la advertencia de
> `docs\dia-d.md` sección 2 — Ventoy monta la ISO como disco virtual y **nunca se probó**
> que exponga el `autounattend.xml` en la raíz del medio. Rufus **sí está probado** en este
> proyecto. Dos problemas, una decisión.

Detalle operativo: **Windows no formatea FAT32 en volúmenes de más de 32 GB** (ni por el
Explorador ni por `diskpart`). Para los 58,7 GB del pendrive hay que usar **Rufus en modo
"Non bootable" con FAT32**, o hacer una partición de 32 GB y dejar el resto sin asignar.

---

## 🗺️ Mapa de documentos

| Documento | Para qué |
|---|---|
| `TIMELINE.md` | **El orden de ejecución del día D.** Fase por fase, con puntos de no retorno. |
| `docs\decisiones.md` | **El "por qué" de cada decisión técnica.** Empezá acá. |
| `docs\bios-update.md` | Operativo de la BIOS y del pendrive. **Nuevo.** |
| `docs\dia-d-respaldo.md` | No perder nada: respaldos, licencia, orden del día D. |
| `docs\dia-d.md` | La instalación en sí, paso a paso, y qué verificar. |
| `docs\contrato-cuenta-usuario.md` | Cómo se crea el usuario y qué garantiza el unattend. |
| `docs\personalizacion-contrato.md` | Contrato de `perfil.json` y personalización. |
| `docs\testing-e2e.md` | Cómo se prueba el pipeline de punta a punta. |
| `docs\inventario-appx.md` | Qué appx se quita y qué se conserva, con motivo. |

## ⚙️ Reglas del proyecto que no se negocian

- **Scripts en ASCII puro** — es PowerShell 5.1. Sin caracteres raros en los `.ps1`.
- **Paths a DISM como variable entre comillas**, nunca expresión inline → si no, error 87.
- **Secure Boot + TPM 2.0 ON** son innegociables (regla de oro **D5**): Vanguard los exige,
  sin ellos Valorant tira `VAN9001`.
- **Nunca se hardcodea un secreto en la ISO.** El usuario nace sin password a propósito;
  la clave del `autounattend.xml` es la genérica pública de Pro (fija la edición, **no
  activa nada**).
- **Edge no se desinstala, se bloquea.** Desinstalarlo rompe WebView2, y `EdgeUpdate` queda
  **vivo** a propósito: es quien mantiene WebView2 parchado. Ver **D21**.
- **Rufus, no Ventoy.** Y si se usa Rufus, **rechazar todas** sus "customizaciones": pisan
  nuestro unattend.
