# Actualizar la BIOS de la mother nueva (B560M AORUS ELITE rev 1.x)

> Relevado el 2026-07-31. **Este documento existe porque hay un solo pendrive** y las dos
> cosas que necesita el día D — el firmware de la BIOS y la ISO de LunaticOS — exigen
> formatos de disco **incompatibles entre sí**.
>
> Flashear la BIOS es la única operación de todo el día D que puede dejar la placa
> **muerta**. No es un paso más de una lista.

## El hardware en juego

| Qué | Cuál | Detalle que importa |
|---|---|---|
| Mother nueva | GIGABYTE B560M AORUS ELITE rev 1.x | Tiene **botón Q-Flash Plus** en el panel trasero |
| CPU | Intel **i5-11400F** (Rocket Lake, 11ª gen) | La **F** significa **sin gráficos integrados** |
| GPU | Discreta (obligatoria) | Sin ella no hay imagen, ni para entrar a la BIOS |
| Pendrive | SanDisk Cruzer Fit 58,7 GB | **El único que hay** |

---

## El problema, en una tabla

Q-Flash (la utilidad de BIOS de Gigabyte) **solo lee FAT32/FAT16/FAT12**. No lee NTFS y
no lee exFAT. Eso choca de frente con la ISO:

| Necesidad | Formato exigido | Por qué |
|---|---|---|
| Firmware de la BIOS (`.bin`, ~16 MB) | **FAT32 obligatorio** | Es lo único que entiende Q-Flash |
| ISO de LunaticOS (**7,5 GB**) | exFAT o NTFS | FAT32 tiene techo de **4 GB por archivo** |

En una sola partición es **imposible**. El pendrive venía con Ventoy en MBR y la partición
de datos en **exFAT** — o sea que, tal como estaba, la BIOS no iba a ver el firmware ni
sabiendo que estaba ahí.

### Por qué NO se resuelve con particiones

La primera idea fue reinstalar Ventoy reservando espacio y crear una tercera partición
FAT32 chica. **Se descartó**, y el motivo es el 11400F:

Rocket Lake es 11ª generación. Si la placa viene con una BIOS de fábrica que no lo
soporta, **no va a dar imagen** — y sin imagen no se puede entrar al setup para usar
Q-Flash normal. El único camino ahí es **Q-Flash Plus**, que flashea sin CPU, sin RAM y
sin GPU apretando el botón del panel trasero.

Y Q-Flash Plus es **mucho más estricto** que Q-Flash normal: quiere un pendrive
**FAT32 de una sola partición**, con el archivo en la raíz y renombrado exactamente
`gigabyte.bin`. Un pendrive multipartición es justo lo que puede hacerlo fallar.

> **Conclusión:** el pendrive tiene que ser FAT32 puro para la BIOS. La ISO va después,
> por otra vía. Es un plan de **dos etapas separadas en el tiempo**, no un pendrive que
> hace las dos cosas.

---

## El plan de dos etapas

### Etapa 0 — Vaciar el pendrive (con la PC vieja todavía andando)

- [ ] Copiar **todo** lo que tenga el pendrive a `E:\pendrive-backup`:
  ```powershell
  New-Item -ItemType Directory -Force -Path "E:\pendrive-backup" | Out-Null
  robocopy "F:\" "E:\pendrive-backup" /E /R:1 /W:1 /NFL /NDL /XD "System Volume Information"
  ```
- [ ] Verificar con los ojos que se copió antes de formatear. El formateo no se deshace.

### Etapa 0.5 — Pasar la ISO a la notebook ⚠️ EL PASO QUE SE OLVIDA

La ISO **no está en el repo y nunca va a estar**: `work/` y `*.iso` están en
`.gitignore`, y pesa 7,5 GB. Clonar el repo en la notebook te da **los scripts**, no la
ISO.

Si no hacés este paso, desde la notebook tenés que **reconstruir la ISO de cero**: bajar
la imagen original de Windows 11 (~6 GB), instalar el ADK, y correr el pipeline completo
`00→11`. Son **horas**, con la PC principal ya desarmada y sin red de contención.

- [ ] Copiar `work\Win11_25H2_Pro_debloat.iso` (7,5 GB) a la notebook **hoy**, por red
      local (carpeta compartida SMB) o por cable. Es el camino más rápido y directo.
- [ ] **Verificar el hash en la notebook**, no asumir que llegó entera. Una ISO corrupta
      no se nota hasta la mitad de la instalación:
  ```powershell
  # En la PC principal:
  Get-FileHash "work\Win11_25H2_Pro_debloat.iso" -Algorithm SHA256
  # En la notebook, sobre la copia: los dos hashes tienen que ser IDENTICOS.
  ```
- [ ] Copiar también el respaldo de Claude (`.claude` + `engram`) si querés retomar con
      contexto desde la notebook — ver `dia-d-respaldo.md` paso 1.5.

### Etapa 1 — Pendrive FAT32 con el firmware

- [ ] Bajar la **última** BIOS de la página de soporte oficial y **anotar la versión**:
      <https://www.gigabyte.com/Motherboard/B560M-AORUS-ELITE-rev-1x/support>
- [ ] ⚠️ **Leer las notas de cada versión intermedia.** Gigabyte a veces exige pasar por
      una versión puente antes de saltar a la última. Si dice eso, respetá el orden.
