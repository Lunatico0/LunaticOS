# Contrato: la cuenta de usuario es elegible

> Hoy el nombre de usuario esta **hardcodeado** en `config\autounattend.xml`
> (`<Name>pato</Name>`), y `perfil.json` tiene un campo `usuario` que **NADIE
> CONSUME**: `LunaticOS.ps1` lo carga en `$Global:UsuarioPerfil` y ahi muere.
> Un perfil que promete un dato y no lo aplica es peor que no tenerlo.
>
> LunaticOS va a publicarse. Nadie quiere llamarse `pato`, y renombrar una cuenta de
> Windows despues es un lio: la CARPETA del perfil queda con el nombre viejo para
> siempre. Se elige antes de instalar o no se elige nunca.

## 1. Que tiene que poder hacer el usuario

En la TUI, una entrada nueva del menu principal:

```
7. Cuenta de usuario                 crear 'pato'  /  la pide el OOBE
```

Adentro, dos caminos:

- **Crear la cuenta ahora** (default, marcado): pide un **nombre por teclado** y la ISO
  crea esa cuenta local. El OOBE no pregunta nada.
- **Que la pida el OOBE**: no se crea ninguna cuenta y el instalador la pide durante
  la instalacion.

## 2. EL COSTO DE "que la pida el OOBE" — hay que decirlo en la TUI

Windows 11 **24H2 y 25H2 ya no traen `bypassnro.cmd`**: Microsoft lo saco. Si el
autounattend no crea una cuenta local, el OOBE **exige cuenta Microsoft y conexion a
internet**. Para hacer cuenta local hay que:

1. `Shift + F10` en el OOBE,
2. escribir `start ms-cxh:localonly`,
3. y recien ahi aparece el formulario de cuenta local.

**La nota de esa opcion en la TUI TIENE que decir esto.** Ofrecer "que la pida el OOBE"
sin avisar que el camino te lleva a una cuenta Microsoft es tenderle una trampa al
usuario. Con el texto exacto del comando, para que lo pueda tipear.

Por eso el default es **crear la cuenta**.

## 3. `Show-TuiInput` — el input que falta en la TUI

`scripts\tui.ps1` tiene `Show-TuiChecklist`, `Show-TuiMenu`, `Show-TuiConfirm` y
`Show-TuiPause`. **No tiene input de texto.** Hay que agregarlo:

```powershell
# Devuelve el string, o $null si el usuario cancelo con Esc.
Show-TuiInput -Title '...' -Prompt '...' -Default 'pato' -MaxLen 20 -Validate { param($s) ... }
```

Requisitos:

- **Se lee tecla por tecla con `Get-TuiKey`, NO con `Read-Host`.** Dos razones: `Read-Host`
  rompe el frame de la TUI, y sobre todo **no pasa por `$Global:TuiKeyProvider`**, asi
  que no se podria testear con teclas inyectadas. Todo lo que lee input en este repo
  tiene que ser testeable sin humano.
- Soporta: caracteres imprimibles, **Backspace**, **Enter** (confirmar), **Esc**
  (cancelar y devolver `$null`).
- El texto se dibuja dentro del frame, con el largo actual visible (`nombre: pato_`).
- `-Validate` es un scriptblock que devuelve `$null` si esta bien o el **mensaje de
  error** si no. El error se muestra EN VIVO, debajo del campo, y **Enter no confirma
  mientras haya error**.

## 4. Validacion del nombre de usuario de Windows

No es cosmetica: un nombre invalido hace **fallar la creacion de la cuenta durante la
instalacion**, y eso se descubre 40 minutos despues, con el OOBE roto.

Reglas a aplicar:

