# Contrato del test end-to-end de LunaticOS

> LunaticOS va a salir para que lo use gente que no escribio el codigo. Un bug que
> llega al usuario cuesta una instalacion completa de Windows, no un `git revert`.
> Este documento define el E2E: **desde la TUI hasta el SO corriendo.**
>
> Fuente de verdad para todo lo que sea tema/color/policies:
> `docs\personalizacion-contrato.md`. Este doc es solo sobre COMO SE PRUEBA.

## 0. Que hay hoy y que falta

| Capa | Hoy |
|---|---|
| Logica sin UI (catalogos, perfil, clases de bug) | `LunaticOS.ps1 -SelfTest`: 111 tests, probados por mutacion |
| **La TUI** | **NADA.** Es el primer contacto del usuario y no se prueba |
| Pipeline -> ISO | Solo se ve si el build no explota |
| **Instalacion** | **Requiere un clic humano** -> imposible automatizar |
| SO instalado, apagado | `test-vm.ps1 -Verify` (hives offline) |
| **SO corriendo** | **NADA.** Y hay cosas que offline son opacas |

La regla que gobierna todo esto, aprendida a golpes en este repo (siete casos):
**el instrumento falla mas veces que el producto.** Todo chequeo nuevo se valida
reintroduciendo el bug que deberia cazar. Un test que no falla con el bug puesto
es un adorno.

## 1. El clic manual: por que existe y como se elimina

El teclado sintetico de Hyper-V (`Msvm_Keyboard`, namespace `root\virtualization\v2`)
**NO llega al setup de Windows 11**. Medido: 5 intentos, todos con `ReturnValue=0` y
CERO efecto sobre la pantalla "Select location to install Windows 11". `ReturnValue=0`
miente. En el firmware UEFI si funciona; en WinPE no.

Automatizar el clic esta descartado. **La solucion es que esa pantalla no aparezca:**
un autounattend con `DiskConfiguration`, que particiona solo.

Por eso hay DOS autounattend:

| Archivo | Uso | `DiskConfiguration` |
|---|---|---|
| `config\autounattend.xml` | **PRODUCCION** | **NO.** Decision tomada: el disco lo elige el usuario a mano. Un script que formatea el disco equivocado es catastrofico e irreversible |
| `config\autounattend-test.xml` | **SOLO TEST en VM** | **SI.** Limpia el disco 0 entero, sin preguntar |

**`autounattend-test.xml` NUNCA puede terminar en una ISO de produccion.** Tiene que
llevar el aviso en la primera linea del archivo, y el self-test tiene que verificar
que el pipeline normal no lo use.

## 2. TUI testeable: inyeccion de teclas

`scripts\tui.ps1` lee input en UN solo lugar: `Get-TuiKey`. Ese es el punto de corte.

Contrato:

```powershell
# Si $Global:TuiKeyProvider es un scriptblock, Get-TuiKey lo invoca en vez de
# leer el teclado. Si no, se comporta exactamente como hoy ([Console]::ReadKey).
$Global:TuiKeyProvider = $null

# Helper para los tests: carga una cola de teclas.
#   Send-TuiKeys 'DownArrow','DownArrow','Spacebar','Enter'
# Acepta nombres de [ConsoleKey] y caracteres sueltos ('A','N','R','S').
function Send-TuiKeys([string[]]$Keys)
```

Reglas:

- **Si la cola se vacia en modo test, `Get-TuiKey` TIENE que tirar error**, no colgarse
  ni devolver `$null`. Un test que se cuelga esperando input es peor que uno que falla.
- En produccion, con `$TuiKeyProvider = $null`, el comportamiento no cambia **en nada**.
  Es la unica forma de que esto no sea un riesgo agregado.
- Los tests de TUI no deben depender de la salida visual (posiciones, colores): afirman
  sobre el **estado del hashtable `$Selected`** y sobre el valor de retorno.

Que hay que cubrir como minimo:

1. Marcar un item con `Spacebar` lo deja en `$true` en `$Selected`.
2. Los grupos excluyentes: marcar un acento desmarca los hermanos. **Este ya fue un bug.**
3. `A` (todos) deja solo UNO de cada grupo excluyente.
4. `N` (ninguno) deja todo en `$false`, y **"cero marcados" tiene que ser distinguible
   de "sin perfil"** -- el bug de "elegir 0 apps instalaba los 24 recomendados".
5. `R` restaura los recomendados.
6. `Enter` devuelve `$true`, `Escape` devuelve `$false`.
7. El scroll: navegar mas alla de la ventana visible no rompe ni sale del rango.
8. Una lista **vacia** no explota (hoy `$Items[$idx]` con 0 items es un indice invalido).
9. **El frame no se desarma con la consola chica.** El frame de la checklist mide ~28
   lineas y 78 columnas, y nadie fija el tamano de la consola: si la ventana es menor,
   el buffer scrollea y el `SetCursorPosition(0,0)` dibuja encima de si mismo. Como
   minimo el ancho tiene que adaptarse a `[Console]::WindowWidth`.

