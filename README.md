# win11-debloat-iso

Debloat **offline** de Windows 11 25H2: se edita la imagen (`install.wim`) **dentro de la ISO original**
antes de instalar, así el bloat **nunca llega al disco**. No se toca un SO ya corriendo.

> Estado: 🚧 en construcción. Enfoque y toolchain definidos; pipeline en desarrollo.

## Por qué offline y no post-install

Editar la imagen = el bloat no se instala nunca, no hay que "limpiar" después, y la ISO
resultante es reproducible en cualquier PC. Lo que no se puede hacer 100% offline
(algunas scheduled tasks, ajustes runtime) se resuelve inyectando un `SetupComplete.cmd`
que corre **al final del setup** — sigue siendo parte de la ISO, no una limpieza manual posterior.

## Principios (la línea que no se cruza)

- **Anticheat-safe.** Nada de lo que hacemos flaggea Vanguard/FACEIT. Secure Boot + TPM intactos.
- **No romper dependencias de dev** (winget, Store, runtimes VC++/.NET, WSL/Hyper-V).
- **Reversible donde se pueda.** Los tweaks de registro se documentan con su reversa.
- **Con criterio, no a ciegas.** El perfil base salió de 32 días de uso real medido, no de una guía de foro.

## Requisitos (host que edita la ISO)

| Requisito | Detalle |
|---|---|
| Windows | Host igual o más nuevo que el target (editar 25H2 → ADK 24H2 con DISM acorde) |
| Windows ADK 24H2 | Solo *Deployment Tools* → aporta `oscdimg` + `dism` |
| ISO | Windows 11 **25H2 x64 Pro**, oficial de Microsoft (no modificada de terceros) |
| Disco | ~20 GB libres de scratch para montar/exportar el WIM |
| Permisos | Consola **como Administrador** |

## Estructura

```
win11-debloat-iso/
├── scripts/   # pipeline offline (montar WIM, quitar appx, hives, rearmar ISO)
├── config/    # listas de appx, features, autounattend.xml, hives offline
├── docs/      # plan por fases, decisiones, tabla anticheat
└── work/      # scratch (gitignored): ISO original, WIM montado, ISO de salida
```

## Uso

_(Pendiente — se documenta cuando el pipeline esté armado.)_

## Aviso

El perfil por defecto está pensado para **dev pesado + gaming competitivo**. Si tu uso es otro,
revisá las listas de `config/` antes de correrlo: debloatear a ciegas el perfil de otra persona
es exactamente lo que este proyecto trata de evitar.