| Regla | Motivo |
|---|---|
| 1 a 20 caracteres | limite de SAM |
| Prohibidos: `" / \ [ ] : ; \| = , + * ? < >` | los rechaza Windows |
| No puede terminar en `.` ni ser solo puntos/espacios | idem |
| No puede empezar ni terminar con espacio | genera perfiles raros |
| Nombres reservados: `CON PRN AUX NUL COM1-9 LPT1-9` | reservados por el SO |
| No puede ser igual al **nombre del equipo** | colisiona con la cuenta de maquina |
| Nombres ya usados por el sistema: `Administrator`, `Guest`, `DefaultAccount`, `WDAGUtilityAccount`, `SYSTEM` | ya existen |
| Se recomienda ASCII sin acentos | la CARPETA del perfil toma ese nombre, y una `n` con virgulilla en una ruta rompe herramientas viejas. Advertir, no prohibir |

Si el nombre es valido pero tiene espacios o caracteres no-ASCII: **dejarlo pasar con un
aviso** que diga que la carpeta del perfil va a ser `C:\Users\<eso>`.

## 5. El perfil.json

`usuario` pasa a usarse de verdad:

```json
"usuario": {
  "crear":   true,
  "nombre":  "pato",
  "zona":    "Argentina Standard Time",
  "teclado": "es-AR;en-US"
}
```

- `crear: false` -> no se crea cuenta, la pide el OOBE.
- Los perfiles VIEJOS no tienen `crear`. `Import-Profile` tiene que rellenarlo con
  `$true` (el comportamiento actual), no romper. Ya hay un test de "perfil incompleto
  no rompe": tiene que seguir pasando.
- `zona` y `teclado` **hoy tampoco se usan**. Si se conectan, que sea con la misma
  disciplina; si no, no los toques y quedan anotados como pendientes. **No los declares
  como funcionando si no lo estan.**

## 6. La inyeccion en el autounattend

Igual que la clave de producto (seccion 6 de `docs\personalizacion-contrato.md`):
**sobre una COPIA**, nunca mutando `config\autounattend.xml` del repo.

- **`crear: true`**: reemplazar `<Name>` y `<DisplayName>` con el nombre elegido.
- **`crear: false`**: quitar el bloque `<UserAccounts>` **completo** y tambien
  `<HideLocalAccountScreen>true</HideLocalAccountScreen>`, para que el OOBE muestre la
  pantalla de cuenta.
- Despues de tocar el XML: **validarlo** con las guardas que ya existen (XML valido,
  pass `windowsPE`, componentes correctos). Un `UserAccounts` mal quitado deja el
  archivo invalido y el instalador lo **descarta entero en silencio** (D14), o aborta
  a mitad de camino (D15).
- **`config\autounattend-test.xml` NO se toca por esta via.** Su cuenta lleva password
  fijo porque es la unica forma de que PowerShell Direct funcione, y el E2E depende de
  eso. Si el usuario elige `crear: false`, el de test **sigue creando su cuenta**.

## 7. Tests (probados por mutacion, como todo en este repo)

En `scripts\test-tui.ps1`:

1. `Show-TuiInput` con teclas inyectadas devuelve el string tipeado.
2. **Backspace** borra el ultimo caracter.
3. **Esc** devuelve `$null`.
4. **Enter con el campo vacio** no confirma (o devuelve el default, decidilo y testealo).
5. `-MaxLen` no deja pasar de largo.
6. Un nombre invalido **no se puede confirmar con Enter**, y se ve el mensaje de error.
7. Cada regla de la seccion 4 tiene su caso: caracter prohibido, nombre reservado,
   igual al nombre del equipo, 21 caracteres, punto final.

En `LunaticOS.ps1 -SelfTest`:

8. Un perfil viejo **sin** `usuario.crear` se importa con `crear = $true`.
9. Con `crear: true` y un nombre, el XML resultante tiene ese `<Name>`.
10. Con `crear: false`, el XML resultante **no tiene** `UserAccounts` ni
    `HideLocalAccountScreen`, **y sigue siendo XML valido con sus 3 passes**.
11. `config\autounattend.xml` del repo **no se modifica** en ninguno de los dos casos
    (comparacion de hash).
12. `config\autounattend-test.xml` conserva su cuenta con password pase lo que pase.
