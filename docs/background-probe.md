# Prueba de workspace oculto en el mismo Hyprland

Resultado local: **no cumple el requisito de entrada general sin quitar el
foco al usuario**. No se ha implementado un backend de entrada en segundo plano.

Entorno: Hyprland 0.56.2, configuración Hyprlang, aplicaciones de prueba GTK4
Wayland; ventana testigo en workspace 1 y destino en workspace 4, oculto y
previamente sin ventanas. Se usó el mismo compositor, no una sesión anidada.

## Evidencia observada

| Operación sobre el destino oculto | Resultado en destino | Eventos de foco del teclado en la ventana testigo |
| --- | --- | --- |
| Línea base sin acciones | Sin cambios | Ninguno |
| AT-SPI `EditableText.set_text_contents` | Texto Unicode exacto confirmado por GTK | Ninguno |
| AT-SPI `Action.do_action` en botón | Señal `clicked` confirmada | Ninguno |
| Hyprland `sendshortcut` dirigido, tecla `a` | Tecla recibida y texto modificado | Un `wl_keyboard.leave` y un `wl_keyboard.enter` |

En la última fase GTK también notificó pérdida y recuperación de foco. Mientras
tanto, tanto las consultas finales como las muestras de `activewindow` indicaron
la misma ventana activa. El cursor y los workspaces visibles no cambiaron durante
las cuatro fases. **La ventana activa global no basta para detectar el robo
transitorio del foco del teclado.** No se mide aquí su duración exacta.

Esto coincide con el código de
[Hyprland 0.56.2, `Actions::pass`](https://github.com/hyprwm/Hyprland/blob/v0.56.2/src/config/shared/actions/ConfigActions.cpp):
redirige el foco del asiento Wayland a la superficie destino, envía la entrada
y restaura el foco previo. Restaurarlo no equivale a no haberlo cambiado.

## Alcance y límites

- La escritura y el botón por accesibilidad son éxitos concretos en GTK4,
  no una garantía para cualquier aplicación, diálogo o control personalizado.
- No se probaron un editor de video, arrastres de una línea de tiempo ni capturas
  de ventanas ocultas. Una sola pérdida de foco ya contradice el requisito
  estricto; no se continuó con inyección de puntero.
- No se enviaron teclas ni acciones de contenido a Brave ni a otras aplicaciones
  del usuario. Preparar la prueba sí abre y enfoca ventanas temporales y cambia
  su distribución. La invariancia medida corresponde a las fases, no al montaje.
- Al terminar se cerraron ambas ventanas temporales, desapareció el workspace 4
  vacío, Brave volvió a estar activo y el control `host` quedó deshabilitado.
  No se restauró la posición inicial del cursor para no sobrescribir movimientos
  posteriores del usuario.

Para trabajar en interfaces arbitrarias simultáneamente, el aislamiento de
entrada requiere algo más que separar workspaces. Las sesiones gestionadas
separan la entrada, pero queda pendiente resolver el renderizado headless en
esta GPU y validar el editor concreto. No se promete todavía edición de video
completamente oculta y sin interferencias.

## Repetir voluntariamente

```sh
python3 tests/background_probe.py --live --workspace 4
```

Requiere el binario compilado en `zig-out/bin/deskctl`, Python con GI/GTK4/AT-SPI,
sesión Hyprlang desbloqueada y un workspace destino sin uso. Durante la prueba
no se debe escribir. El script verifica identidad de las ventanas y habilitación,
registra eventos GTK y Wayland sin guardar el contenido del usuario, emite JSON
y aborta si cambia la ventana activa global. El veredicto se deriva de eventos:
una ejecución sin pérdidas observadas devuelve `not_established`, no una
garantía universal.
