# Endurecimiento de los puentes experimentales

Complemento de [experimental-bridges.md](experimental-bridges.md). La carga del
plugin sigue siendo manual y explícita en una instancia desechable. Compilar
no carga bibliotecas, no inicia un compositor y no modifica el escritorio.
Nunca se carga automáticamente en el host. El puente headless sigue siendo una
selección explícita al crear una sesión; no se cambió su implementación.

## Alcance de la revisión

Se modificaron únicamente `experimental/cursor-outline/plugin.cpp`, los dos
`build.sh` experimentales y este documento. No se reescribieron backends,
vtable, buffers internos, planificación del compositor ni despacho de frames
de clientes. Permanecen los límites de textura de 256×256 y la lectura de la
textura del cursor, no de la imagen del escritorio.

### Invalidación y recursos del cursor

En el [PointerManager de Hyprland v0.56.2](https://github.com/hyprwm/Hyprland/blob/v0.56.2/src/pointer/PointerManager.cpp),
los commits de superficies y cambios de buffer emiten `cursorChanged`. El
plugin sigue esa señal, también cuando la textura se actualiza en el mismo
objeto. Ahora daña inmediatamente el área anterior y la actual: un render
puede consumir `dirty` antes de la siguiente comprobación de 20 ms.

En cada render se comparan la referencia débil, ID, dimensiones, tipo y
transformación de la textura. Una sustitución invalida la silueta sin conservar
vivos los buffers anteriores. Tras recalcular se dañan de nuevo las áreas con
las dimensiones actualizadas. El temporizador detecta además cambios de
visibilidad del cursor. No se añadieron lecturas continuas de píxeles para
cursores estáticos ni un reloj de animación alternativo.

`stop`, revocación del token y descarga liberan la referencia al resplandor y
reinician dimensiones/cache. Esto ya no depende de que ocurra otro render.
El [destructor CGLTexture de la versión fijada](https://github.com/hyprwm/Hyprland/blob/v0.56.2/src/render/gl/GLTexture.cpp)
activa su contexto EGL y comprueba el apagado del compositor. Si un pase de
render aún conserva la textura, su última referencia sigue controlando su
destrucción; el plugin no borra recursos propiedad del compositor.

La limpieza elimina temporizador, listeners y dispatcher y tolera llamadas
repetidas. También se ejecuta si la inicialización lanza una excepción: el
[sistema de plugins de v0.56.2](https://github.com/hyprwm/Hyprland/blob/v0.56.2/src/plugins/PluginSystem.cpp)
omite `PLUGIN_EXIT` al expulsar un plugin cuya inicialización falló. Un fallo
al rearmar el temporizador desactiva el efecto y elimina ese temporizador;
las activaciones posteriores se rechazan hasta una recarga manual. Las
excepciones de los callbacks de render/señal/temporizador desactivan el efecto;
esto no garantiza recuperación de fallos del driver, señales fatales o falta
de memoria durante la propia limpieza.

### Transferencias GL y ABI

La lectura y creación de textura guardan y restauran framebuffer de lectura,
buffers de pack/unpack, alineación, longitud de fila, saltos de filas/píxeles y
binding de textura 2D. Los buffers se desvinculan durante las transferencias
con memoria CPU. Un guard de alcance restaura ese estado y elimina el FBO
temporal incluso con retornos tempranos o excepciones.

Se validan dimensiones finitas y enteras antes de convertirlas a enteros.
Texturas no RGBA, transformadas, demasiado grandes, totalmente opacas o
transparentes, framebuffer incompleto y errores GL no producen resplandor.
Una lectura fallida elimina la silueta anterior. Las consultas de error GL
consumen los errores consultados; no pueden preservar la cola de errores del
compositor. Tras un fallo se espera otra invalidación para recalcular, evitando
reintentos costosos en cada render.

El build exige Hyprland **0.56.2** o Aquamarine **0.15.0**, respectivamente.
El plugin comprueba además en compilación el tag `v0.56.2`, API `0.1` y un hash
de commit completo. Al cargar compara tanto el commit como el hash de ABI de
dependencias ofrecido por Hyprland, y exige el renderer GL con contexto GLES
3.0 o superior: el camino de lectura usa funcionalidades que GLES 2 no ofrece.
El hash de dependencias de Hyprland omite versiones patch. Estas comprobaciones
no prueban compatibilidad de toolchain, opciones de compilación ni todos los
cambios internos. Hay que recompilar tras actualizar compositor/dependencias.

Ambos builds habilitan diagnósticos C++, RELRO y resolución inmediata de
símbolos. El headless exige resolver referencias al enlazar con Aquamarine
(`-z defs`). El plugin conserva referencias que resolverá el compositor al
cargarlo explícitamente; no se usa una carga como prueba de compilación.

## Metadata e integración de instalación

Cada script acepta `SOURCE.cpp OUTPUT.so` y genera también
`OUTPUT.so.build-metadata`. `CXX`, si se define, debe ser un único ejecutable
o ruta, sin argumentos. Se necesitan C++23, pkg-config, sha256sum y las
utilidades GNU de Linux usadas por los scripts. Los flags de pkg-config se
separan en palabras sin evaluación de shell ni expansión de comodines.

La metadata es texto de diagnóstico; no se debe ejecutar ni usar con `source`.
Incluye SHA-256 de fuente/binario, compilador, target, flags, versiones y
macros de ABI de la biblioteca C++. El plugin incluye además las versiones de
dependencias declaradas en sus headers. No es una firma ni una garantía de ABI.
Los scripts publican desde un directorio temporal privado después de compilar
y recopilar metadata; un fallo ordinario de compilación conserva el resultado
anterior. Cada rename es atómico, pero la pareja binario/metadata no constituye
una transacción: comprobar siempre `binary_sha256` frente al `.so` utilizado.

La integración de instalación ya está completada por el propietario de
`build.zig`. Cada target opcional instala su `.so` y su `.so.build-metadata`
en `zig-out/lib` (o el directorio `lib` del prefijo seleccionado), mediante una
dependencia explícita entre los pasos de instalación. Las copias generadas
permanecen también en `.zig-cache`, en las rutas que imprimen los scripts.

Después de integrar el cambio se repitió
`zig build cursor-plugin headless-bridge`: ambos targets finalizaron bien.
Se verificó la existencia de las dos parejas instaladas y que el
`binary_sha256` de cada sidecar instalado coincide con su biblioteca instalada:

- `deskctl-outline.so` y `deskctl-outline.so.build-metadata`.
- `deskctl-headless-formats.so` y `deskctl-headless-formats.so.build-metadata`.

Esta comprobación solo compila, instala e inspecciona archivos; no añade ni
ejecuta pasos de carga o precarga. La integración no amplía las garantías de
ABI ni sustituye las pruebas pendientes en una sesión desechable.

## Evidencia y límites de validación

Verificado localmente el 2026-09-06 con GCC 16.2.1, headers Hyprland 0.56.2 y
Aquamarine 0.15.0:

- `zig build cursor-plugin` y `zig build headless-bridge`: compilan.
- Repetición conjunta tras integrar la instalación de metadata: ambas parejas
  presentes en `zig-out/lib`, con checksums binario/sidecar instalado iguales.
- Una compilación de sintaxis con tag de headers inyectado `v99.0.0` falla en
  el `static_assert` de versión. Inspección ELF: entrypoints del plugin,
  RELRO, resolución inmediata y pila no ejecutable presentes.
- Scripts: sintaxis shell, rechazo de argumentos ausentes y versiones
  incorrectas, rutas de salida con espacios, checksum de metadata y conservación
  de binario/metadata anteriores ante fallo del compilador; limpieza temporal.
- Harness C++ aislado que extrae las funciones revisadas y sustituye GL,
  renderer y temporizador por dobles, con AddressSanitizer/UBSan: restauración
  de estado GL en éxito, excepción y fallo de FBO; invalidación inmediata;
  daño por cambio de visibilidad; fallo de temporizador; revocación del token;
  liberación sin render y limpieza repetida. No crea contextos GL ni carga el
  plugin. Este harness temporal no es una suite de integración del compositor.

No se realizaron acciones de escritorio, carga/descarga de plugins ni pruebas
GPU. Quedan pendientes en una sesión desechable: animaciones reales de tema y
cliente, memoria/recursos durante sesiones largas, carga fallida y descarga
reales, múltiples salidas, escalados, rotaciones y comportamiento en distintos
drivers. Una modificación de píxeles en el mismo objeto sin señal ni cambio
de metadata no se puede detectar con este cache. La compilación y los dobles
no prueban corrección visual ni compatibilidad universal de GPU. Siguen
vigentes las limitaciones de Lua y headless documentadas en la guía original.
