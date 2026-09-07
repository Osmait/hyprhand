# Dependencias y distribución

La CLI necesita bibliotecas del sistema. Los paquetes son específicos de Linux
x86_64/glibc y de su entorno de compilación; no son binarios universales,
autónomos ni estáticos. Consulta la [matriz de compatibilidad](compatibility.md)
y el [procedimiento de empaquetado](../packaging/README.md).

| Alcance | Dependencias |
| --- | --- |
| Compilar CLI | Zig 0.16.x; CI/empaquetado fijan **0.16.0**. `pkg-config`, `wayland-scanner`, libc y headers de Wayland client, xkbcommon, AT-SPI y GLib/GObject |
| Empaquetar y validar sin escritorio | Python 3.11+ (CI selecciona 3.12), Git, `readelf` y `strip` de binutils; compilación ReleaseSafe y tests unitarios/simulados/de ciclo de vida |
| Ejecutar CLI | Linux con pidfd (5.3+), cargador ELF y ABI de bibliotecas compatibles, Hyprland e IPC/socket Wayland de la sesión seleccionada |
| Capturas | `grim` |
| PiP opcional | `zig build pip`: GTK4 >= 4.8 con headers/pkg-config; `deskctl-pip` junto a `deskctl`, `grim`, host Hyprlang. No entra en el build/archivo estándar de la CLI. [Uso y límites](preview.md) |
| Teclado/scroll XWayland | `xdotool`, servidor XWayland y `DISPLAY` de la ventana destino |
| Teclado Wayland con `--backend helper` | `wtype`; el backend nativo no necesita este helper |
| Sesiones gestionadas | Ejecutable `Hyprland`, `dbus-daemon`; `at-spi2-registryd` para AT-SPI y widgets que expongan accesibilidad |
| Fixtures gráficos voluntarios | Python GI, GTK4 y AT-SPI; no se ejecutan en CI ni durante el empaquetado |
| Ejemplo Blender | Blender y la habitación original abierta; no es dependencia de la CLI |

El teclado nativo genera mapas XKB autocontenidos: necesita **libxkbcommon**,
pero no los archivos de datos de `xkeyboard-config` ni `/usr/share/X11/xkb`.
No usa los includes ni los nombres de configuración del entorno para construir
esos mapas. Los helpers y otras aplicaciones pueden tener sus propios requisitos.

Paquetes de compilación usados por CI en Ubuntu 22.04/24.04:

```sh
sudo apt-get update
sudo apt-get install -y libwayland-dev libwayland-bin libxkbcommon-dev \
  libatspi2.0-dev libglib2.0-dev pkg-config libc6-dev python3 binutils curl xz-utils
```

Esta lista prepara la compilación, no un escritorio Hyprland funcional.
En Ubuntu 22.04 hace falta seleccionar además Python 3.11+ para empaquetar:
el fixture de ciclo de vida usa `subprocess.Popen(process_group=...)`.
`libwayland-bin` aporta `wayland-scanner`. Los nombres de paquetes de ejecución
varían entre distribuciones y versiones (incluidas transiciones ABI de Ubuntu);
el gestor del sistema debe resolver sus dependencias transitivas. AT-SPI necesita
un bus accesible y soporte de la aplicación; instalar la biblioteca no garantiza
un árbol útil en interfaces personalizadas.

El [manifiesto base](../packaging/dependencies.json) describe requisitos por
función. Cada archivo distribuible añade las versiones observadas de pkg-config,
los SONAME directos, el intérprete ELF y símbolos glibc requeridos a su propio
`dependencies.json`. No incluye bibliotecas del sistema ni enumera todas sus
dependencias transitivas. Un build en una distribución reciente puede requerir
bibliotecas que no existen en otra más antigua. Los archivos por plataforma no
certifican que una sesión gráfica haya sido probada allí.

Los dos puentes C++ son opcionales y quedan fuera del paquete normal:

- Headless: Aquamarine **0.15.0**, C++23, pixman y libdrm; uso restringido al
  stack Hyprland **0.56.2** documentado, con renderizador del compositor padre.
- Contorno de cursor: headers de Hyprland **0.56.2**, C++23 y ABI coincidente;
  OpenGL y activación mediante Hyprlang. Lua no está validado/soportado para esa
  activación en esta entrega.

Compílalos localmente solo para su stack exacto; no reutilices sus `.so` después
de actualizar Hyprland/Aquamarine. Sus scripts también necesitan `sha256sum` y
utilidades GNU de Linux para generar metadata de compilación. Véanse los
[límites y selección explícita de los puentes](experimental-bridges.md) y el
[informe de endurecimiento y metadata](experimental-hardening.md).

En `examples/blender/style_room.py`, la salida se deriva de la carpeta del
`.blend` abierto. `DESKCTL_BLENDER_OUTPUT_DIR` permite elegir una carpeta absoluta
ya existente y es obligatorio si el archivo no está guardado. El script rechaza
guardar encima del `.blend` abierto; otros resultados anteriores con los nombres
de salida pueden reemplazarse. Configura `habitacion-realista.png` y guarda
`habitacion-realista.blend`, pero no ejecuta un render. La validación de este
ejemplo se limita a sintaxis y resolución de rutas simulada, sin ejecutar Blender.
