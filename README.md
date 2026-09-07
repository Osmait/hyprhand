# deskctl 0.4

CLI local de **computer use para Linux/Hyprland**, desarrollada en Zig 0.16.
Entrega JSON para agentes y scripts. Sin MCP, modelo de IA, portapapeles ni
servicio de entrada permanente.

Controla la sesión `host` (cursor/foco compartidos contigo) y sesiones propias
de Hyprland, con entrada independiente. No ofrece un segundo cursor sobre tus
ventanas actuales: una sesión separada tiene sus propias aplicaciones.

**Otro workspace no aísla la entrada.** En una prueba real con ventanas GTK4,
`sendshortcut` dirigido al workspace oculto quitó y devolvió el foco del teclado
a la ventana en primer plano, aunque `activewindow` no cambió. AT-SPI permitió
escribir y activar un botón sin esa interrupción, pero no garantiza control
general de un editor de video. [Evidencia y prueba reproducible](docs/background-probe.md).

## Estado de esta entrega

La entrega 0.4 refuerza las acciones en curso: vuelve a validar el frame durante
el movimiento, aborta ante interferencias con el cursor, envía teclas físicas de
modificadores además de sus máscaras XKB, separa el tipo de scroll de su duración
y destruye árboles de procesos propios con identidades verificadas.
[Dependencias](docs/dependencies.md), [compatibilidad](docs/compatibility.md) y
[empaquetado verificable](packaging/README.md).

| Área | Implementado |
| --- | --- |
| Observación | Estado, ventanas, monitores, workspaces, PNG con contrato de coordenadas |
| Entrada | Foco, workspace, movimiento, clic, doble clic, arrastre, scroll, texto Unicode y atajos |
| Robustez | Frames caducables, bloqueo entre acciones, control habilitable, parada, señales y verificación continua de foco/bloqueo |
| Sincronización | Esperas por foco, ventana, workspace, estabilidad geométrica o de píxeles; eventos NDJSON |
| Sesiones | Crear, inspeccionar, listar, lanzar apps y destruir; modo anidado y headless con detección de incompatibilidad |
| PiP opcional | Visor GTK4 flotante del background, solo lectura, cursor visible y parada de entrada sin cerrar apps |
| Accesibilidad | Árbol AT-SPI de solo lectura, límites de profundidad/nodos/tiempo y omisión de campos de contraseña |
| Mantenimiento | Auditoría sin texto escrito, rotación, limpieza de capturas, instalación, Bash/Fish, CI y skill |

**Headless en NVIDIA:** sin extensión, esta combinación de Hyprland 0.56.2 y
Aquamarine 0.15 falla al reservar buffers. Ahora hay un puente experimental
opcional que usa los formatos negociados con el compositor padre: se verificó
una salida 1920×1080 con captura y clic reales. No cambia drivers ni se inyecta
en el host. [Compilación, uso y límites](docs/experimental-bridges.md).
`--nested` sigue disponible. Ningún fallo cambia silenciosamente al host.

## Compilar e instalar

Compilación: Zig **0.16.x**, `pkg-config`, `wayland-scanner`, libwayland-client,
libxkbcommon, libatspi y GLib/GObject, con sus headers. Linux con pidfd (5.3+).
Ejecución: Hyprland; `grim` para captura; `xdotool` para teclado/scroll XWayland.
`wtype` solo es necesario al elegir el backend de teclado `helper`.
Sesiones propias: `Hyprland`, `dbus-daemon` y, para AT-SPI, `at-spi2-registryd`.

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/deskctl doctor
./zig-out/bin/deskctl --help

