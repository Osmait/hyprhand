# Rendimiento y fiabilidad: seguimiento de septiembre de 2026

Base analizada: `cd500ce` (`main`). Zig 0.16.0, Linux, ReleaseSafe.
Las pruebas de este seguimiento no usan el escritorio ni los sockets del host.
Los tiempos sintéticos incluyen los servidores/helpers Python del fixture y no
equivalen a latencia de Hyprland, una GPU o una aplicación real.

## Correcciones

- **Parada sin escrituras nuevas.** `enable` publica una generación antes de
  consultar al compositor. `stop` elimina generación, token e indicador bajo
  el cerrojo de autoridad, intentando todas las revocaciones aunque alguna
  falle. Así no depende de escribir un journal para quitar la autorización.
  La regresión usa `RLIMIT_FSIZE=0`, comprueba que la entrada posterior queda
  bloqueada y que un `enable` concurrente anterior no puede volver a publicarse.
  Permisos de directorio, fallos del kernel o un filesystem incapaz de eliminar
  archivos siguen pudiendo impedir una revocación; no se promete lo contrario.
- **Wayland no bloqueante entre eventos.** La sincronización usa
  `prepare_read`/`read_events`/`cancel_read`, mantiene el deadline y comprueba
  cancelación durante las esperas. Se cubren mensajes incompletos, timeout,
  SIGTERM y un `EAGAIN` real inyectado en `wl_display_flush`. Las teclas ya
  encoladas conservan su limpieza independiente.
- **Auditoría recuperable.** La escritura completa se reintenta, una escritura
  fallida revierte la cola parcial cuando el filesystem lo permite, y el
  siguiente append recupera la última línea no confirmada. `logs` informa
  `incomplete_tail` sin perder acceso a registros completos y parsea solo los
  últimos registros solicitados. No se registran texto escrito ni títulos.

## Optimizaciones

- Una comprobación completa antes de cada carácter. La sincronización reutiliza
  solo esa comprobación inmediatamente precedente; al tener que esperar otra
  iteración vuelve a validar. No hay caché de autorización entre caracteres.
- Arenas de guardas reutilizables con retención máxima de 256 KiB; memoria de
  movimiento delimitada por muestra. Se mantienen foco, bloqueo, geometría,
  exclusión exclusiva del aura propia y verificación de posición del cursor.
- JSON de salida serializado con un buffer fijo de 4 KiB. No se acumulan
  cadenas de eventos en la arena del proceso. Hay una regresión que transmite
  4096 eventos de 60 KB con un límite de espacio virtual de 128 MiB.
  El máximo de 64 KiB se aplica por registro, no al bloque recibido: varios
  eventos grandes adyacentes ya no se rechazan por compartir una lectura.
- Limpieza automática de capturas amortizada cada 30 s. `gc` explícito siempre
  recorre el directorio; ninguna variante elimina capturas todavía utilizables.
- PiP con worker persistente y una solicitud pendiente como máximo. Mantiene
  `grim` por captura, pero elimina un arranque de CLI por frame. Revalida sesión
  e identidad antes/después de capturar y libera memoria entre solicitudes.
- E/S cancelable y decodificación de textura fuera del hilo GTK, tamaño acotado
  antes de reservar, slices PNG sin copia y reutilización exacta de texturas.
  Imágenes idénticas reducen gradualmente la captura hasta 1 fps; cambios de
  contenido restauran la frecuencia solicitada. No cambia el diseño del visor.
- Telemetría opt-in distingue capturas, cambios de textura, pinturas GTK y
  timestamps de presentación proporcionados por GDK. El benchmark live incluye
  ahora CPU de workers persistentes vivos, además de los ya recolectados.

## Comparación offline

Medianas antes: auditoría previa, 4 muestras por longitud. Después: script
reproducible, 5 muestras. Las cifras temporales son orientativas; los recuentos
IPC son la comparación más estable. No se ejecutaron ambos binarios en una
campaña alternada bajo cargas idénticas.

| Escritura | IPC antes → después | Mediana antes → después |
| --- | --- | --- |
| 16 caracteres | 74 → 42 | 6,60 → 5,33 ms |
| 128 caracteres | 522 → 266 | 27,54 → 16,80 ms |
| 1024 caracteres | 4134 → 2086 | 195,80 → 100,23 ms |

Con 1 ms de demora artificial por consulta, 128 caracteres pasaron de
568,14 ms (3 muestras) a 291,48 ms (5 muestras).

Eventos de 60 KB: antes, el RSS máximo pasó de 18 664 KiB (10 eventos) a
65 792 KiB (1000 eventos). Después, ambas longitudes registraron 23 636 KiB.
`wait4.ru_maxrss` puede incluir el máximo heredado antes de exec; interesa la
ausencia del crecimiento proporcional, no comparar el suelo absoluto entre
ejecuciones de Python. La regresión de memoria acotada es independiente de
estos valores de RSS.

```sh
zig build check pip pip-test -Doptimize=ReleaseSafe
python3 tests/viewer_broadway.py
python3 scripts/benchmark_offline.py --samples 5
python3 scripts/benchmark_viewer_offline.py --seconds 300
```

Las pruebas GTK opcionales usan Broadway sobre sockets Unix privados, con un
PNG válido sintético: reutilización de textura, pérdida/recuperación de señal y
cierre durante captura, incluso si `grim` ignora TERM. No requieren navegador,
no abren una ventana en el host y no acreditan presentación física en Wayland.
La primera ejecución larga se descartó porque los procesos de la fuente falsa
expiraban a los 60 s; el fixture ahora dura más que el ensayo y perder señal
invalida sus resultados.

Ensayo válido de **300,12 s**, después de 5 s de calentamiento, a un máximo
solicitado de 15 fps: **2,28 % de un núcleo** (visor y workers), RSS del visor
**85,41 MiB** tanto inicial como final, sin variación en las muestras cada 5 s.
Hubo 327 respuestas frescas contando el calentamiento y una sola textura nueva;
la fuente estática terminó capturándose aproximadamente a 1 fps. Cierre normal,
sin procesos propios supervivientes. Es una prueba de estabilidad de cinco
minutos, no una certificación de ausencia de fugas durante horas ni una medida
de FPS en un monitor físico.

## Alcance pendiente de verificación live

La comparación con los antiguos 51–77 % de un núcleo del PiP **no es válida**:
aquellos datos usaron Hyprland/NVIDIA y este seguimiento usa Broadway/helpers
sintéticos. Se necesita repetir el benchmark opt-in sobre la misma GPU, con
video en movimiento y durante horas. El script admite hasta una hora y no
habilita control, pero abre su propio PiP en el host al usar `--live`.

PipeWire/zero-copy y eliminar el proceso `grim` requieren un backend distinto;
no están implementados ni se presentan como consecuencia de este cambio.
Las limitaciones de posicionamiento tras cambios de monitor, XWayland gestionado
y otras GPU del informe anterior permanecen fuera de este seguimiento.
