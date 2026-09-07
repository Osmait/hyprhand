# Matriz de compatibilidad — 0.4.0

Esta matriz distingue pruebas locales documentadas, cobertura automatizada sin
escritorio y compatibilidad pendiente. Los resultados se limitan a las versiones,
aplicaciones y escenarios descritos en cada registro. La configuración de CI
no demuestra por sí sola una ejecución remota satisfactoria.
`status: sent` solo confirma envío, no el efecto en
la aplicación; se necesita observar y verificar cada resultado.

| Entorno o función | Evidencia y alcance | Límites |
| --- | --- | --- |
| Ubuntu 22.04 y 24.04, Linux x86_64/glibc | CI configurado con Zig 0.16.0 y Python 3.12: compilación, tests unitarios, protocolos simulados, ciclo de vida y contrato de fiabilidad offline | No ejecuta Hyprland ni aplicaciones gráficas; los resultados remotos deben consultarse en cada ejecución de CI |
| GTK4/Wayland sobre Hyprland 0.56.2 | El registro local describe texto, clic/doble clic, movimiento, scroll, arrastre y cancelación en fixtures GTK4 | No certifica otros toolkits, versiones, GPUs o todas las escalas/rotaciones |
| GTK4/XWayland | El registro local incluye pruebas del fixture X11; `tests/live_smoke.py --x11` comprueba backend, texto, clic y scroll | Teclado/scroll dependen de `xdotool`; scroll en detentes enteros, no subpíxeles. No implica paridad completa con Wayland ni las mismas garantías de liberación de entrada |
| GTK4 en workspace oculto, mismo compositor | La [prueba local de fondo](background-probe.md) confirmó acciones AT-SPI de texto/botón sin pérdida de foco en ese fixture | `sendshortcut` produjo salida/entrada de foco Wayland en primer plano. Otro workspace no aísla la entrada; `activewindow` puede ocultar esa interrupción |
| Sesión propia anidada, Hyprlang/Lua | Registros locales de ciclo de vida y entrada en ventanas propias | Abrir/cerrar la previsualización puede afectar el foco del host. Aislamiento de entrada no es aislamiento de archivos, red, permisos o credenciales; apps gestionadas deben usar Wayland |
| Blender 5.2.1 LTS / Wayland nativo | En una instancia nueva con configuración de fábrica, dentro del compositor hijo, `Shift+F4` cambió la vista 3D a la consola Python y `Ctrl+Space` maximizó el editor de consola; ambos resultados verificados mediante capturas. El fallo previo de Shift queda corregido para ese atajo y escenario | **Compatibilidad parcial**: no valida otros atajos, modos, perfiles, versiones ni XWayland. Los problemas anteriores de scroll y arrastre no se consideran resueltos por estas pruebas; un éxito en GTK no demuestra éxito en Blender |
| Headless sin puente en el stack NVIDIA documentado | El registro local indica `HeadlessRenderUnavailable` | No hay fallback silencioso al host; no se promete soporte headless general |
| Headless con puente experimental | Registro previo de captura/clic GTK4 y ciclo de vida en NVIDIA, **Aquamarine 0.15.0 + Hyprland 0.56.2**, Hyprlang/Lua | Solo nueva sesión headless propia, selección explícita del `.so`, ABI exacta y renderizador Wayland del padre. No combinar con `--nested`; no funciona como escritorio autónomo sin sesión gráfica |
| Suite headless de fiabilidad 0.4.0, GTK/Wayland | Suite completa con **10 comprobaciones verificadas**: atajos/modificadores, todos los modos de scroll explícitos e implícitos y cancelación. Además, el [registro local](reliability-040.md) recoge escritura Unicode exacta, clic normal, arrastre de 270 px y rechazo con `StaleObservation` ante cambios de geometría durante la aproximación | Solo el fixture GTK y el stack documentado, **Hyprland 0.56.2 + Aquamarine 0.15.0** con puente headless explícito. No certifica XWayland, Blender, otras GPUs ni equivalencia de distancia visual entre aplicaciones |
| Contorno de cursor experimental | Registro local de flecha/I-beam, clics y apagado en compositor desechable; Hyprland **0.56.2**, OpenGL, Hyprlang | No se incluye/carga al empaquetar. Activación Lua, cursores animados, todas las escalas/rotaciones y sesiones largas no están validados |
| Otras arquitecturas, musl, otras distribuciones o compositores | Sin matriz de paquetes ni resultado local establecido aquí | Requieren compilación y validación propias; no se promete compatibilidad binaria |

Los resultados GTK/Wayland/XWayland proceden del registro local en
[PLAN.md](../PLAN.md) y de los alcances de los fixtures en `tests/live_smoke.py`,
`tests/live_motion.py` y `tests/live_advanced.py`. Los resultados y restricciones
de headless/contorno se detallan en [puentes experimentales](experimental-bridges.md).
El [registro local de fiabilidad 0.4.0](reliability-040.md) reúne la evidencia,
incidencias y límites de la suite GTK y de las dos comprobaciones puntuales en Blender.
Las pruebas offline de
`tests/fixtures/test_reliability_contract.py` validan las guardas y los criterios
de éxito con eventos sintéticos; no sustituyen la verificación en una aplicación.

En Blender, vuelve a observar tras cada acción y comprueba el editor activo,
el modo y el efecto real. No encadenes atajos/scroll/arrastres basándote solo en
una respuesta de envío. El ejemplo Python cambia una escena y guarda un archivo;
su validación de sintaxis no demuestra que el control GUI funcione.

El puente headless depende de APIs internas. La compilación verifica Aquamarine
0.15.0, pero esa comprobación por sí sola no garantiza la ABI del proceso en el
que se cargue; el alcance documentado sigue siendo Hyprland 0.56.2. Debe aplicarse
solo al nuevo compositor hijo, nunca precargarse globalmente ni en el host.
No añade soporte genérico para otras GPUs/versiones. Los perfiles y el D-Bus son
propios, pero los permisos del usuario y sus archivos siguen compartidos.

Los paquetes incluyen metadatos de plataforma y dependencias, no una promesa
de portabilidad universal. Consulta [dependencias](dependencies.md) antes de
instalar. Los workflows no cambian la visibilidad privada del repositorio,
no publican releases/tags y no aportan una licencia de redistribución.
