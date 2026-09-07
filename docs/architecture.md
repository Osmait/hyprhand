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
  runtime/               sesión, control, guardas, auditoría, eventos y GC
  input/                 teclado, puntero, movimiento, scroll y aura
  capture/               observación, revisión de layout y captura de cursor
  accessibility/         recorrido AT-SPI y puente C
  preview/               controlador, protocolo, visor GTK, CSS y ABI C
tests/                   pruebas offline y live explícitamente separadas por runner
protocols/               XML Wayland; C y headers se generan en la caché
scripts/                 verificación y empaquetado local
experimental/            puentes de compositor opt-in, nunca autocargados
docs/                    contratos, compatibilidad, decisiones y evidencias
```

La extracción de observación y ayuda reduce `main.zig` de 848 a 620 líneas.
El build raíz pasa de 111 a 48 líneas; generación Wayland y variantes opcionales
viven en módulos específicos. No se han alterado nombres de comandos, rutas
instaladas, formato JSON, frame v2 ni protocolo DCP1.

## Límites entre componentes

`main` coordina la CLI, runtime, captura y entrada. Los algoritmos de movimiento
y scroll reciben un driver, lo que permite pruebas sin compositor. La geometría
y el protocolo del PiP son datos/validación; no crean ventanas ni dispositivos.
`runtime` gestiona autoridad y ciclo de vida; `platform` implementa operaciones
de bajo nivel sin conocer nombres de comandos.

El visor GTK es otro ejecutable y otra raíz de módulo: no enlaza la entrada ni
sesiones. Solicita capturas y parada mediante workers de la CLI con la identidad
de sesión fijada. La CLI no adquiere GTK como dependencia por reorganizar carpetas.
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
apropiadas aquí. Esta distribución tampoco convierte el grafo en capas estrictas;
la coordinación de entrada sigue en `main` y puede extraerse de forma incremental.
