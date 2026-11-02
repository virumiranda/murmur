# Murmur: guía para agentes de código (Claude Code, Codex y otros)

Murmur es una app de dictado por voz para macOS, al estilo Wispr Flow: mantenés **fn**, hablás, soltás, y el texto aparece donde está el cursor. Está escrita en Swift (SwiftPM, sin Xcode) y vive en la barra de menú, con una ventana (Inicio, Diccionario, Estilo, Transforms, Bloc de notas y Tomador de notas) que aparece en el Dock mientras está abierta. **Solo funciona en macOS** con Apple Silicon.

## Instalación guiada (si te pidieron instalar Murmur)

**Antes de empezar, fijate el sistema.** Si la persona usa Windows o Linux, no intentes instalarlo: Murmur depende de APIs de macOS. Explicale que no es compatible y ofrecele las alternativas de la sección "Windows" del README (el dictado de Windows con Win + H, Handy o Whispering).

**Si corrés comandos dentro de un sandbox** (por ejemplo, Codex), la instalación necesita salir de él: usa internet (clonar, compilar, bajar el modelo, hablar con Groq) y escribe fuera de la carpeta del proyecto (`~/Applications`, `~/.config/murmur` y el llavero de macOS para la firma). Pedí permiso para esos comandos, o pedile a la persona que te dé acceso completo durante la instalación. Si `make install` falla al firmar dentro del sandbox, corrélo afuera.

La persona puede no saber programar. Hablale en su idioma, de a un paso por vez, y avisale **antes** de cada momento en que tiene que hacer algo ella. Hay cuatro que solo puede hacer ella: la contraseña del llavero, los permisos, el ajuste de la tecla fn y la cuenta de Groq. Nunca muestres su clave de API.

1. **Revisá la Mac:** `uname -m` tiene que dar `arm64` (Apple Silicon) y `sw_vers` macOS 13.3 o más. `xcode-select -p` tiene que existir; si no, ejecutá `xcode-select --install`, pedile que pulse **Instalar** en la ventana que aparece, y seguí cuando `xcode-select -p` funcione.
2. **Bajá el proyecto** (por ejemplo, `git clone https://github.com/virumiranda/murmur ~/Projects/murmur`) y trabajá desde esa carpeta.
3. **Modelo local:** `make model` baja ≈1,8 GB. Si tu entorno lo permite, corrélo en segundo plano y seguí con lo demás; si no, avisale que tarda unos minutos.
4. **Firma local:** `bash scripts/create-signing-cert.sh`. Después, **antes** de compilar, avisale: *"Te va a aparecer una ventana que dice que codesign quiere usar la clave «Murmur Local Signing». Poné la contraseña de tu Mac y tocá «Permitir siempre»."* Corré `make install` (en segundo plano si podés): queda esperando hasta que ella acepte, y si no ve la ventana puede estar detrás de otras.
5. **Primera carga del modelo:** cuando terminen la descarga y la instalación, prepará el Neural Engine antes de abrir la app, para que su primer dictado no tarde 2–3 minutos: `say -v Paulina -o /tmp/murmur-prueba.aiff "hola, esto es una prueba"` y después `~/Applications/Murmur.app/Contents/MacOS/Murmur --transcribe /tmp/murmur-prueba.aiff --raw`.
6. **Abrí la app** (`open ~/Applications/Murmur.app`): se abre su ventana. Explicale los permisos que va a pedir: **Micrófono** (tocar Permitir), **Monitorización de entrada** y **Accesibilidad** (abrir Ajustes del Sistema y encender el interruptor de Murmur). Murmur los detecta solo en unos segundos. Si quiere tenerla a mano, que la arrastre al Dock (o al escritorio con Cmd + Opción).
7. **Tecla fn:** abrí `open "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"` y pedile que ponga **"Pulsar la tecla 🌐 para" → "No hacer nada"**. Si usa Wispr Flow u otra app de dictado con fn, que la cierre.
8. **Clave de Groq** (gratis, es lo que la hace rápida): abrí `open https://console.groq.com/keys`. Que entre con Google, toque **Create API Key** y la copie. Si la página dice "Access denied", tiene una VPN prendida: que la apague para registrarse. Cuando te diga que la copió, guardala vos desde el portapapeles sin mostrarla (`pbpaste`, comprobá que empiece con `gsk_`) en la línea `GROQ_API_KEY=` de `~/.config/murmur/.env`. Verificala con `curl` contra `https://api.groq.com/openai/v1/models` (tiene que dar 200). Usá curl: Groq rechaza el user-agent por defecto de Python.
9. **Si usa VPN:** con la VPN prendida, Groq responde 403. Explicale la opción `"bypassVPN": true` en `~/.config/murmur/config.json`: solo los pedidos de Murmur a Groq salen sin VPN y Groq ve su IP real. Activala solo si está de acuerdo.
10. **Probá:** que abra Notas, mantenga **fn**, diga algo y suelte. El dictado aparece también en **Inicio**, en la ventana de Murmur. Sugerile activar **Abrir al iniciar sesión** en el menú del micrófono (al iniciar sesión arranca sin abrir la ventana).

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
.build/release/Murmur --transform 1 "texto"   # probar un Transform (1 = Pulir)
.build/release/Murmur --summarize t.txt   # probar el resumen de una reunión
swift scripts/make-icon.swift "$PWD"      # regenerar Resources/Murmur.icns
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
| `Pill.swift` | El globito flotante: barritas al grabar, puntitos al transcribir, botones ✕ y ■ en manos libres. |
| `AppDelegate.swift` | Menú de la barra, permisos, abrir al iniciar sesión, recarga de ajustes; conecta todo lo de abajo. |
| `Config.swift` | Ajustes (`~/.config/murmur/config.json`) y claves (`~/.config/murmur/.env`). |
| `LLM.swift` | Un pedido al modelo de la limpieza; lo usan la limpieza, Transforms y los resúmenes. |
| `Storage.swift` | Archivos JSON privados (0600) en `~/.config/murmur`, escritos en segundo plano. |
| `History.swift` | Historial de dictados (`history.json`), solo texto. |
| `Personalization.swift` | Diccionario, estilo por tipo de app y lista de Transforms (`personalization.json`); `Style` y `AppContext`. |
| `WordLearner.swift` | Aprende nombres corregidos: sigue el cuadro de texto por Accesibilidad un minuto después de pegar y compara. |
| `Transforms.swift` | Atajos globales ⌃⌥1…9 (Carbon), tomar la selección, reescribir con la IA y pegar. |
| `Notes.swift` | Bloc de notas y reuniones guardadas (`notes.json`). |
| `Meeting.swift` / `SystemAudio.swift` | Tomador de notas: micrófono + audio del sistema (Core Audio tap, macOS 14.2+), transcripción por partes y resumen. |
| `Window/` | La ventana (SwiftUI): `MainWindow.swift` (ventana, menú de la app, piezas comunes) y una vista por sección. |

