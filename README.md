# BlackBlaze2Sync

App nativa de macOS (SwiftUI) para usar Backblaze B2 sin terminal. Por debajo usa `rclone`, pero el usuario nunca ve un comando.

## Por que no es solo otro Cyberduck

Cyberduck y apps parecidas dan acceso a muchos proveedores de nube, pero de forma generica. BlackBlaze2Sync se enfoca solo en Backblaze B2 y por eso puede ofrecer cosas que un cliente generico no tiene:

- Historial de operaciones con detalle por archivo (nombre, tamano, exito o falla), no solo un log de texto.
- Busqueda difusa en todo el bucket, no solo en la carpeta abierta.
- Galeria de fotos integrada, con vista de miniaturas y visor a pantalla completa.
- Comprimir una carpeta remota a .zip sin descargar nada a mano.
- Verificacion de integridad automatica despues de subir un archivo.
- Links de descarga que fuerzan "Guardar archivo" en vez de abrirlo en el navegador.

## Funciones principales

- Explorador de B2 tipo Finder: vista de iconos y vista de lista con arbol expandible.
- Subir, bajar, mover, copiar y borrar archivos y carpetas, con confirmacion antes de acciones destructivas.
- Arrastrar y soltar desde Finder o dentro del mismo explorador.
- Multiples conexiones B2 (varias cuentas o buckets).
- Generar links para compartir archivos, con fecha de expiracion.

## Requisitos

- macOS 14 o superior.
- Xcode.
- [rclone](https://rclone.org/) instalado con Homebrew (se espera en `/opt/homebrew/bin/rclone`).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) para generar el proyecto de Xcode.

## Como compilar

```bash
xcodegen generate
xcodebuild -project BlackBlaze2Sync.xcodeproj -scheme BlackBlaze2Sync -configuration Release build
```

## Estado del proyecto

Es un proyecto personal en desarrollo activo. No esta firmado para distribucion fuera de esta Mac ni pensado para la App Store.

## Capturas

_Pendiente: agregar capturas del explorador, la galeria y el historial._
