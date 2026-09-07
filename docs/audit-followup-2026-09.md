# Seguimiento de auditoría — 2026-09-06

Parte de `4f230f3`. Alcance: cerrar tareas de mantenimiento verificables en este
equipo; no equivaler la ejecución de tests con ausencia de bugs o compatibilidad
universal. Se conservan `frame v2`, `DCP1` y nombres de comandos públicos.

## Implementado

- Extraídos `input/actions.zig` y `runtime/wait.zig`: `main` queda en unas
  220 líneas. Algoritmos y contratos permanecen en sus módulos de dominio.
- Presupuesto monotónico compartido para esperas, consultas, observación y
  acciones. Una sucesión de consultas lentas ya no renueva el timeout de `wait`.
  Limpieza y procesos persistentes conservan presupuestos independientes.
- `stop-generation` y `control.lock` impiden que un `enable` en curso publique
  autorización después de una parada que lo invalidó. Ninguna consulta al
  compositor ocurre mientras se mantiene ese cerrojo de publicación.
- Captura PiP con pipe no bloqueante y límite incremental de 8 MiB. Un helper
  que emite sin terminar se rechaza y recolecta aunque ignore SIGTERM.
- La sincronización inicial de Wayland comprueba cancelación antes de disponer
  de un runtime. La liberación de entrada ya encolada sigue siendo no cancelable.
- La comprobación X11 usa el entorno enrutado, igual que el helper de entrada,
  y el tiempo restante del comando; no hereda inadvertidamente el DISPLAY del host.
- Reglas PiP para Lua con identificadores internos, validación de respuesta y
  desactivación acotada tras señales. No se interpolan nombres externos en Lua.
- Benchmark PiP opt-in de solo lectura: latencia del worker, RAM del visor y CPU
  del visor con hijos recolectados. No habilita control ni cambia aplicaciones fuente.

## Pruebas

`zig build check -Doptimize=ReleaseSafe` pasó 27 unitarias Zig y 112 pruebas Python
(139 en total). Además: unitarias Debug, las 9 unitarias aisladas del teclado,
build GTK4 ReleaseSafe y comprobaciones de sintaxis/formato.

La carrera stop/enable y la espera compuesta fallaron contra el binario previo
y pasaron después. Las regresiones incluyen helper de salida ilimitada,
cancelación durante bootstrap Wayland y cierre de visor con reglas Lua.

Live, en sesiones desechables, sin habilitar el control del host:

- GTK4 Wayland: Control/Shift y combinaciones, selección de texto y navegación
  de foco; liberación de modificadores observada por la aplicación.
- Seis scrolls: auto, rueda y continuo, con/sin ventana explícita. En cada caso
  se revisó la captura; el receptor confirmó unidades y progresión. La prueba
  terminal de `stop` rechazó la acción y dejó de producir eventos de eje.
- Ciclo Lua headless: creación, enrutamiento, espera de píxeles, eventos,
  workspace, lanzamiento, entorno, cierre y ausencia de procesos propios vivos.
- PiP Hyprlang: dos mediciones de 120 s; foco del host igual en los extremos,
  fuente detenida intacta y visor cerrado sin destruir la fuente.
- PiP Lua: expresión de reglas y visor nativo comprobados en compositor aislado,
  imagen real, 640 × 360, floating/pinned, sin foco inicial y limpieza. El
  launcher integrado se valida offline, no se presenta como prueba live completa.

Todas las sesiones creadas para esta auditoría se cerraron. Sus perfiles y logs
temporales se conservan conforme a `session destroy`; no se borraron archivos
del usuario ni se cambió la configuración del compositor principal.

## Medición PiP

Hyprland 0.56.2, Aquamarine 0.15.0, NVIDIA con puente headless explícito, GTK4
4.22.4, ReleaseSafe. Fuente GTK estática 1920 × 1080; PNG reducido a 960 × 540,
mediana 32 525 bytes. No es una carga de video animado.

| FPS configurados | Tiempo | Worker mediana / p95 | CPU visor+hijos¹ | RSS final visor | Rango RSS últimos 30 s |
| --- | --- | --- | --- | --- | --- |
| 5 | 120,02 s | 100,03 / 109,05 ms | 50,61 % | 136,41 MiB | 2,29 MiB |
| 15 | 120,02 s | 99,55 / 111,26 ms | 76,63 % | 137,98 MiB | 2,17 MiB |

¹ Porcentaje de **un núcleo**, incluido tiempo de hijos ya recolectados; excluye
compositor/GPU. RSS solo del visor. El primer ensayo incluyó el arranque GTK;
el segundo usó 5 s de calentamiento. Las 30 latencias se midieron por separado
antes de cada visor. FPS configurados no son FPS presentados: no hay contador
de presentación. Dos minutos sin crecimiento sostenido aparente no demuestran
ausencia de fugas a largo plazo. El coste refuerza mantener 5 fps como defecto;
PipeWire/zero-copy requiere un backend nuevo y medición propia.

## Límites encontrados / pendientes reales

- Rotar/reducir el monitor con PiP abierto puede dejarlo parcialmente fuera de
  pantalla: reproducido en la salida Lua a escala 1,5 y rotación 90°. Falta
  reposicionamiento automático y validación de fullscreen/multimonitor.
- La sesión gestionada deshabilita XWayland al arrancar. Cambiar su opción
  dinámicamente no inició el servidor en esta versión. Se mantuvo el host fuera
  de alcance: X11 conserva regresiones offline y evidencia histórica, pero no
  una nueva prueba live en esta auditoría. Falta una ruta XWayland gestionada opt-in.
- Crear otra sesión desde un runtime ya gestionado superó el límite Unix de la
  ruta de socket de Hyprland (`Socket2 path is too long`). Falló por timeout y
  limpió los procesos. Falta diagnóstico previo para runtimes demasiado largos.
- Capturas comprimidas siguen siendo el backend; PipeWire/zero-copy, pruebas de
  horas, cursores animados y otras GPU siguen pendientes. No se instaló ningún driver.
- Los presupuestos son cooperativos. No acreditan ausencia de bloqueos internos
  en bibliotecas nativas ni límites de disco para toda salida posible de helpers.
- Licencia pendiente de elección del propietario; no se concedieron permisos nuevos.

La CI remota de `4f230f3` pasó en Ubuntu 22.04 y 24.04
([ejecución](https://github.com/Osmait/computer-use-hyperland/actions/runs/34074547410)).
Los resultados remotos del seguimiento deben asociarse al commit correspondiente,
no inferirse de esa ejecución anterior.

El código del seguimiento `261fe93` pasó la
[CI completa](https://github.com/Osmait/computer-use-hyperland/actions/runs/34075926551)
y el [empaquetado privado](https://github.com/Osmait/computer-use-hyperland/actions/runs/34075926414)
en ambos Ubuntu. No se creó tag ni GitHub Release. Esas ejecuciones detectaron
avisos por acciones Node 20: se actualizaron checkout/setup-python/upload-artifact
a las versiones publicadas v7, fijando sus SHA exactos en los workflows.
La modificación de workflows requiere otra ejecución para verificar sus nuevos pins.
