# Desarrollo de deskctl

CLI para Linux/Hyprland, Zig 0.16.x. La API pública es el contrato de comandos
y JSON; los módulos internos pueden reorganizarse sin cambiarlo.

## Verificación

```sh
zig build check -Doptimize=ReleaseSafe
zig build test                    # repetir unitarias en Debug
zig build pip -Doptimize=ReleaseSafe  # opcional, requiere GTK4 >= 4.8
python3 tests/keyboard_unit.py    # suite de teclado aislada
```

`check` compila la CLI y ejecuta formato, unitarias Zig, integración con un
compositor falso, IPC, protocolo de teclado, ciclo de vida de procesos, PiP,
contratos de fiabilidad y empaquetado. No abre ventanas ni inyecta entrada en
el escritorio. Las pruebas `live_*.py` y los probes necesitan una sesión de
prueba y autorización explícita; no forman parte de `check` ni de la CI normal.

## Criterios para cambios

- Reproducir el bug antes de corregirlo y conservar la regresión. Probar también
  errores, cancelación, límites y liberación de recursos.
- Validar datos externos antes de calcular o convertir. Devolver errores JSON,
  no usar `assert`/`unreachable` para datos del compositor, archivos o CLI.
- Usar assertions para invariantes internos demostrables, no como cuotas de estilo.
- Delimitar tiempo total y tamaño de IPC, buffers y trabajo repetido. No confundir
  timeout de cada lectura con plazo total de una operación.
- Documentar quién posee cada descriptor/proceso/buffer. Liberar con `defer` o
  `errdefer`; emplear arenas por iteración para consultas temporales en bucles.
- Usar `platform/child_process.zig` para limpiar hijos directos aún no recolectados;
  `runtime/sessions.zig` mantiene su propio protocolo PID/start/uid/pidfd para árboles.
  Nunca reutilizar estos mecanismos con PIDs arbitrarios.
- Conservar cancelación, foco, token y validación de frames. Un error no habilita
  entrada, no cambia a host ni autoriza repetir una acción con efectos.
- Mantener funciones centradas en una responsabilidad. Extraer por dominio,
  evitando carpetas genéricas `utils` y capas que solo reenvían llamadas.
- Usar `zig fmt`; mantener snake_case en nombres de archivos existentes.
  No mezclar cambios mecánicos de estilo con cambios de comportamiento sin pruebas.
- No registrar texto escrito, títulos, credenciales ni contenido de las aplicaciones.

Los recursos de demostración existentes no se borran por reorganizar código.
Los nuevos renders, vídeos y proyectos editables van en `output/` (ignorado).
No se cambia licencia ni se añaden dependencias sin una necesidad explícita.

Consulta [arquitectura](docs/architecture.md) y [auditoría](docs/audit-2026-09.md).
