# Resplandor del cursor real: sonda y nuevo backend experimental

Requisito corregido: brillo azul ajustado a la silueta real de la flecha, sin
aro, durante todo el control del agente (`enable` → `stop`), incluso en pausas.
La sonda nativa no pudo obtener la silueta, como documenta el registro histórico
inferior. Ahora existe un plugin opcional probado en un compositor desechable:
[guía de los puentes experimentales](experimental-bridges.md). El aura circular
previa no cumple este requisito. No se modificó el tema ni se cargó el plugin
en el escritorio principal.

## Investigación y prueba local

Hyprland 0.56.2 anuncia `ext_image_copy_capture_manager_v1` y
`ext_output_image_capture_source_manager_v1`. Se implementó una sonda de solo
lectura, `_cursor_probe`, que pide exclusivamente la imagen del cursor, nunca
una captura del contenido de la pantalla. No registra ni guarda sus píxeles.

Con el cursor inicialmente oculto, no se recibieron restricciones utilizables
para iniciar una captura. Luego, dentro de una ventana GTK4 desechable, se movió
el cursor al botón de prueba, sin hacer clic. El resultado inmediato fue:

```json
{"ok":true,"width":24,"height":24,"hotspot":{"x":5,"y":1},"transparent":576,"nontransparent":0,"entered":true}
```

La petición tuvo éxito, pero **los 576 píxeles eran transparentes**: no existe
una silueta que pueda usarse para un resplandor fiel. La sonda ahora incluye
`usable_shape` para no confundir una respuesta correcta del protocolo con una
imagen utilizable. También rechaza buffers completamente opacos, que podrían
ser una redacción del compositor.

El [código de Hyprland 0.56.2, `CCursorshareSession::render`](https://github.com/hyprwm/Hyprland/blob/v0.56.2/src/managers/screenshare/CursorshareSession.cpp)
produce una imagen transparente cuando falta `cursorImage.surface`, además de
cuando falta el buffer o su textura. Esto explica el resultado para un cursor
proporcionado por el compositor, que no necesita una superficie de una app.
No se atribuye el fallo a una denegación de permisos: se recibió `enter` y el
buffer estaba transparente, no negro opaco.

No se generaliza esta limitación a todos los compositores ni a todos los
cursores de aplicaciones. No se intentó modificar permisos, drivers o el
compositor. Se cerró únicamente la ventana temporal y el control quedó parado.

## Resultado posterior

`experimental/cursor-outline/plugin.cpp` usa la textura interna del cursor,
sin hooks de funciones, y supera esta limitación en la sesión de prueba.
Se verificaron flecha, cursor de texto, clic atravesando el efecto, permanencia
durante pausas, desaparición al parar y descarga del plugin. Su uso en el host
sigue siendo una decisión explícita: carga código dentro del compositor.

La CLI sigue en Zig. Esta sonda y los protocolos vendorizados son diagnóstico,
no una implementación del indicador continuo por sí mismas. La sonda sigue
disponible al compilar el árbol de trabajo:

```sh
zig build
./zig-out/bin/deskctl _cursor_probe --session host
```
