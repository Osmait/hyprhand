# Fiabilidad 0.4.0 — registro local

Pruebas realizadas el 6 de septiembre de 2026, Hyprland 0.56.2,
Aquamarine 0.15.0, GTK4 nativo, salida HEADLESS-1 1920×1080 con puente
experimental seleccionado explícitamente. Sesión desechable `reliability-040`;
ninguna entrada dirigida al escritorio host. No es una certificación de otros
equipos, aplicaciones o versiones.

## Puntero

- Clic con aura y ventana explícita: evento recibido y etiqueta de confirmación
  inspeccionada en una captura nueva.
- Arrastre normal de 270 px: receptor GTK confirmó `drag-end`, dx=270, dy=0.
- Cambio de geometría durante aproximación de 5 s: `StaleObservation` antes del
  clic. El contador de clics permaneció en uno. Se restauró la geometría de la
  ventana de prueba, no una ventana del usuario.
- Interferencia durante arrastre de 5 s: se movió deliberadamente el cursor del
  compositor hijo con su IPC exacto. deskctl devolvió `CursorPositionMismatch`
  y el receptor confirmó la liberación del botón (`drag-end`).
- Scroll de rueda dosificado y continuo inverso: desplazamientos visibles
  comprobados con capturas antes/después. La distancia visual no es equivalente
  entre modos y depende de la aplicación.
- La observación detallada detectó un quinto evento `surface` después de los
  cuatro pasos `wheel`: lo provocaba enviar fin de eje al terminar una rueda.
  Se limita ese cierre a gestos continuos. La repetición produjo exactamente
  cuatro eventos `wheel`, dy=1 cada uno, sin evento adicional.

## Teclado y pruebas sin escritorio

El backend envía teclas físicas de modificadores y máscaras derivadas de su
mapa XKB autocontenido. Las pruebas de protocolo utilizan sockets Wayland/IPC
privados simulados: no pueden inyectar entrada en un compositor real.

La primera ejecución GTK detectó una suposición incorrecta del observador:
esperaba una notificación de máscara cero inmediatamente después de soltar
Control. El receptor sí registró Control abajo, `a` con máscara Control y ambas
liberaciones. GTK actualiza la señal de modificadores al procesar eventos de
teclado; la siguiente tecla sin modificadores es la comprobación necesaria.
Referencia: [implementación de GtkEventControllerKey](https://github.com/GNOME/gtk/blob/main/gtk/gtkeventcontrollerkey.c).

La repetición completa pasó diez comprobaciones: tres grupos de atajos nativos,
los modos `auto`, `wheel` y `continuous` con ventana explícita e implícita, y
cancelación del scroll por SIGTERM sin eventos posteriores. Se inspeccionó una
captura nueva antes de cada acción de puntero. También se recibió exactamente
`Zig rápido: ñ ✓ — prueba Unicode` mediante escritura nativa.

`Shift+Tab` reveló otro fallo real: el mapa de un solo nivel no entregaba
`ISO_Left_Tab` y GTK no cambiaba de campo. Los mapas de atajos ahora incluyen
niveles Shift para Tab y letras; el mapa de escritura conserva texto exacto.
La navegación inversa y la selección por palabras con Ctrl+Shift pasaron después.

En Blender **5.2.1 LTS**, una instancia nueva con configuración de fábrica en
la misma sesión privada recibió `Shift+F4` y cambió de vista 3D a consola Python;
`Ctrl+Espacio` maximizó ese editor. Ambos efectos se comprobaron en capturas.
Esto valida esos atajos, no todo el modelado, scroll o arrastre de Blender.

Comandos reproducibles sin entrada gráfica:

```sh
zig build test
zig build -Doptimize=ReleaseSafe
python3 tests/integration.py
python3 tests/keyboard_unit.py
python3 tests/keyboard_protocol.py
python3 tests/session_lifecycle.py
python3 -m unittest discover -s packaging -p 'test_*.py'
```

Los ocho tests de teclado aislados también forman parte de los 26 tests Zig;
no deben sumarse dos veces. La integración tiene 36 casos, el protocolo de
teclado siete, el ciclo de vida doce y el empaquetado siete. El contrato del
observador gráfico tiene otros 31 tests sin escritorio: 119 casos automatizados
distintos en total entre estas suites.

Al finalizar se detuvo el control y se destruyó `reliability-040`. Se conservan
sus perfiles/logs temporales para diagnóstico; no se borraron archivos del
usuario. La prueba no guardó escenas de Blender.

## Límites conservados

No se añade entrada aislada a workspaces del mismo compositor, sandbox de
archivos/credenciales, acciones semánticas AT-SPI generales ni captura nativa.
Los puentes C++ siguen siendo experimentales y no se cargan en el host.
Las comprobaciones son guardas periódicas, no transacciones atómicas frente a
cambios simultáneos del escritorio. Después de una interrupción puede existir
entrada ya recibida; cancelarla no deshace sus efectos.
Mover/redimensionar la propia ventana con un arrastre puede invalidar el frame
y abortar; la prueba de arrastre verificada ocurrió dentro del contenido GTK.
