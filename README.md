# Murmur

Dictado por voz para Mac (macOS con chip Apple; si usás Windows, mirá [Windows](#windows)). Mantenés **fn**, hablás, soltás, y el texto aparece donde estás escribiendo: WhatsApp, mail, Notion, Claude Code, lo que sea. Gratis y de código abierto. Pensado para español; también funciona en inglés y en más de 90 idiomas.

## Qué hace

- **Mantener fn** graba mientras hablás. Al soltar, transcribe y pega.
- **Doble toque en fn** activa manos libres: graba sin mantener nada. Otro toque termina. A los 5 minutos corta solo.
- **Esc** cancela la grabación, o una transcripción en curso.
- **Limpieza inteligente:** saca muletillas ("eh", "o sea", "tipo") y aplica tus autocorrecciones: "el viernes, no, perdón, el lunes" queda "el lunes", y "retiro lo dicho" borra lo anterior. También arma listas numeradas cuando enumerás, da formato a los mails, escribe bien los mails y las webs dictados ("juan arroba gmail punto com") y pasa horas y montos a números.
- **Rápido:** ~0,5 s en frases simples y ~1,2–1,5 s cuando hay algo que limpiar (con Groq, en una Mac M1).
- **Sin internet** también funciona, con un modelo local (un poco más lento).
- Sin cuentas, sin suscripción, sin telemetría.

Y tiene una ventana, como Wispr Flow (se abre con doble clic en la app o desde el menú → **Abrir Murmur**):

- **Inicio:** todos tus dictados, por día, con buscador y botón para copiarlos de nuevo.
- **Diccionario:** nombres y palabras que tiene que escribir exacto, y reemplazos ("mi mail" → tu dirección). Aprende solo: si después de dictar corregís cómo se escribe un nombre, lo agrega.
- **Estilo:** cómo queda escrito según la app: formal, casual, muy casual (sin mayúsculas) o entusiasta, por separado para mensajes personales, de trabajo, mails y el resto.
- **Transforms:** seleccionás un texto en cualquier app, apretás **⌃⌥1** y la IA lo pule ahí mismo. **⌃⌥2** lo convierte en un prompt para IA, **⌃⌥3** lo traduce al inglés, y podés crear los tuyos.
- **Bloc de notas:** notas que escribís o dictás (mantené fn con la nota abierta).
- **Tomador de notas:** graba una reunión (tu micrófono y, si querés, el audio de la compu, para escuchar a los demás en Zoom o Meet), la transcribe mientras habla la gente y al final arma un resumen con puntos clave y tareas.

## Lo que necesitás

- Una Mac con Apple Silicon (M1 o posterior) y macOS 13.3 o más nuevo.
- Las herramientas de línea de comandos de Apple (gratis): en la Terminal, `xcode-select --install`.
- Una clave gratis de [Groq](https://console.groq.com). No es obligatoria, pero es lo que la hace rápida.
- Unos 2 GB libres para el modelo local.

## Instalación

### La forma fácil: con Claude Code o Codex

Si usás [Claude Code](https://claude.com/claude-code) o [Codex](https://openai.com/codex), pegale esto:

> Instalá Murmur desde https://github.com/virumiranda/murmur: clonalo en ~/Projects/murmur, leé su AGENTS.md y seguí la "Instalación guiada" conmigo, paso a paso.

El agente hace todo y te avisa cuando te toca a vos. Son cuatro momentos: poner la contraseña de tu Mac una vez, activar los permisos, cambiar el ajuste de la tecla fn y crear tu clave gratis de Groq. Con Codex, además, aprobá los comandos que te pida correr fuera de su sandbox: instalar necesita internet y escribir fuera de la carpeta del proyecto.

### A mano

Si preferís hacerlo vos, seguí estos pasos.

### 1. Descargar

En GitHub, botón verde **Code → Download ZIP**, y descomprimilo (por ejemplo en `Documentos`). O con git: `git clone` + la dirección del repositorio.

### 2. Compilar e instalar

Abrí la **Terminal**, escribí `cd ` (con un espacio), arrastrá la carpeta de Murmur a la ventana y apretá Enter. Después:

```sh
bash scripts/create-signing-cert.sh # una sola vez: una firma local para que los permisos no se pierdan
make model                         # descarga el modelo local (≈1,8 GB)
make run                           # compila, instala en Aplicaciones y abre Murmur
```

Cuando aparezca una ventana del llavero preguntando por **codesign**, poné la contraseña de tu Mac y elegí **Permitir siempre**.

### 3. Permisos

macOS te los pide la primera vez. También están en **Ajustes del Sistema → Privacidad y seguridad**:

| Permiso | Para qué |
|---|---|
| **Micrófono** | Grabarte mientras dictás. |
| **Monitorización de entrada** | Ver cuándo apretás fn y Esc. Solo mira: tus teclas siguen llegando a la app donde escribís. |
| **Accesibilidad** | Pegar el texto donde está el cursor. |

Cuando los activás, Murmur los detecta solo en un par de segundos.

### 4. La tecla fn

En **Ajustes del Sistema → Teclado**, poné **"Pulsar la tecla 🌐 para"** en **No hacer nada**. Si no, fn abre los emojis o el dictado de Apple. Si usás otra app de dictado con fn (Wispr Flow, Superwhisper…), cerrala.

### 5. Clave de Groq (recomendado)

1. Entrá a [console.groq.com](https://console.groq.com) con tu cuenta de Google. Es gratis. Si tenés una VPN prendida, apagala para entrar: Groq bloquea las VPN.
2. **API Keys → Create API Key**, y copiá la clave (empieza con `gsk_`).
3. En el menú de Murmur (el micrófono de arriba), elegí **Editar claves de API (.env)**, pegá la clave justo después de `GROQ_API_KEY=` y guardá con Cmd + S.

No hace falta reiniciar nada. Sin clave, Murmur usa el modelo local: sin internet, en ~1,5 s.

### 6. Que arranque sola

En el menú de Murmur, activá **Abrir al iniciar sesión**.

> La primera vez que Murmur usa el modelo local, macOS lo prepara para el Neural Engine. Tarda 2–3 minutos, una sola vez.

## Cómo se usa

| Hacés | Pasa |
|---|---|
| **Mantenés** fn y hablás | Graba. Al soltar, transcribe y pega. |
| **Doble toque** en fn | Manos libres: graba sin mantener nada. |
| **Otro toque** | Termina el manos libres y transcribe. |
| **Esc** | Cancela la grabación o la transcripción en curso. Esc también le llega a tu app. |
| fn + otra tecla | Es un atajo (fn+←, fn+borrar), no un dictado: no se transcribe. |

El globito negro de abajo muestra las barritas de tu voz mientras grabás y unos puntitos mientras transcribe. En manos libres tiene dos botones: **✕** cancela y **■** termina y pega. Cuando faltan 30 segundos para el corte, avisa.

El texto queda también en el portapapeles y en **Inicio**, en la ventana de Murmur, para copiarlo cuando quieras. Si dictás con una nota del **Bloc de notas** abierta, el texto va a la nota.

### Transforms

| Atajo | Hace |
|---|---|
| **⌃⌥1** | Pulir: más claro y conciso, sin cambiar lo que dice ni el tono. |
| **⌃⌥2** | Prompt para IA: convierte ideas sueltas en un prompt ordenado. |
| **⌃⌥3** | Traducir al inglés. |

Seleccioná el texto y apretá el atajo (⌃ es Control, ⌥ es Opción). Cmd + Z lo deshace. En **Transforms** podés cambiar las instrucciones, los atajos (⌃⌥1 a ⌃⌥9) o crear los tuyos. Usa la misma IA que la limpieza, así que necesita la clave de Groq.

### Tomador de notas

En la ventana de Murmur, **Tomador de notas → Empezar a grabar** (o en el menú: **Grabar una reunión**). Con **Incluir el audio de la compu**, también graba lo que suena en la Mac, así se escucha a los demás aunque uses auriculares; la primera vez macOS pide permiso para grabar el audio del sistema (necesita macOS 14.2 o más nuevo). La transcripción aparece cada medio minuto. Al terminar, el resumen tarda unos segundos (en reuniones largas, unos minutos por el límite gratis de Groq). Sin clave de IA, guarda la transcripción sin resumen.

En dictados largos, Murmur va transcribiendo mientras hablás (cada ~20 segundos, cortando en una pausa). Al soltar solo falta el último pedazo: hablar más no te hace esperar más.

## Velocidad

Medido en una Mac M1. Es lo que esperás desde que soltás fn:

| Configuración | Frase simple | Con limpieza (muletillas, listas…) | Dictado de casi 1 minuto |
|---|---|---|---|
| Groq | ~0,5 s | ~1,2–1,5 s | ~1,5 s |
| Modelo local, idioma automático | ~1,3–1,6 s | sin limpieza | ~1,6 s |
| Modelo local, idioma fijo (`"es"`) | ~0,7–1 s | sin limpieza | ~1 s |

## Límites

Murmur no tiene límites. Los únicos son los del plan gratis de Groq:

- **Transcripción:** 2.000 por día.
- **Limpieza:** 1.000 por día y unas 5 por minuto. Solo se usa cuando hace falta: las frases que ya vienen bien se pegan directo.

Si llegás a un límite, Murmur no se frena. Pega el texto sin limpiar, o transcribe con el modelo local hasta que se renueva el cupo. El plan pago de Groq quita los límites.

## VPN

Groq bloquea las conexiones que vienen de una VPN. Si usás una, poné `"bypassVPN": true` en los ajustes. Así solo los pedidos de Murmur a Groq salen por tu conexión normal, y el resto de tu Mac sigue dentro de la VPN. A cambio, Groq ve tu IP real en esos pedidos. Viene apagado.

## Ajustes

Todo está en `~/.config/murmur/config.json` (menú → **Abrir archivo de ajustes**). Los cambios se aplican al guardar.

| Ajuste | Qué hace |
|---|---|
| `hotkey` | La tecla: `fn` (por defecto), `rightoption`, `rightcommand`, o una combinación como `ctrl+option+space` o `f13`. |
| `transcription.language` | `auto`, o un idioma fijo como `es` o `en`. Fijo es más rápido con el modelo local. |
| `transcription.provider` | `auto` (Groq si hay clave; si no, local), `groq`, `openai` o `local`. |
| `vocabulary` | Nombres y palabras que tiene que escribir bien, por ejemplo `["Claude Code", "Mar del Plata"]`. |
| `cleanup.enabled` | Prende o apaga la limpieza. |
| `cleanup.casing` | `sentence` (normal) o `lowercase` (todo en minúscula, estilo chat). |
| `cleanup.skipWhenClean` | Salta la limpieza cuando el texto ya viene bien (más rápido). |
| `cleanup.provider` / `cleanup.model` | Qué LLM limpia: `auto`, `groq`, `openai`, `anthropic`, `ollama` (local) o `custom`. |
| `insertion.restoreClipboard` | `true` devuelve tu portapapeles anterior después de pegar. |
| `insertion.trailingSpace` | Agrega un espacio al final, para que los dictados seguidos no se peguen. |
| `bypassVPN` | Ver [VPN](#vpn). |
| `maxRecordingSeconds` | Corte automático (300 = 5 minutos). |
| `saveHistory` | `false` deja de guardar los dictados en **Inicio**. |

Las claves van en `~/.config/murmur/.env`: `GROQ_API_KEY`, `OPENAI_API_KEY` y `ANTHROPIC_API_KEY`.

## Personalizalo con Claude Code o Codex

Este proyecto está pensado para que lo modifiques a tu gusto.

- Abrí la carpeta con **Claude Code** o **Codex**. El archivo `AGENTS.md` les explica cómo está armado todo, así que podés pedirles cambios directamente: "agregá un sonido al terminar", "que la tecla sea option derecha".
- Las instrucciones de la limpieza están en `Sources/Murmur/CleanupPrompt.swift`. Para probar cambios sin compilar, guardá tu versión en `~/.config/murmur/cleanup-prompt.md`.
- Medí si un cambio mejora o empeora: `bash scripts/eval-cleanup.sh` pasa los 27 casos de `evals/cleanup-cases.txt` por la limpieza. Agregá los tuyos.
- Para probar sin hablar: `.build/release/Murmur --clean "eh, nos vemos el lunes, no, el martes"`, o `--transcribe audio.m4a`, o `--check`. Para los Transforms, `--transform 1 "texto"`; para los resúmenes de reuniones, `--summarize transcripcion.txt`.

## Privacidad

- Sin cuentas ni telemetría.
- El audio queda en memoria. Si usás Groq, se sube comprimido y no se guarda en ningún lado: solo pasa unos milisegundos por un archivo temporal privado. Con el modelo local, nada sale de tu Mac. Lo mismo con las reuniones: se guarda el texto, nunca el audio.
- El texto de tus dictados, notas, reuniones y diccionario se guarda solo en tu Mac, en `~/.config/murmur` (`history.json`, `notes.json`, `personalization.json`), en archivos que solo vos podés leer. Para no guardar los dictados, poné `"saveHistory": false`; desde **Inicio** podés borrar el historial.
- Para aprender palabras, Murmur lee el cuadro de texto donde pegó durante un minuto, en tu Mac. No guarda ni envía ese texto: solo agrega la palabra corregida. Se apaga en **Diccionario**.
- Los Transforms mandan el texto seleccionado a la misma IA que la limpieza (Groq, si usás su clave).
- Los registros nunca incluyen lo que dictaste.
- Tus claves viven en `~/.config/murmur/.env`, fuera de esta carpeta: no se suben si compartís el proyecto.

## Problemas comunes

- **El icono muestra ⚠︎:** faltan permisos. El menú tiene accesos directos para darlos.
- **Graba pero no pega:** falta el permiso de Accesibilidad. El texto igual queda en el portapapeles.
- **fn abre los emojis:** ver [La tecla fn](#4-la-tecla-fn).
- **Salen dos textos por dictado:** otra app de dictado está usando fn.
- **Groq dice "Access denied":** tenés una VPN prendida; ver [VPN](#vpn).
- **Se queda en "Transcribiendo…":** Esc lo cancela, y a los 2 minutos se cancela solo.
- **Escribe mal un nombre:** agregalo a `vocabulary`.
- **Después de recompilar no funciona la tecla:** si no creaste la firma local, macOS invalida los permisos en cada compilación. Ejecutá `tccutil reset Accessibility local.murmur` y `tccutil reset ListenEvent local.murmur`, y dalos de nuevo.
- **Ver qué está pasando:** abrí la app Consola y filtrá por `local.murmur`.
- **Un Transform no hace nada:** fijate que haya texto seleccionado y que Murmur tenga el permiso de Accesibilidad. Si otra app usa el mismo atajo, cambialo en **Transforms**.
- **El tomador de notas no escucha a los demás:** revisá en **Ajustes del Sistema → Privacidad y seguridad → Grabación de pantalla y audio del sistema** que Murmur tenga permiso para el audio del sistema.

## Windows

Murmur es solo para Mac: usa partes de macOS (el teclado, el micrófono, el Neural Engine) que no existen en Windows. Si usás Windows, estas alternativas hacen lo mismo:

- **El dictado de Windows:** apretá **Win + H** en cualquier lugar donde se pueda escribir. Viene incluido, es gratis y entiende español.
- **[Handy](https://github.com/cjpais/Handy):** gratis y de código abierto. Atajo de teclado, hablás, y pega el texto. Funciona sin internet.
- **[Whispering](https://github.com/EpicenterHQ/epicenter):** de código abierto. Puede usar Groq (con tu propia clave, como Murmur) o modelos locales.

¿Querés llevar Murmur a Windows con un agente de código? Se puede reutilizar casi todo lo que no es de macOS: las instrucciones de limpieza (`CleanupPrompt.swift`), los pedidos a Groq, la lógica de mantener / doble toque / Esc y las pruebas de `evals/`. Habría que rehacer la parte del sistema: escuchar el teclado (un hook de teclado de Windows), grabar el micrófono, pegar con Ctrl+V, el globito y el icono de la bandeja. Es un proyecto aparte, no un ajuste.

## Desinstalar

```sh
pkill -x Murmur; rm -rf ~/Applications/Murmur.app ~/.config/murmur
tccutil reset All local.murmur
```

Antes, apagá **Abrir al iniciar sesión** desde el menú.

## Créditos

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT), para la transcripción local.
- Los modelos [Whisper](https://github.com/openai/whisper) de OpenAI (MIT).
- [Groq](https://groq.com), para la transcripción y la limpieza en la nube.

Licencia MIT: usalo, modificalo y compartilo.
