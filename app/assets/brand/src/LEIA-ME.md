# Ícone e splash do app Hexapod

| Arquivo | Uso |
|---|---|
| `app_icon_1024.png` | Ícone completo (Android legado, iOS, Play Store) |
| `adaptive_foreground_1024.png` | Ícone adaptativo do Android: camada da frente (fundo transparente, dentro da zona segura) |
| `adaptive_background_1024.png` | Ícone adaptativo: camada de fundo (ou use a cor `#0c1428`) |
| `splash_android12_1152.png` | Splash do Android 12+ (ícone central; área visível = círculo de 768 px) |
| `splash_logo.png` | Splash do Android < 12 (robô + nome, fundo transparente) |
| `splash_preview_1080x2340.png` | Só prévia, para ver como fica no celular |
| `*.svg` | Originais vetoriais, para editar cores e textos |

## Como usar no Flutter

Copie os PNG para `app/assets/brand/` e adicione no `pubspec.yaml`:

```yaml
dev_dependencies:
  flutter_launcher_icons: ^0.14.0
  flutter_native_splash: ^2.4.0

flutter_launcher_icons:
  android: true
  ios: true
  image_path: "assets/brand/app_icon_1024.png"
  adaptive_icon_foreground: "assets/brand/adaptive_foreground_1024.png"
  adaptive_icon_background: "assets/brand/adaptive_background_1024.png"

flutter_native_splash:
  color: "#0c1428"
  image: "assets/brand/splash_logo.png"
  android_12:
    color: "#0c1428"
    image: "assets/brand/splash_android12_1152.png"
```

Depois rode:

```
dart run flutter_launcher_icons
dart run flutter_native_splash:create
```

Confira as versões mais recentes dos dois pacotes no pub.dev antes de fixar.
