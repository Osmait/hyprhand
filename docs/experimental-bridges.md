# Puentes experimentales: cursor y headless

La CLI y la entrada siguen en Zig. Estas bibliotecas opcionales usan C++ porque
interactúan con APIs internas de Hyprland/Aquamarine. La compilación normal no
las necesita. No son MCP ni plugins de Codex. No cambian drivers, temas, la
configuración personal ni el asiento físico.

Son código dentro del compositor: un error puede cerrarlo. Compila localmente
con las versiones exactas indicadas y prueba primero en una sesión desechable.
No reutilices binarios tras actualizar Hyprland/Aquamarine. Nunca cargues una
biblioteca de procedencia desconocida. Las comprobaciones de ruta/versión no
constituyen una auditoría de seguridad ni una garantía de ABI.

## Headless en NVIDIA (Aquamarine 0.15.0)

```sh
zig build -Doptimize=ReleaseSafe
zig build headless-bridge
./zig-out/bin/deskctl session create prueba \
  --headless-bridge /RUTA/AL/PROYECTO/zig-out/lib/deskctl-headless-formats.so
./zig-out/bin/deskctl enable --session prueba
./zig-out/bin/deskctl launch --session prueba -- brave-browser
./zig-out/bin/deskctl observe --session prueba
# Al terminar:
./zig-out/bin/deskctl stop --session prueba
./zig-out/bin/deskctl session destroy prueba
```

Requiere C++23, pkg-config y headers de Aquamarine **0.15.0**, pixman y libdrm.
La ruta debe ser absoluta, archivo regular propio o de root, no escribible por
grupo/otros, sin enlaces finales, espacios ni `:`. Es una selección explícita
de código de confianza, no un mecanismo de sandbox. No se combina con `--nested`.

La CLI establece `LD_PRELOAD` únicamente en el nuevo proceso Hyprland, no en
deskctl, el compositor padre, su D-Bus, registro AT-SPI ni apps lanzadas por
deskctl. El compositor experimental podría transmitir su entorno a procesos
que él mismo ejecutase; no agregues comandos `exec` a su configuración de prueba.
La biblioteca elegida queda registrada en `session inspect`.

[Aquamarine 0.15.0 Headless.cpp](https://github.com/hyprwm/aquamarine/blob/v0.15.0/src/backend/Headless.cpp)
busca formatos del backend DRM y, sin ellos, usa formatos/modificadores de
respaldo. El puente mantiene la preferencia DRM y añade los formatos ya
negociados por el backend Wayland con el padre. Si no hay formatos disponibles,
no inventa un modificador. No garantiza soporte en cualquier GPU/version.

Resultado local: sin puente, `HeadlessRenderUnavailable`; con él, HEADLESS-1
1920×1080, captura GTK4 y clic con texto «Clic recibido». Ciclo de vida,
espera de píxeles, eventos, cambio de workspace y ausencia de procesos propios
vivos tras destruir comprobados con Hyprlang y Lua. La prueba comprueba también
que la precarga no llega al bus/registro/apps.

```sh
python3 tests/live_sessions.py --live --headless \
  --headless-bridge /RUTA/AL/PROYECTO/zig-out/lib/deskctl-headless-formats.so
# Repetir con --lua para ese proveedor.
# Prueba gráfica; exige inspeccionar la captura y pulsar Enter:
DESKCTL_TEST_SESSION=prueba python3 tests/live_motion.py --live
```

Sigue usando el compositor padre como proveedor del renderizador. No es una
sesión gráfica autónoma ni permite manejar tus ventanas del host sin foco.
Las apps/perfiles son propios; los archivos/permisos del usuario no se aíslan.

## Resplandor de silueta (Hyprland 0.56.2, OpenGL, Hyprlang)

```sh
zig build cursor-plugin
./zig-out/bin/deskctl session create cursor-prueba --nested
./zig-out/bin/deskctl session inspect cursor-prueba
```

Del resultado toma `runtime` e `instance`. Carga solo en esa instancia de prueba:

```sh
XDG_RUNTIME_DIR=RUNTIME_DE_PRUEBA hyprctl -i INSTANCIA_DE_PRUEBA \
  plugin load /RUTA/AL/PROYECTO/zig-out/lib/deskctl-outline.so
./zig-out/bin/deskctl enable --session cursor-prueba --indicator outline
# Observa/interactúa con una app de prueba y verifica el resultado.
./zig-out/bin/deskctl stop --session cursor-prueba
XDG_RUNTIME_DIR=RUNTIME_DE_PRUEBA hyprctl -i INSTANCIA_DE_PRUEBA \
  plugin unload /RUTA/AL/PROYECTO/zig-out/lib/deskctl-outline.so
./zig-out/bin/deskctl session destroy cursor-prueba
```

No copies esos comandos apuntando al host sin decidir expresamente aceptar el
riesgo. El plugin compara el hash de los headers con el compositor al cargar,
y rechaza renderizadores no OpenGL. Compilar con una ABI/toolchain incompatible
sigue siendo arriesgado, como explican los
[requisitos de plugins de Hyprland](https://wiki.hypr.land/Plugins/Development/Getting-Started/).

Usa `getCurrentCursorTexture()` y `getCursorBoxGlobal()` del
[gestor de puntero](https://github.com/hyprwm/Hyprland/blob/v0.56.2/src/pointer/PointerManager.cpp),
lee únicamente la transparencia de esa textura y dibuja su dilatación azul.
No lee la imagen del escritorio ni crea una superficie que intercepte entrada.
La silueta se recalcula cuando cambia el cursor; la posición y el token de
control se comprueban aproximadamente cada 20 ms. No es tiempo real.

La activación necesita el archivo privado `enabled` de la sesión. `stop`, un
token sustituido o eliminado apagan el efecto. Un SIGTERM de una acción no
revoca por sí solo `enable`: el indicador continuo permanece hasta `stop`.
Es un indicador de control habilitado, no una prueba de que todos los movimientos
del mouse provengan del agente; el host comparte el cursor con la persona.

Verificado: flecha y cursor de texto, permanencia en pausas, clics atravesando
el efecto, desaparición después de `stop`, carga/descarga aislada. Pendiente
validar cursores animados, texturas no RGBA o mayores de 256×256, todos los
escalados/rotaciones y sesiones largas. Texturas transparentes/opacas sin
silueta no producen resplandor; `enable` confirma la activación del dispatcher,
no garantiza que cada textura futura sea compatible. Lua no está soportado
por el dispatcher de activación de la CLI en esta versión.

## Revisión de frames y scroll

Los frames v2 mantienen foco global y geometría/workspaces de monitores, pero
limitan capas y ventanas a la salida capturada, incluyendo ventanas cruzadas.
Las regresiones simuladas demuestran que una barra/ventana de otra salida no
invalida el frame y que una superposición local sí. No se pudo reproducir con
certeza la causa exacta de todos los `StaleObservation` anteriores en X; no se
afirma que este cambio elimine todos esos errores. Caducidad de 30 segundos y
rechazo de cambios reales permanecen activos, sin reintentos de entrada ciegos.

El scroll nativo usa distancia continua acumulada con perfil minimum-jerk,
objetivo de paso de 16 ms y duración configurable. XWayland reparte detentes
enteros. Las pruebas unitarias cubren totales positivos/negativos en ambos ejes,
retrasos, modo instantáneo, cero y cancelación. Un `status: sent` sigue sin
probar el resultado visual de una aplicación.