# Instalación local, sin sudo:
zig build -Doptimize=ReleaseSafe --prefix "$HOME/.local"
```

El prefijo recibe el binario, completados Bash/Fish y la skill bajo
`share/deskctl/skills/deskctl`. Asegura que `$HOME/.local/bin` está en PATH.
Para descubrir la skill automáticamente, enlaza su directorio a tu carpeta de
skills, solo si el destino todavía no existe:

```sh
ln -s "$HOME/.local/share/deskctl/skills/deskctl" "$HOME/.codex/skills/deskctl"
```

No se editan archivos de configuración de Hyprland ni se necesitan credenciales de IA.
El agente externo necesita una herramienta para visualizar las imágenes.

## Ver al agente en segundo plano

```sh
# Componente opcional: requiere GTK4 >= 4.8 y sus headers.
zig build pip -Doptimize=ReleaseSafe
./zig-out/bin/deskctl preview --session agent --fps 5
```

La sesión `agent` debe estar creada y en ejecución. El PiP aparece en el host,
sin bordes ni barras separadas: imagen completa y controles superpuestos.
Arrastra la imagen para moverlo y su esquina inferior derecha para redimensionar.
Es flotante y queda fijado entre workspaces. No envía clics ni
teclado al agente y no solicita el foco al abrirse. **Cerrar el visor no detiene
al agente**; **Detener agente** deshabilita la entrada de deskctl, sin cerrar apps
ni cancelar procesos externos. Una sesión bloqueada o perdida borra la imagen.

Primera versión: host Hyprlang (probado en 0.56.2), capturas de hasta 960×540 a
1–15 fps, 5 por defecto. Añade reglas temporales solo para su ventana, sin editar
tu configuración. GTK no se añade como dependencia de la CLI principal.
[Uso, arquitectura, pruebas y límites](docs/preview.md).

## Flujo básico en el escritorio actual

```sh
deskctl state --session host
deskctl enable --session host
deskctl focus DIRECCION_REAL --session host
deskctl wait focus --window DIRECCION_REAL --session host
deskctl observe --session host --monitor DP-1
# Visualiza image_path y usa el frame_id y coordenadas reales:
deskctl click --session host --frame FRAME_ID --x 620 --y 340 --dry-run
deskctl click --session host --frame FRAME_ID --x 620 --y 340
deskctl key ctrl+a --session host --window DIRECCION_REAL
deskctl type --session host --window DIRECCION_REAL --text 'Hola, ñ ✓'
deskctl observe --session host
deskctl stop --session host
```

La dirección se descubre en `windows` o `state`; no es un título de ventana.
`type` y `key` requieren que esa ventana siga enfocada.
Los comandos de puntero también aceptan `--window DIRECCION_REAL`: el punto
inicial debe estar dentro de esa ventana enfocada. Sin esta opción se protege
el foco observado inicialmente. Enfoca el destino **antes** de capturar: si el
foco o la geometría relevante cambian durante la aproximación, se aborta.
Esto puede cancelar recorridos con foco al pasar el mouse; no se ignora esa
interrupción de seguridad. Una nueva acción requiere una observación nueva.
Un arrastre que mueva o redimensione la ventana del compositor puede invalidar
su propio frame y abortar. Los arrastres dentro del contenido no cambian por sí
solos esa geometría; no se promete arrastre libre de ventanas con esta guarda.
`--dry-run` valida sin inyectar entrada, incluso con el control detenido.
Una respuesta `status: sent` no demuestra el resultado de la aplicación:
**observar → actuar → observar y verificar**.

## Movimiento suave del cursor

`move`, `click`, `doubleclick`, `scroll` y la aproximación al inicio de `drag`
recorren una línea recta desde el cursor actual, con aceleración y frenado
progresivos. La duración automática es de 200–600 ms según la distancia lógica;
si ya está en el destino no se añade espera. Se intenta actualizar cada 16 ms,
sin acumular pasos atrasados si el compositor responde más despacio.

```sh
deskctl move --session host --frame FRAME_ID --x 620 --y 340
# Duración explícita para el desplazamiento previo:
deskctl click --session host --frame FRAME_ID --x 620 --y 340 --move-duration-ms 400
# Compatibilidad con el salto instantáneo anterior:
deskctl move --session host --frame FRAME_ID --x 620 --y 340 --move-duration-ms 0
```

`--move-duration-ms` acepta `0` o `50..10000`. En `drag`, esta opción controla
solo la aproximación sin pulsar; `--duration-ms` (500 por defecto) controla el
recorrido suave con el botón pulsado. Las duraciones son objetivos, no garantías
de tiempo real. Cada paso mantiene las comprobaciones de parada/señal/bloqueo y
verifica la posición antes y después del movimiento. Si otro dispositivo mueve
el cursor, una aplicación lo recentra o el compositor restringe la posición,
se aborta con `CursorPositionMismatch`; no se intenta luchar por el cursor.
No es una garantía de exclusión atómica frente a entrada simultánea.

El movimiento pasa por las superficies intermedias y puede activar efectos
hover o foco al pasar el mouse, según tu configuración. Sigue compartiendo
mouse/foco en `host`: no implica aislamiento ni arbitraje con el mouse humano.

## Scroll progresivo

El scroll nativo reparte el desplazamiento con aceleración y frenado durante
500 ms por defecto. `--duration-ms` acepta `0` o `50..10000`;
`--move-duration-ms` sigue controlando solo la aproximación.
`--scroll-mode auto` conserva el comportamiento anterior: continuo con duración,
rueda con duración cero. `wheel` permite rueda discreta pausada y `continuous`
mantiene distancias continuas incluso con duración cero.

```sh
deskctl scroll --session host --frame FRAME_ID --x 620 --y 340 --dy 5 --duration-ms 800
deskctl scroll --session host --frame FRAME_ID --x 620 --y 340 --dy -5 --duration-ms 0
deskctl scroll --session host --frame FRAME_ID --x 620 --y 340 --dy 5 --scroll-mode wheel --duration-ms 800
```

Conserva el desplazamiento acumulado y comprueba parada, señal, bloqueo,
foco y posición del cursor entre eventos. La cancelación nativa emite fin de
eje; no deshace lo ya desplazado. Las apps deciden su escala e inercia, por lo
que no se promete la misma distancia visual que con la rueda discreta.
XWayland distribuye botones XTEST enteros en `auto`/`wheel`: no ofrece subpíxeles
ni la misma garantía de limpieza que el backend nativo. Rechaza `continuous`
explícito con `ContinuousScrollUnavailable`.

## Aura continua sobre el cursor real (experimental)

El plugin opcional `deskctl-outline` dibuja un resplandor azul usando la
transparencia de la textura real del cursor. Sigue la flecha y el cursor de
texto, incluso quietos, desde `enable --indicator outline` hasta `stop`.
No sustituye el tema ni captura entrada. Se verificó en un compositor de prueba;
**no se carga automáticamente ni está activado en tu escritorio principal**.

```sh
zig build cursor-plugin
# Solo después de cargar deliberadamente el plugin en la sesión elegida:
deskctl enable --session SESION --indicator outline
deskctl stop --session SESION
```

Requiere Hyprland 0.56.2 con headers/ABI coincidentes, OpenGL y configuración
Hyprlang. Si no está cargado, la activación falla y deja el control detenido.
Lua, cursores animados y todos los casos de escalado/rotación no están
validados. [Guía de prueba y riesgos](docs/experimental-bridges.md).
La CLI sigue en Zig; solo los dos puentes opcionales usan C++ por las APIs
internas de Hyprland/Aquamarine.

### Halo temporal compatible

Las acciones de mouse muestran por defecto un halo azul pequeño y
semitransparente alrededor de la punta del cursor. Sigue el recorrido, deja
pasar los clics y no solicita foco de teclado. No cambia el tema del cursor,
no modifica la configuración de Hyprland y no mantiene un proceso residente.
Este aro anterior no es el resplandor de silueta. Se omite cuando está activo
el indicador continuo. `--no-aura` omite el aro por acción, no apaga el plugin.

El halo aparece durante `move`, `click`, `doubleclick`, `scroll` y `drag`;
no durante `enable`, las observaciones ni la escritura de teclado. Desaparece
al terminar, ante errores, `stop` o SIGINT/SIGTERM. Las acciones muy breves
mantienen un mínimo aproximado de 100 ms para que el indicador pueda verse;
esa espera también es cancelable. Se puede omitir en una acción:

```sh
deskctl move --session host --frame FRAME_ID --x 620 --y 340 --no-aura
# Salto instantáneo, también sin la espera visual mínima:
deskctl move --session host --frame FRAME_ID --x 620 --y 340 --move-duration-ms 0 --no-aura
```

Implementación nativa Zig: superficies Wayland `layer-shell` con región de
entrada vacía y teclado deshabilitado, según el
[protocolo de wlroots](https://github.com/swaywm/wlr-protocols/blob/master/unstable/wlr-layer-shell-unstable-v1.xml).
La posición usa las coordenadas lógicas del monitor y el halo se dibuja a
escala 2. Requiere `wl_output` v4, compositor v4 y layer-shell v3; si no están
disponibles devuelve un error, sin omitir silenciosamente el indicador.
`--no-aura` conserva el backend anterior.

Las capturas tomadas durante una acción pueden incluir el halo; las capturas
posteriores no. Las animaciones/reglas de capas del usuario pueden influir en
su apariencia. Esto es un indicador visual, no aislamiento del mouse humano.

## Sesión independiente

```sh
deskctl session create agent --nested
# Añade --lua para una configuración Lua generada.
deskctl session inspect agent
deskctl enable --session agent
deskctl launch --session agent -- brave-browser
deskctl wait window --class brave-browser --session agent
deskctl state --session agent
deskctl observe --session agent
deskctl stop --session agent
deskctl session destroy agent
```

`--nested` abre una ventana de previsualización. Crear/cerrar esa ventana puede
cambiar el foco del host; la entrada dirigida al compositor interior no mueve su
cursor ni cambia su foco. Sin `--nested`, se intenta una salida headless oculta.
Incluso esta última usa el compositor padre para obtener el renderizador:
no es un escritorio autónomo arrancable sin sesión gráfica.

Cada sesión usa IPC, socket Wayland, directorio de ejecución y D-Bus privados.
Se impide adquirir el asiento físico mediante un backend libseat inválido.
Se elimina DISPLAY: las aplicaciones gestionadas deben usar Wayland.
Se generan configuraciones propias; nunca se carga tu configuración personal.

El entorno de aplicaciones usa carpetas XDG propias. Brave/Chromium reciben
`--user-data-dir` propio; Firefox recibe `--no-remote --profile`.
No se copian cookies ni credenciales. Otros programas pueden tener sus propios
mecanismos de reutilización de procesos: verifica siempre el PID/ventana creada.
El bus privado no activa servicios/portales del usuario; algunas funciones de
portales, integración de escritorio y selectores de archivos pueden no funcionar.

`destroy` termina las aplicaciones registradas, el compositor y su registro
AT-SPI/bus, junto con descendientes todavía atribuibles. Verifica UID, PID y
tiempo de inicio mediante pidfd; coordina lanzamientos y destrucción con un
bloqueo de ciclo de vida y confirma la salida tras TERM/KILL acotados. Conserva perfiles
y logs en la ruta indicada, normalmente hasta cerrar la sesión Linux.
Los descendientes que deliberadamente se independicen de su aplicación no
constituyen una frontera de procesos controlada por deskctl.

**Esto aísla la entrada, no el sistema de archivos, las credenciales, la red ni
los permisos del usuario.** HOME permanece intacto. Para contenido hostil se
necesita otro usuario, contenedor adecuadamente aislado o VM.

## Coordenadas y acciones

`observe` devuelve `frame_id`, `image_path` absoluto, dimensiones PNG,
rectángulo lógico, monitor, workspace, instancia, timestamps y revisión.
La escala de captura `--scale 0.1..2` es independiente de la escala del monitor.
Se soportan rotación, posiciones negativas y escala fraccional.

`move`, `click`, `doubleclick`, `drag` y `scroll` usan **píxeles de esa imagen**.
La CLI transforma a coordenadas globales. Cada frame caduca a los 30 segundos o
al cambiar foco/geometría/monitores/workspaces/capas relevantes. El esquema v2
considera capas y ventanas del monitor capturado, incluyendo ventanas que lo
cruzan; cambios de ventanas/capas solo en otro monitor ya no lo invalidan.
Se mantienen las comprobaciones globales de foco y geometría/workspace de
monitores. Los frames v1 se rechazan: toma una captura nueva. Esto no detecta todos los
cambios internos de una página ni elimina la carrera entre comprobar y actuar.

```sh
deskctl doubleclick --session agent --frame FRAME_ID --x 300 --y 200
deskctl drag --session agent --frame FRAME_ID --x 100 --y 200 --to-x 400 --to-y 200 --duration-ms 500
deskctl scroll --session agent --frame FRAME_ID --x 500 --y 400 --dy 2
```

Botones: `left|right|middle`. Scroll: `--dx/--dy` entre -100 y 100;
positivo derecha/abajo. XWayland usa botones XTEST y verifica PID de la ventana
enfocada de DISPLAY. La aplicación/compositor puede aplicar su propio factor.

Atajos: `ctrl+shift+Return`, `super+a`, `alt+Left`.
Modificadores: ctrl, shift, alt, super/logo, altgr; tecla final con nombre XKB.
El texto admite UTF-8 hasta 64 KiB, incluidos tabuladores y saltos de línea.
El teclado nativo trabaja en bloques de hasta 128 caracteres y comprueba el
control entre eventos. No se usa shell ni se altera el portapapeles.

Backend de teclado `auto`: nativo en Wayland, xdotool en XWayland.
`--backend helper` selecciona wtype/xdotool; `native` falla explícitamente en
XWayland. No hay fallback silencioso tras un error que pueda haber enviado texto.
La captura continúa usando grim; `observe --backend native` no está disponible.

## Esperas, eventos y accesibilidad

```sh
deskctl wait stable --session agent --stable-ms 300
deskctl wait stable --session agent --pixels --timeout-ms 5000
deskctl wait window --session agent --class brave-browser
deskctl wait workspace --session agent --workspace 2
deskctl events --session agent --limit 20 --timeout-ms 5000
deskctl accessibility --session agent --window DIRECCION_REAL --depth 5 --limit 100
```

`wait stable` compara revisiones geométricas; `--pixels` añade el contenido PNG
sin dejar capturas de espera. Una imagen estable no prueba que la red terminó
ni que se guardaron datos. `WaitTimeout` indica condición no satisfecha.
El plazo solicitado puede excederse por una llamada IPC/helper individual.

`events` emite NDJSON: eventos del socket2 y un resumen final. El timeout sin
eventos es un resumen normal; no implica error del compositor.

AT-SPI devuelve una lista de nodos con id/padre, rol, nombre, foco y bounds.
Opera en un proceso desechable con timeout externo, además de límites por
llamada. No lee el valor de contraseñas ni recorre sus hijos. Otros nombres
pueden contener información privada. Los bounds son **atspi-screen-unverified**:
en Wayland algunas apps devuelven orígenes 0,0; no se pueden usar directamente
como coordenadas de un frame. Un árbol vacío no demuestra ausencia de controles.

## Parada, registros y limpieza

`stop` revoca el token de la sesión sin esperar el bloqueo de la acción.
SIGINT/SIGTERM también cancelan. Durante entrada se comprueba el bloqueo de
pantalla, y durante escritura el foco esperado. Los helpers se revisan cada
25 ms; Wayland/IPC tienen esperas individuales de hasta 3 s. No es tiempo real.

El teclado y puntero nativos sueltan sus teclas/modificadores/botones propios
en la limpieza normal, cancelación y señales capturables. SIGKILL, fallo del
compositor y helpers X11 externos no ofrecen esa misma garantía. Una parada
no deshace texto/eventos ya enviados. No re-habilites automáticamente tras una
parada humana. No existe un botón pulsado persistente entre invocaciones.

```sh
deskctl logs --session agent --limit 20
deskctl gc --session agent --older-than-ms 300000 --dry-run
deskctl gc --session agent
```

La auditoría guarda fecha, sesión, acción y estado, no texto, argv ni títulos.
Rota aproximadamente a 1 MiB y conserva una rotación anterior.
Las capturas usan directorios 0700 y archivos 0600. `observe` limpia capturas de
más de 5 minutos; `gc` permite ajustar el umbral, pero nunca borra un frame
todavía utilizable. Solo elimina nombres exactos de frames regulares, no enlaces
simbólicos ni archivos ajenos. No sube datos a servicios externos.

Puedes añadir manualmente un atajo de emergencia Hyprlang; usa la ruta real:

```ini
bind = SUPER SHIFT, Escape, exec, /ruta/absoluta/deskctl stop --session host
```

## Pruebas y mediciones

```sh
zig build test
zig build integration -Doptimize=ReleaseSafe
python3 tests/keyboard_unit.py
python3 tests/keyboard_protocol.py
python3 tests/session_lifecycle.py
python3 -m unittest discover -s packaging -p 'test_*.py'
python3 tests/benchmark.py --session host