## 3. Verificacion en el SO CORRIENDO: PowerShell Direct

Hay cosas que offline son **opacas** y solo se pueden medir con el SO andando:

- la **activacion** (vive en `tokens.dat` y `HKLM\SYSTEM\WPA`, blobs opacos),
- los colores **efectivos** (no los escritos: los que la UI esta usando),
- `winget` y las apps realmente instaladas,
- los servicios en su estado real,
- si Explorer sobrevivio al primer login (el issue #329),
- que Settings > Personalization se pueda abrir sin el cartel de organizacion.

`Invoke-Command -VMName` (PowerShell Direct) **no funciona con password vacio** -- por eso
nunca se pudo usar. La cuenta de `autounattend-test.xml` lleva password, y ese es el
unico motivo por el que existe ese archivo aparte.

```powershell
scripts\verify-live.ps1 -VMName 'LunaticOS-Test' -User 'pato' -Password '<...>'
```

- Devuelve un objeto con los resultados **y** un exit code (0 = todo OK).
- **NO imprime el password nunca**, ni en logs ni en pantalla.
- Si la VM no responde en el timeout, dice **timeout**; no inventa un veredicto.
- Cada chequeo dice de donde saco el dato. "OK" sin evidencia no sirve.

El password de la cuenta de test es **solo para la VM**, va en un archivo versionado a
proposito (es un secreto que no protege nada) y **no se usa en produccion**.

## 4. El runner: `scripts\test-e2e.ps1`

Un comando, de la TUI al SO corriendo:

```
1. -SelfTest                      (rapido: si esto falla, no gastes 35 min)
2. tests de TUI                   (teclas inyectadas -> perfil.json esperado)
3. build con el perfil de test    (~9 min si el WIM ya esta exportado)
4. VM: reset + boot               (con autounattend-test = CERO clics)
5. esperar la instalacion         (~25 min, con timeout y evidencia de progreso)
6. verify-live                    (SO corriendo, por PowerShell Direct)
7. apagar + test-vm.ps1 -Verify   (hives offline)
8. reporte final                  (una linea por capa: PASA / FALLA / SIN MEDIR)
```

Requisitos:

- **Cada fase tiene timeout.** Un E2E que se cuelga para siempre no se corre nunca mas.
- `-KeepVM` para dejar la VM viva y poder mirarla cuando algo falla.
- Poder **arrancar desde una fase** (`-From 4`): si falla el paso 6, no se rehacen los 35
  minutos anteriores.
- Log completo a `work\logs\e2e-<stamp>.log`, y el reporte final tambien por pantalla.
- **Nunca dejar la maquina en un estado raro**: hives descargados, VHDX desmontado, ISO
  liberada del DVD. Todo en `finally`.
- Que quede claro qué se midio y qué NO: `SIN MEDIR` es un resultado valido y honesto.
  `PASA` sin evidencia es la trampa que ya nos costo dos sesiones.

## 5. Matriz de perfiles

La gente va a marcar combinaciones que nosotros no probamos. El costo es tiempo de
maquina (~35 min por corrida), asi que la matriz **no va en cada cambio**: va en una
corrida nocturna o a mano antes de publicar.

Minimo:

| Perfil | Por que |
|---|---|
| **recomendados** | el default, lo que va a usar el 90% |
| **todo marcado** | el maximo de debloat: encuentra lo que se rompe al sacar de mas |
| **nada marcado** | Windows limpio. "Cero" tiene que ser distinguible de "sin perfil" (bug real) |
| **tema claro + otro acento** | la rama `InstallThemeLight`. Solo probamos la Dark, y el bug estaba justo en la rama que no mirabamos |

Ese ultimo importa mas de lo que parece: `InstallThemeDark` era el bug **porque nunca
probamos con tema claro**. Cubrir las dos ramas.

## 6. Que NO se puede automatizar (y hay que decirlo)

- **La activacion real.** Requiere una licencia legitima y hardware que coincida. En VM
  no va a activar nunca, asi que Personalization va a estar en gris. **No es un bug del
  proyecto**: el runner lo reporta como `SIN MEDIR (requiere activacion)`.
- La instalacion en **hardware real** (Secure Boot, TPM, drivers, anticheat). La VM se
  acerca pero no es lo mismo. Ver `docs\dia-d.md`.
- Que las apps de `winget` instalen bien: depende de internet y de repos de terceros.
  Se verifica que el instalador CORRIO y que dejo log, no que cada app este.
