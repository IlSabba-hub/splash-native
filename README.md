# Splash Deck

App macOS nativa (SwiftUI, app + barra dei menu) per gestire [Splash](https://github.com/incoai/splash): modelli, configurazioni, caricamento con stima della memoria, server su una porta sola, chat, statistiche.

## Requisiti
- macOS 26.4 o successivo, Apple Silicon
- Swift 6.2 (Xcode 26)
- Splash installato: `brew install incoai/tap/splash`

## Compilare e avviare
```sh
swift build -c release
.build/release/SplashDeck
```

## Test
```sh
swift test
```
I test leggono le schede dei modelli in `Tests/Fixtures/hub/readme` (vedi `NOTICE.md` lì dentro).

## Struttura
- `Sources/DeckCore`: dati, lettura di Splash, stime di memoria, processi
- `Sources/DeckUI`: interfaccia e design system (italiano e inglese)
- `Sources/SplashDeck`: l'app e gli adattatori fra i due

## Contributi
Il codice è pubblicato da leggere, scaricare e riusare: pull request e issue non sono accettate.

## Licenze
Il codice è sotto licenza MIT (`LICENSE`). I file in `Sources/DeckCore/Upstream` vengono da Splash (Apache 2.0, vedi `LICENSE-SPLASH`); in questa copia sono modificati: commenti rimossi.
