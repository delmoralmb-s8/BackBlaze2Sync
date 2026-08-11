# BackBlaze2Sync

App nativa de macOS (SwiftUI) para usar Backblaze B2 sin terminal. Por debajo usa `rclone` pero el usuario nunca ve un comando.

## Por que no es solo otro Cyberduck

Cyberduck y apps parecidas dan acceso a muchos proveedores de nube, pero de forma generica. BackBlaze2Sync se enfoca solo en Backblaze B2 para ofrecer cosas que un cliente generico no tiene:

- Historial de operaciones con detalle por archivo:  nombre, tamaño, exito o falla. 
- Busqueda difusa por carpeta o en toda la raíz del bucket. 
- Galeria de fotos integrada con vista de miniaturas y visor a pantalla completa.
- Comprimir una carpeta remota a .zip sin requerir descarga a mano. 
- Verificacion de integridad automatica despues de subir un archivo.
- Links de descarga que fuerzan "Guardar archivo" en vez de abrirlo direecto en el navegador.

## Funciones principales

- Explorador de B2 tipo Finder: vista de iconos y vista de lista con arbol expandible.
- Subir, bajar, mover, copiar y borrar archivos y carpetas, con confirmacion antes de acciones destructivas.
- Arrastrar y soltar desde Finder o dentro del mismo explorador.
- Multiples conexiones B2 (varias cuentas o buckets).
- Generar links para compartir archivos, con fecha de expiracion.

## Requisitos

- macOS 14 o superior.
- Xcode.
- [rclone](https://rclone.org/) instalado con Homebrew: `brew install rclone`. La app lo detecta solo (Apple Silicon, Intel o vía PATH); si no lo encuentra, muestra el comando exacto para instalarlo al abrir.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) para generar el proyecto de Xcode.

## Como compilar

El `-destination "generic/platform=macOS"` es necesario para que el build sea universal
(Apple Silicon + Intel) — sin él, `xcodebuild` compila solo para la arquitectura de la Mac
donde corres el comando.

```bash
xcodegen generate
xcodebuild -project BackBlaze2Sync.xcodeproj -scheme BackBlaze2Sync -configuration Release \
  -destination "generic/platform=macOS" build
```

Para confirmar que el binario resultante sí es universal:

```bash
lipo -info BackBlaze2Sync.app/Contents/MacOS/BackBlaze2Sync
# debe decir: Architectures in the fat file: ... are: x86_64 arm64
```

## Estado del proyecto

Es un proyecto personal en desarrollo activo. No esta firmado para distribucion fuera de esta Mac ni pensado para la App Store.

## Capturas

_Pendiente: agregar capturas del explorador, la galeria y el historial._
