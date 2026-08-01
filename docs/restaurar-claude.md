# Restaurar Claude Code en el Windows nuevo

> Qué se respaldó, qué **no viaja**, y cómo dejarlo andando igual que antes.
> Relevado el 2026-08-01, antes del cambio de placa.

## Por qué este documento existe

La configuración de Claude Code **no vive en un solo lugar**. Está repartida en dos rutas,
y una de ellas queda **fuera** de la carpeta `.claude`:

| Qué | Dónde vive | ¿Lo agarra un robocopy de `.claude`? |
|---|---|---|
| Reglas, skills, agents, plugins, MCP, sesiones | `%USERPROFILE%\.claude\` | ✅ Sí |
| **Config general, historial de proyectos, MCP por proyecto** | **`%USERPROFILE%\.claude.json`** | ❌ **NO — es un archivo suelto, hermano de la carpeta** |
| Memoria persistente de engram | `%LOCALAPPDATA%\engram\` | ❌ No, es otra ruta |

> ⚠️ **Este fue un agujero real del respaldo.** Se copió `.claude\` y se dio por hecho que
> incluía todo. `.claude.json` (88,7 KB) estaba afuera y quedó sin copiar hasta que se
> revisó a mano. Si repetís este respaldo en el futuro, **son tres rutas, no una.**

---

## Qué quedó respaldado

Todo en `E:\_migracion\claude\` — y **E: no se formatea**:

```
E:\_migracion\claude\
├── .claude\          6812 archivos / 776 MB   <- la carpeta completa
├── engram\             18 MB                   <- la memoria persistente
└── claude.json         88,7 KB                 <- el archivo suelto
```

### Lo que hay adentro de `.claude\` y por qué importa

| Carpeta | Qué tiene |
|---|---|
| `CLAUDE.md` | **Tus reglas globales.** Personalidad, idioma, tono, filosofía, protocolo de engram |
| `skills\` | Tus 17 skills: `sdd-*`, `judgment-day`, `branch-pr`, `go-testing`, `skill-creator`… |
| `agents\` | Los sub-agentes definidos |
| `output-styles\` | El estilo de salida (Gentleman) |
| `commands\` | Slash-commands propios |
| `plugins\` | Plugins instalados y de dónde salieron (`installed_plugins.json`) |
| `mcp\` | `context7.json`, `engram.json` — **configuración de MCP** |
| `projects\`, `sessions\`, `history.jsonl` | Historial de conversaciones |
| `.credentials.json` | 🔑 **Tratalo como una contraseña** |

**Los MCP de serena, playwright, chrome-devtools y vercel** no están en `.claude.json`:
llegan por **plugins/marketplaces**, y eso vive en `.claude\plugins\`. Está cubierto.

---

## El robocopy final: qué hace y por qué va último

```powershell
robocopy "$env:USERPROFILE\.claude" "E:\_migracion\claude\.claude" /E /R:1 /W:1 /NFL /NDL
robocopy "$env:LOCALAPPDATA\engram" "E:\_migracion\claude\engram" /E /R:1 /W:1 /NFL /NDL
```

**Qué hace cada bandera:**

| Bandera | Qué significa |
|---|---|
| `/E` | Copia subcarpetas, **incluidas las vacías** |
| `/R:1` | Si un archivo falla, **reintenta 1 vez** (el default son **un millón** de reintentos: sin esto se cuelga para siempre en un archivo bloqueado) |
| `/W:1` | Espera **1 segundo** entre reintentos (el default son 30) |
| `/NFL` `/NDL` | No lista cada archivo ni cada carpeta — solo el resumen |

**Por qué va último, después de cerrar Claude Code:**

`engram` es una base **SQLite en un solo archivo de 18 MB**. Si la copiás con Claude
corriendo, podés llevarte una copia a mitad de una escritura — una base inconsistente que
parece estar bien hasta que la abrís. Lo mismo con las sesiones de `.claude\`.

**Es incremental**: solo copia lo que cambió desde la corrida anterior. Tarda **segundos**,
no minutos. Por eso conviene correrlo dos veces: una ahora (red de contención) y otra con
todo cerrado (la buena).

**Cómo ejecutarlo:**

1. Cerrá Claude Code por completo (que no quede ninguna ventana ni proceso).
2. Abrí **PowerShell** (no hace falta admin).
3. Pegá los dos comandos de arriba.
4. Buscá en el resumen la columna **`Failed`**: tiene que decir **0**.

---

## Restaurar en el Windows nuevo

⚠️ **El usuario nuevo se llama `pato`, no `Administrator`.** Las rutas cambian.

**Con Claude Code cerrado**, y ya instalado:

```powershell
robocopy "E:\_migracion\claude\.claude" "$env:USERPROFILE\.claude" /E /R:1 /W:1 /NFL /NDL
robocopy "E:\_migracion\claude\engram" "$env:LOCALAPPDATA\engram" /E /R:1 /W:1 /NFL /NDL
Copy-Item "E:\_migracion\claude\claude.json" "$env:USERPROFILE\.claude.json" -Force
```

Después abrí Claude **dentro de la carpeta del repo** — es un repo git único, así engram
resuelve el proyecto sin el error de *"ambiguous project"*.

### Qué puede fallar, y qué hacer

| Síntoma | Causa | Solución |
|---|---|---|
| Pide login de nuevo | `.credentials.json` está atado a la máquina | Volvé a loguearte. Es normal. |
| Un plugin no carga | `installPath` apunta a `C:\Users\Administrator\...` | Reinstalá ese plugin; la lista está en `plugins\installed_plugins.json` |
| Un MCP no arranca | Ruta absoluta al binario que ya no existe | Revisá `.claude\mcp\*.json` y corregí la ruta |
| engram no encuentra nada | Resolvió otro nombre de proyecto | Ver la nota de abajo |

### ⚠️ La fragmentación de engram

Al publicar el repo en GitHub, engram **cambió la identidad del proyecto**: pasó de
`win11-debloat-iso` (resuelto por `git_root`) a **`lunaticos`** (resuelto por `git_remote`).

Las memorias viejas quedaron bajo el nombre anterior. **Buscá en los dos nombres** hasta
que se puedan mergear — `mem_merge_projects` existe pero no siempre está disponible.

---

## Qué NO viaja, y hay que rehacer a mano

- **Login de Claude** — volvés a iniciar sesión.
- **MCP autenticados interactivamente** (claude.ai, Figma, Microsoft 365) — hay que
  reautenticar.
- **Rutas absolutas** dentro de configs que apunten a `C:\Users\Administrator\`.
- **Variables de entorno** del sistema que hayas seteado a mano.
