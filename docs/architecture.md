# Arquitectura y organización

```text
build.zig                composición de artefactos y pasos públicos
build/                   dependencias nativas y artefactos opcionales
src/
  main.zig               entrada, coordinación de comandos y errores JSON
  pip_main.zig           raíz independiente del ejecutable GTK
  test_keyboard.zig      raíz de las unitarias aisladas de teclado
  cli/                   argumentos estrictos y ayuda
  core/                  geometría y contrato de frame, sin dependencias nativas
  platform/              FFI Linux/Wayland, señales, reloj, IPC y limpieza de hijos
  runtime/               sesión, control, guardas, esperas, auditoría, eventos y GC
  input/                 coordinación de acciones, teclado, puntero, movimiento, scroll y aura
  capture/               observación, revisión de layout y captura de cursor
  accessibility/         recorrido AT-SPI y puente C
  preview/               controlador, transporte acotado, cadencia, protocolo, GTK y ABI C
tests/                   pruebas offline y live explícitamente separadas por runner
protocols/               XML Wayland; C y headers se generan en la caché
scripts/                 verificación y empaquetado local
experimental/            puentes de compositor opt-in, nunca autocargados
docs/                    contratos, compatibilidad, decisiones y evidencias
```

La extracción de observación, ayuda, acciones y esperas reduce `main.zig`
de 848 a unas 220 líneas.
El build raíz pasa de 111 a 48 líneas; generación Wayland y variantes opcionales
viven en módulos específicos. Los comandos públicos, rutas instaladas, frame v2
y DCP1 se mantienen. El seguimiento de rendimiento añade `_preview_stream`
interno (longitud + DCP1) y el indicador aditivo `incomplete_tail` en `logs`.

## Límites entre componentes

`main` selecciona comandos y presupuestos; `input/actions.zig` coordina entrada
y `runtime/wait.zig` implementa las condiciones de espera. Los algoritmos de movimiento
y scroll reciben un driver, lo que permite pruebas sin compositor. La geometría
y el protocolo del PiP son datos/validación; no crean ventanas ni dispositivos.
`runtime` gestiona autoridad y ciclo de vida; `platform` implementa operaciones
de bajo nivel sin conocer nombres de comandos.

Cada proceso ejecuta un comando. `native.limitCommand` fija su presupuesto
monotónico compartido: las solicitudes IPC no lo renuevan. Las guardas y los
helpers consultan ese límite. La limpieza de entrada ya encolada y de hijos
propios conserva sus presupuestos independientes para no omitir liberaciones.
`wait --timeout-ms` incluye las consultas de una iteración; los comandos de
lectura habituales disponen de 10 s, las acciones de 30 s y `type` de 300 s.
Son límites cooperativos, no una garantía frente a bloqueo del kernel o de una
biblioteca nativa. Sesiones, eventos, AT-SPI y visor conservan límites específicos.

`stop` y la publicación de `enable` comparten un cerrojo local corto separado
del cerrojo de acciones. La generación de parada invalida un `enable` anterior
que aún estuviera esperando al compositor; el cerrojo no se retiene durante IPC.
`enable` crea esa generación antes de consultar al compositor. `stop` elimina
generación y autorización bajo el cerrojo: no necesita escribir datos nuevos
para revocar. Un error al eliminar un marcador no omite intentar los demás.

La memoria temporal de las guardas se reutiliza con retención máxima de 256 KiB.
Las comprobaciones no se cachean entre caracteres: solo se omite la validación
duplicada inmediatamente anterior a una sincronización de texto. La lectura
Wayland usa prepare/read/cancel y sondeo de escritura para EAGAIN, no dispatch
bloqueante después de poll. Eventos serializa JSON con un buffer fijo; la
limpieza automática de capturas recorre el directorio como máximo cada 30 s.
El comando explícito `gc` sigue ejecutándose siempre.

El visor GTK es otro ejecutable y otra raíz de módulo: no enlaza la entrada ni
sesiones. Solicita capturas y parada mediante workers de la CLI con la identidad
de sesión fijada. `transport.zig` hace E/S y decodificación fuera del hilo GTK;
`cadence.zig` planifica sin acumular solicitudes y reduce la frecuencia en reposo.
La CLI no adquiere GTK como dependencia por reorganizar carpetas.
La observación sí conoce el namespace del aura para excluir exclusivamente la
superficie propiedad del proceso actual; no elimina overlays ajenos.

## Referencias adaptadas

- [Build de Ghostty](https://github.com/ghostty-org/ghostty/tree/main/src/build):
  inspira separar el ensamblaje de artefactos de sus detalles de compilación.
  [Runtimes de aplicación](https://github.com/ghostty-org/ghostty/tree/main/src/apprt)
  sirven como referencia para mantener fronteras específicas de plataforma/UI.
- [TigerStyle de TigerBeetle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md):
  inspira límites explícitos, control claro, invariantes y pruebas de casos inválidos.

Es una adaptación a una CLI pequeña, no una copia de esas arquitecturas. No se
importa código, no se promete su nivel de robustez y no se adopta la prohibición
general de asignación dinámica de TigerBeetle: las arenas acotadas siguen siendo
apropiadas aquí. Esta distribución tampoco convierte el grafo en capas estrictas.