## Cosas a tener en cuenta

- **Permisos y firma.** macOS ata los permisos de Accesibilidad y Monitorización de entrada a la firma de la app. `scripts/create-signing-cert.sh` crea una firma local estable que `make` usa sola; sin ella, cada compilación pierde los permisos (`tccutil reset Accessibility local.murmur`).
- **No usar `Process.waitUntilExit()`.** En la app puede quedarse esperando para siempre si el proceso se lanzó desde un hilo de Swift concurrency. `DirectRoute` lee hasta el fin de los pipes.
- **Groq gratis:** ~8.000 tokens por minuto para la limpieza, unos 5 dictados. Las instrucciones de `CleanupPrompt.swift` tienen que ser compactas. Si se pasa el límite, Murmur pega el texto sin limpiar al instante, sin esperar.
- **Probar cambios a las instrucciones** con `./scripts/eval-cleanup.sh` antes de dar por bueno un cambio: un arreglo puede romper otro caso. Para probar sin recompilar, guardá tu versión en `~/.config/murmur/cleanup-prompt.md`.
- **Privacidad.** Sin telemetría, sin cuentas. El audio nunca se guarda (solo un archivo temporal privado de milisegundos para comprimir antes de subir), tampoco el de las reuniones. El texto (historial, notas, diccionario) va solo a los JSON privados de `~/.config/murmur`, con `PrivateFile`. Nunca escribir el texto dictado en los logs; solo tiempos y tamaños.
- **Accesibilidad sobre la propia app.** No llamar a las APIs de AX contra Murmur desde el hilo principal: se cuelga. Cuando la ventana de Murmur está al frente, se usa el `NSTextView` directamente.
- **Atajos de Transforms con ⌃⌥, no solo ⌥:** en teclados en español ⌥ + número escribe @, #, | o ¡.
- **Textos de la interfaz** con `L("English", "Español")`; se muestran en español si la Mac está en español.
- **Primera carga del modelo local** con Neural Engine: ~2–3 min una sola vez por compilación nueva.