- [ ] **Descomprimir el `.zip`.** Q-Flash no abre archivos comprimidos.
- [ ] Formatear el pendrive en **FAT32, una sola partición, MBR**.
      ⚠️ **Windows no ofrece FAT32 en volúmenes de más de 32 GB** (ni por el Explorador ni
      por `diskpart`). El pendrive es de 58,7 GB, así que hay dos salidas:
      - **Rufus** → dispositivo, "Non bootable", sistema de archivos **FAT32**. Formatea
        los 58,7 GB sin problema. *(Recomendado: es una sola operación.)*
      - O crear a mano **una** partición de **32 GB en FAT32** y dejar el resto sin
        asignar. Q-Flash Plus queda contento igual.
- [ ] Copiar el `.bin` a la **raíz** del pendrive y **renombrarlo `gigabyte.bin`**.
      Guardá también una copia con el nombre original al lado.

      > Renombrarlo a `gigabyte.bin` **no molesta a Q-Flash normal** (ahí elegís el
      > archivo de una lista, se llame como se llame) y es **obligatorio** para Q-Flash
      > Plus. Un solo pendrive que sirve para los dos caminos.
- [ ] Nada más en el pendrive. Ni ISO, ni Ventoy, ni carpetas.

### Etapa 2 — Flashear, ya con la placa montada

Montá la placa, la CPU, la RAM y **la GPU discreta** (sin ella no hay imagen: el 11400F
no tiene salida de video propia). Conectá el monitor a la GPU, no a la placa.

- [ ] ⚠️ **Antes de empezar: que no se corte la luz.** Si tenés UPS, enchufá la PC ahí.
      Un corte a mitad de flasheo brickea la placa. Esto es lo único irreversible del día.

**Camino A — la placa da imagen (lo esperable).** El chipset B560 salió junto con Rocket
Lake, así que lo más probable es que postee de fábrica:

- [ ] Entrá al setup (`Del`) → **Q-Flash** (`F8`, o desde el menú) → elegí el archivo del
      pendrive → confirmá → **no toques nada** hasta que reinicie solo.

**Camino B — la placa NO da imagen, o queda en bucle.** Ahí es BIOS demasiado vieja para
el 11400F:

- [ ] Conectá solo la fuente (no hace falta CPU, ni RAM, ni GPU).
- [ ] Pendrive en el **puerto USB del panel trasero marcado para Q-Flash Plus** (está
      identificado en el manual; es uno específico, no cualquiera).
- [ ] Apretá el **botón Q-Flash Plus**. La luz empieza a titilar: está flasheando.
- [ ] **Terminó cuando la luz deja de titilar.** Puede tardar varios minutos. No apagues,
      no desenchufes, no apretes de nuevo.

### Etapa 3 — Configurar la BIOS (recién ahora)

⚠️ **En este orden y no al revés:** flashear **resetea la BIOS a defaults**. Si configurás
primero y flasheás después, perdés toda la configuración y no te vas a acordar qué tocaste.

- [ ] Con la BIOS nueva ya puesta, aplicá `docs\dia-d.md` sección 3:
      **Secure Boot ON**, **Intel PTT (TPM 2.0) ON**, **CSM DISABLED**, disco en **AHCI**.
- [ ] Confirmá en la pantalla principal que la versión de BIOS es la nueva.
- [ ] Confirmá que reconoce el **i5-11400F** por nombre y la RAM completa.

### Etapa 4 — La ISO al pendrive, desde la notebook

Con la BIOS ya actualizada, el pendrive queda libre para su segundo trabajo.

- [ ] En la notebook: **Rufus** → la ISO → esquema **GPT** · destino **UEFI (no CSM)**.
- [ ] ⚠️ **Rufus, no Ventoy.** Rufus es la opción **probada** de este proyecto. Ventoy monta
      la ISO como disco virtual y puede no exponer el `autounattend.xml` en la raíz del
      medio — ver `docs\dia-d.md` sección 2. Cambiar a Rufus resuelve ese riesgo de paso.
- [ ] ⚠️ Rufus ofrece "customizar" la instalación (saltear cuenta MS, quitar requisitos).
      **Rechazá todo.** Inyecta su propio unattend y **pisa el nuestro**, que ya hace eso
      y está probado.
- [ ] Seguí con `docs\dia-d-respaldo.md` PARTE 2.

---

## Lo que NO hay que hacer

- ❌ **`@BIOS` desde Windows.** Flashear desde el sistema operativo es el camino con más
  casos de brickeo. Existiendo Q-Flash, no hay razón.
- ❌ **Actualizar "porque sí" a la última si la placa ya arranca bien y todo funciona.**
  Cada flasheo es un riesgo real. Si postea, reconoce el CPU y la RAM, y no tenés un bug
  concreto que resolver, es defendible quedarse. La excepción son las versiones que
  agregan **microcódigo de estabilidad de Rocket Lake** — esas sí valen.
- ❌ **Interrumpir el proceso** por lento que parezca.
- ❌ **Configurar la BIOS antes de flashear.** El flasheo lo borra.

## Si algo sale mal

| Qué pasó | Qué mirar |
|---|---|
| Q-Flash no ve el pendrive | Está en NTFS o exFAT. Tiene que ser **FAT32**. |
| Q-Flash no ve el archivo | Sigue comprimido, o no está en la raíz. |
| Q-Flash Plus no arranca (no titila) | Puerto USB equivocado, no está renombrado `gigabyte.bin`, o hay más de una partición. |
| La placa no da imagen tras flashear | Limpiá CMOS (jumper o quitar la pila). Volvé a probar. |
| No postea ni con Q-Flash Plus | Probá con **un solo módulo de RAM** en el slot que indica el manual. |
