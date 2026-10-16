# Murmur: guía para Claude Code

Murmur es una app de dictado por voz para macOS, al estilo Wispr Flow: mantenés **fn**, hablás, soltás, y el texto aparece donde está el cursor. Está escrita en Swift (SwiftPM, sin Xcode) y vive en la barra de menú.

## Instalación guiada (si te pidieron instalar Murmur)

La persona puede no saber programar. Hablale en su idioma, de a un paso por vez, y avisale **antes** de cada momento en que tiene que hacer algo ella. Hay cuatro que solo puede hacer ella: la contraseña del llavero, los permisos, el ajuste de la tecla fn y la cuenta de Groq. Nunca muestres su clave de API.

1. **Revisá la Mac:** `uname -m` tiene que dar `arm64` (Apple Silicon) y `sw_vers` macOS 13.3 o más. `xcode-select -p` tiene que existir; si no, ejecutá `xcode-select --install`, pedile que pulse **Instalar** en la ventana que aparece, y seguí cuando `xcode-select -p` funcione.
2. **Bajá el proyecto** (por ejemplo, `git clone https://github.com/virumiranda/murmur ~/Projects/murmur`) y trabajá desde esa carpeta.
3. **Modelo local:** `make model` baja ≈1,8 GB. Corrélo en segundo plano y seguí con lo demás mientras baja.
4. **Firma local:** `bash scripts/create-signing-cert.sh`. Después, **antes** de compilar, avisale: *"Te va a aparecer una ventana que dice que codesign quiere usar la clave «Murmur Local Signing». Poné la contraseña de tu Mac y tocá «Permitir siempre»."* Corré `make install` en segundo plano: queda esperando hasta que ella acepte, y si no ve la ventana puede estar detrás de otras.
5. **Primera carga del modelo:** cuando terminen la descarga y la instalación, prepará el Neural Engine antes de abrir la app, para que su primer dictado no tarde 2–3 minutos: `say -v Paulina -o /tmp/murmur-prueba.aiff "hola, esto es una prueba"` y después `~/Applications/Murmur.app/Contents/MacOS/Murmur --transcribe /tmp/murmur-prueba.aiff --raw`.
6. **Abrí la app** (`open ~/Applications/Murmur.app`) y explicale los permisos que va a pedir: **Micrófono** (tocar Permitir), **Monitorización de entrada** y **Accesibilidad** (abrir Ajustes del Sistema y encender el interruptor de Murmur). Murmur los detecta solo en unos segundos.
7. **Tecla fn:** abrí `open "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"` y pedile que ponga **"Pulsar la tecla 🌐 para" → "No hacer nada"**. Si usa Wispr Flow u otra app de dictado con fn, que la cierre.
8. **Clave de Groq** (gratis, es lo que la hace rápida): abrí `open https://console.groq.com/keys`. Que entre con Google, toque **Create API Key** y la copie. Si la página dice "Access denied", tiene una VPN prendida: que la apague para registrarse. Cuando te diga que la copió, guardala vos desde el portapapeles sin mostrarla (`pbpaste`, comprobá que empiece con `gsk_`) en la línea `GROQ_API_KEY=` de `~/.config/murmur/.env`. Verificala con `curl` contra `https://api.groq.com/openai/v1/models` (tiene que dar 200). Usá curl: Groq rechaza el user-agent por defecto de Python.
9. **Si usa VPN:** con la VPN prendida, Groq responde 403. Explicale la opción `"bypassVPN": true` en `~/.config/murmur/config.json`: solo los pedidos de Murmur a Groq salen sin VPN y Groq ve su IP real. Activala solo si está de acuerdo.
10. **Probá:** que abra Notas, mantenga **fn**, diga algo y suelte. Sugerile activar **Abrir al iniciar sesión** en el menú del micrófono.

Si algo falla: `~/Applications/Murmur.app/Contents/MacOS/Murmur --check` muestra el estado, y `log stream --level info --predicate 'subsystem == "local.murmur"'` muestra lo que pasa mientras dicta.

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
