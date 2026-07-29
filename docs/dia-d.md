# Día D — instalar la ISO en la máquina real

Checklist operativo. Todo lo de acá salió de errores reales documentados en `decisiones.md`;
las notas **⚠️** no son paranoia, son cosas que ya nos pasaron.

---

## 1. Antes de tocar la máquina

- [ ] **Backup.** La instalación formatea la partición que elijas. Lo que no esté copiado, se va.
- [ ] Tener a mano en otro dispositivo: driver de red/Wi-Fi de la mother (si Windows no lo trae, quedás
      sin internet y sin poder bajarlo). Bajalo del sitio de Gigabyte para tu modelo exacto.
- [ ] Tu clave de licencia real de Windows, si vas a activar. La del `autounattend.xml` es la clave
      genérica pública de Pro: **fija la edición, no activa nada**.

## 2. Grabar el USB

Pendrive de **8 GB o más**. Cualquiera de las dos opciones sirve.

### Opción A — Ventoy (copiás la ISO y listo)

- [ ] Instalá [Ventoy](https://ventoy.net) en el pendrive **una sola vez** (con **GPT**, no MBR).
- [ ] Copiá `work\Win11_25H2_Pro_debloat.iso` a la partición de datos. Nada más.
- [ ] Ventaja: el pendrive queda reutilizable y podés tener varias ISOs juntas.
- [ ] ⚠️ **NO probamos esta ISO con Ventoy.** Ventoy monta la ISO como disco virtual, y el setup busca el
      `autounattend.xml` en la raíz del medio. Suele funcionar, pero **si al instalar te pide idioma o
      product key**, es que Ventoy no expuso la raíz: no es que la ISO esté mal. Pasate a la opción B.

### Opción B — Rufus (probado)

- [ ] [Rufus](https://rufus.ie) → elegí la ISO. Esquema **GPT** · Sistema destino **UEFI (no CSM)**.
- [ ] ⚠️ El `install.wim` pesa >4 GB, así que **no entra en FAT32**. Rufus lo detecta y parte el WIM solo
      (o formatea NTFS). Dejalo hacer lo suyo — no lo fuerces a FAT32 a mano.
- [ ] ⚠️ Rufus ofrece "customizar" la instalación (saltear cuenta MS, quitar requisitos). **Rechazá todo.**
      Eso inyecta su propio unattend y **pisa el nuestro**, que ya hace todo eso y está probado.

## 3. BIOS/UEFI de la mother (Gigabyte)

Entrá con `Del` (o `F2`) al arrancar.

- [ ] **Secure Boot: ENABLED.** Si está en Setup Mode o "Other OS", pasalo a Windows UEFI mode y
      cargá las claves por defecto (*Restore Factory Keys*).
- [ ] **TPM 2.0: ENABLED.** En AMD se llama **AMD CPU fTPM**; en Intel, **Intel PTT**. Está en
      *Settings → Miscellaneous → Trusted Computing* (o *Peripherals*, según BIOS).
- [ ] ⚠️ **Estos dos son innegociables** (regla de oro D5): Vanguard los exige. Sin ellos Valorant no
      abre y tirás `VAN9001`. Si los dejás para "después", vas a tener que reinstalar.
- [ ] **CSM (Compatibility Support Module): DISABLED.** Boot UEFI puro.
- [ ] Modo del disco: **AHCI** (no RAID), salvo que sepas exactamente por qué querés RAID.
- [ ] Guardá y salí (`F10`).

## 4. Bootear del USB

- [ ] `F12` al arrancar → boot menu → elegí la entrada **UEFI** del pendrive.
- [ ] ⚠️ **Apretá una tecla** cuando diga *"Press any key to boot from CD or DVD"*. Tenés ~5 segundos.
      Si se vence, aborta con `The boot loader failed` → reintentá el boot, no cambiés nada.
- [ ] ⚠️ **En los reinicios siguientes NO toques ninguna tecla.** Windows reinicia varias veces durante
      el setup; ese prompt es precisamente el mecanismo que hace que arranquen **del disco** y no del USB.
      Si apretás una tecla, relanzás el instalador desde cero → loop infinito. Ver **D17**.

## 5. Durante la instalación

Con el `autounattend.xml` funcionando, **lo único que te va a preguntar es el disco**.

- [ ] Elegí la partición/disco destino a mano. ⚠️ **El particionado no está automatizado a propósito**
      (D14): un `DiskConfiguration` en el unattend puede formatear el disco equivocado.
- [ ] Si venís de otra instalación de Windows: borrá **todas** las particiones viejas de ese disco
      (incluidas *System*, *MSR*, *Recovery*) y dejá espacio sin asignar. Windows recrea las suyas.
- [ ] No debería pedir: idioma, teclado, product key, EULA, edición, cuenta Microsoft, red.
      **Si pide algo de eso, el unattend no se aplicó** → ver la tabla de trampas del README.

## 6. Primer arranque — verificación

Entra solo al escritorio como **`pato`** (sin contraseña). Verificá:

- [ ] **Poné una contraseña ya.** El usuario es Administrator y nace sin password, a propósito
      (no se hardcodea un secreto en la ISO). `Settings → Accounts → Sign-in options`.
- [ ] Formatos **es-AR** (fecha `28/7/2026`) y teclado **ES LatAm** + EN US disponibles.
- [ ] **Edge bloqueado.** No se desinstala (imposible sin perder WebView2 — ver **D21**): se bloquea su
      ejecución. Probalo: `Win+R` → `msedge` → **no debe pasar absolutamente nada**.
      No debería haber ícono en el escritorio ni en el menú Inicio.
- [ ] **WebView2 presente** (si falta, la Store y Widgets se rompen):
      ```powershell
      Test-Path "C:\Program Files (x86)\Microsoft\EdgeWebView\Application"
      ```
- [ ] **EdgeUpdate VIVO** — sí, vivo: es quien mantiene WebView2 parchado.
      ```powershell
      Get-Service edgeupdate, edgeupdatem | Select-Object Name, StartType
      ```
      Esperado: `Automatic` y `Manual`. Si los ves `Disabled`, algo quedó del enfoque viejo.
- [ ] **Poné Firefox/Chrome como predeterminado**: `Settings → Apps → Default apps`. Con Edge bloqueado,
      los links que el sistema intente abrir con él fallan en silencio.
- [ ] **Secure Boot y TPM activos** (confirmación desde el SO, no desde la BIOS):
      ```powershell
      Confirm-SecureBootUEFI
      Get-Tpm | Select-Object TpmPresent, TpmReady
      ```
      Esperado: `True` / `True` / `True`.
- [ ] Red funcionando. Si no hay Ethernet ni Wi-Fi → instalá el driver que bajaste en el paso 1.
- [ ] Activá tu licencia real: `Settings → System → Activation`.

## 7. Post-install

- [ ] Región: debería estar en **Argentina**. Verificá con `Get-WinHomeLocation`.
- [ ] **WebView2 se actualiza solo** — no hay mantenimiento manual. Ese fue el punto de D21.
- [ ] ⚠️ **Si el ícono de Edge reaparece** tras un Windows Update grande: es sólo cosmético. Confirmá que
      sigue bloqueado (`Win+R` → `msedge` → nada) y borrá el acceso directo, o corré
      `herramientas\ocultar-edge.ps1` de nuevo. Lo que hay que vigilar es el IFEO, no el ícono.
- [ ] Instalá lo tuyo por winget (está intacto): `winget install ...`.
- [ ] Revisá `$ServicesOptional` en `scripts\config.ps1`: si te falta algo (impresora, Bluetooth, VR,
      RDP), ahí está documentado qué servicio lo maneja.

---

## Si algo sale mal

El disco de la instalación anterior guarda la evidencia. Los logs que sirven:

| Qué pasó | Dónde mirar |
|---|---|
| El unattend no se aplicó | `C:\Windows\Panther\setupact.log` — buscá `UnattendSearch` |
| La instalación abortó a mitad | `C:\Windows\Panther\setuperr.log` |
| Edge volvió | `C:\ProgramData\Microsoft\EdgeUpdate\Log\MicrosoftEdgeUpdate.log` |
| Edge no se pudo desinstalar | `C:\Windows\SystemTemp\msedge_installer.log` |

**Diagnosticá antes de parchar.** En este proyecto un solo defecto produjo cuatro síntomas distintos
(D14), y arreglarlo destapó un segundo defecto que estaba escondido debajo (D18). Leer el log primero
ahorró vueltas de 45 minutos cada una.