# Opt-in: crean ventanas temporales y emiten entrada real.
python3 tests/live_smoke.py --live
python3 tests/live_smoke.py --live --x11
# Movimiento suave y cancelación: exige revisar la captura y pulsar Enter.
python3 tests/live_motion.py --live
python3 tests/live_motion.py --live --aura-review
python3 tests/live_sessions.py --live
python3 tests/live_sessions.py --live --lua
python3 tests/live_sessions.py --live --headless

deskctl session create prueba --nested --lua
DESKCTL_TEST_SESSION=prueba python3 tests/live_smoke.py --live
DESKCTL_TEST_SESSION=prueba python3 tests/live_advanced.py --live
deskctl session destroy prueba
```

Las gráficas requieren Python GObject/GTK4. La suite simulada no emite entrada.
`tests/live_reliability.py` verifica eventos nativos en un fixture ya abierto en
una sesión gestionada explícita; no habilita control. Su modo puntero exige
revisar una captura nueva antes de cada acción. Consulta las instrucciones en
`tests/fixtures/reliability.py`.
CI compila ReleaseSafe y ejecuta pruebas sin escritorio en una matriz Ubuntu
22.04/24.04. El primer CI remoto de 0.3 pasó; la nueva matriz 0.4 necesita su
propia ejecución remota y no se considera validada por aquel resultado.
[Registro de fiabilidad 0.4](docs/reliability-040.md).

Verificación histórica de 0.3: 16 pruebas unitarias, 33 de integración; fixtures reales
Wayland, XWayland y Lua; arrastre/doble clic, cancelación y liberación observable,
AT-SPI, ciclo de vida sin procesos propios vivos tras destruir, y aislamiento
del cursor/foco del host durante entrada en la sesión anidada. La skill fue
validada y utilizada por otro agente para observar e interpretar una captura.

Movimiento suave verificado en GTK4/Wayland sobre el host: un recorrido de
400 ms con aura generó 24 posiciones distintas y tardó 411,24 ms; el modo
instantáneo generó una posición (104,46 ms incluyendo la espera visual).
Clic, doble clic, scroll y arrastre recibidos;
SIGTERM durante la aproximación impidió el clic y `stop` durante el arrastre
produjo la liberación observable del botón. Son mediciones locales, no un SLA.
El aura se inspeccionó en una captura real sobre el monitor rotado: foco de la
ventana conservado, clics atravesando el halo y sin capas residuales al terminar.

Entrega 0.3: prueba completa repetida en headless NVIDIA con el puente opcional.
Scroll inverso y horizontal recibieron 30 eventos nativos cada uno; modo
instantáneo, uno. SIGTERM tras iniciar el scroll cortó nuevos eventos de entrada;
la animación/inercia posterior pertenece a la aplicación. También pasaron clic,
doble clic, arrastre, cancelación durante aproximación y liberación por `stop`.

Medianas orientativas en esta máquina, no SLA: estado 3,16 ms; observación con
grim 25,23 ms (15 muestras); escritura de 180 caracteres 750,24 ms con wtype y
40,36 ms nativa (3 muestras y resultado recibido comprobado, ReleaseSafe).
Por estas medidas se migró el teclado y se
conservó grim para captura. Una captura nativa queda como optimización futura.

Salida JSON por stdout; diagnósticos por stderr. Excepciones: ayuda/versión son
texto; eventos es NDJSON. Exit codes: 0 éxito, 1 ejecución, 2 argumentos.
Errores: `{"ok":false,"err":{"code":"StaleObservation","message":"..."}}`.

## Estructura y referencias

El núcleo, IPC, coordinación, geometría y clientes de entrada están en Zig.
Los XML oficiales generan bindings C durante el build. AT-SPI utiliza un puente
C pequeño para evitar incompatibilidades del traductor de Zig con macros GLib;
recorrido, límites y serialización permanecen en Zig.

Referencias: [Hyprland](https://github.com/hyprwm/Hyprland),
[Aquamarine](https://github.com/hyprwm/aquamarine),
[puntero virtual](https://github.com/swaywm/wlr-protocols/blob/master/unstable/wlr-virtual-pointer-unstable-v1.xml),
[teclado virtual/wtype](https://github.com/atx/wtype),
[AT-SPI](https://github.com/GNOME/at-spi2-core),
[xdotool](https://github.com/jordansissel/xdotool).
Los protocolos incluidos conservan las licencias de sus autores.
