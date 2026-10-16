# Murmur: guía para Claude Code

Murmur es una app de dictado por voz para macOS, al estilo Wispr Flow: mantenés **fn**, hablás, soltás, y el texto aparece donde está el cursor. Está escrita en Swift (SwiftPM, sin Xcode) y vive en la barra de menú.

## Comandos

```sh
swift build -c release                    # compilar (rápido, para probar cambios)
make install                              # compilar, firmar e instalar en ~/Applications
make run                                  # lo mismo y abrir la app
.build/release/Murmur --check             # ver configuración, modelo y claves
.build/release/Murmur --clean "texto"     # probar solo la limpieza con el LLM
.build/release/Murmur --transcribe a.m4a  # probar todo el proceso con un audio (--realtime, --raw)
./scripts/eval-cleanup.sh                 # pasar todos los casos de evals/ por la limpieza
```

Para un audio de prueba sin micrófono: `say -v Paulina -o prueba.aiff "texto"` y después `--transcribe prueba.aiff`.

## Cómo está armado (`Sources/Murmur/`)

| Archivo | Qué hace |
|---|---|
| `Hotkey.swift` | Tecla de atajo y escucha del teclado (CGEvent tap en su propio hilo). Esc nunca se intercepta. |
| `DictationController.swift` | Lógica de mantener, doble toque, manos libres, Esc y corte a los 5 min; cola de transcripciones en orden. |
| `AudioRecorder.swift` | Micrófono → 16 kHz mono en memoria; codificación AAC/WAV para subir. |
| `Streaming.swift` | Corta dictados largos en pausas (~20 s) y los transcribe mientras seguís hablando; incluye `withWatchdog`. |
| `Transcriber.swift` | whisper.cpp local (Metal + Neural Engine) y APIs de Groq/OpenAI; `APIHealth` para caer al modelo local. |
| `Cleanup.swift` / `CleanupPrompt.swift` | Paso de limpieza con LLM (muletillas, autocorrección, listas, mails, números) y sus instrucciones. |
| `DirectRoute.swift` | Opcional: saltar la VPN solo para los pedidos a la API (Groq bloquea VPNs). |
| `TextInserter.swift` | Pega con Cmd-V (o tipea), con opción de restaurar el portapapeles. |
| `Pill.swift` | El globito flotante. |
| `AppDelegate.swift` | Menú de la barra, permisos, abrir al iniciar sesión, recarga de ajustes. |
| `Config.swift` | Ajustes (`~/.config/murmur/config.json`) y claves (`~/.config/murmur/.env`). |

## Cosas a tener en cuenta

- **Permisos y firma.** macOS ata los permisos de Accesibilidad y Monitorización de entrada a la firma de la app. `scripts/create-signing-cert.sh` crea una firma local estable que `make` usa sola; sin ella, cada compilación pierde los permisos (`tccutil reset Accessibility local.murmur`).
- **No usar `Process.waitUntilExit()`.** En la app puede quedarse esperando para siempre si el proceso se lanzó desde un hilo de Swift concurrency. `DirectRoute` lee hasta el fin de los pipes.
- **Groq gratis:** ~8.000 tokens por minuto para la limpieza, unos 5 dictados. Las instrucciones de `CleanupPrompt.swift` tienen que ser compactas. Si se pasa el límite, Murmur pega el texto sin limpiar al instante, sin esperar.
- **Probar cambios a las instrucciones** con `./scripts/eval-cleanup.sh` antes de dar por bueno un cambio: un arreglo puede romper otro caso. Para probar sin recompilar, guardá tu versión en `~/.config/murmur/cleanup-prompt.md`.
- **Privacidad.** Sin telemetría, sin cuentas. El audio nunca se guarda (solo un archivo temporal privado de milisegundos para comprimir antes de subir). Nunca escribir el texto dictado en los logs; solo tiempos y tamaños.
- **Textos de la interfaz** con `L("English", "Español")`; se muestran en español si la Mac está en español.
- **Primera carga del modelo local** con Neural Engine: ~2–3 min una sola vez por compilación nueva.
