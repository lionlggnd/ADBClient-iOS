# ADB Client per iOS

Client ADB nativo per iPhone/iPad (SwiftUI). Parla direttamente con `adbd` sul dispositivo Android tramite TCP/TLS: non serve un computer né il server adb.

## Funzioni

- **Connessione**
  - ADB TCP classico: porta 5555, dopo `adb tcpip 5555`. Autenticazione RSA con richiesta "Consenti debug" sul telefono.
  - Debug wireless (Android 11+): accoppiamento con codice a 6 cifre (TLS + SPAKE2, lo stesso protocollo di `adb pair`), poi connessione cifrata TLS.
  - Rilevamento automatico via mDNS dei servizi `_adb-tls-pairing`, `_adb-tls-connect` e `_adb`. Elenco dei dispositivi recenti.
- **App**
  - Elenco con filtri: utente, sistema, disattivate, rimosse e tutte. Ricerca per nome pacchetto.
  - Azioni: avvia, forza chiusura, attiva/disattiva, svuota dati, svuota cache (Android 14+), libera la cache di tutte le app, sospendi/riattiva, disinstalla, disinstalla per l'utente 0 (anche app di sistema), ripristina app rimossa, estrai APK.
  - Dettagli dell'app (versione, SDK, date, percorsi) e permessi runtime con concessione/revoca.
- **Installazione APK**: singolo APK o APK suddivisi (install-multiple), con opzioni `-r -d -g -t`.
- **File**
  - Browser del filesystem via protocollo sync.
  - Scarica file e cartelle, con condivisione. Carica dall'app File. Crea cartelle, rinomina, elimina. Installa un APK direttamente dal dispositivo.
- **Terminale** in stile platform-tools
  - Comandi: `adb connect/pair/devices/shell/exec-out/logcat/install/install-multiple/uninstall/push/pull/reboot/root/unroot/remount/tcpip/usb/get-state/get-serialno/features`…
  - Shell interattiva (PTY) con tasti Ctrl-C, Ctrl-D, Tab, Esc e frecce.
  - Cronologia dei comandi.
- **Impostazioni**: nome della chiave, visualizzazione e copia della chiave pubblica, rigenerazione della chiave.

I file locali usati da push, pull e install, insieme agli APK estratti, stanno nella cartella Documenti dell'app (app File > Sul mio iPhone > ADB Client).

## Struttura

```
ADBClient/
  Native/        C su BoringSSL: chiavi RSA, socket, TLS 1.3, pairing SPAKE2
  Core/          protocollo ADB (messaggi, connessione, stream, sync), installer, mDNS
  Features/      schermate SwiftUI (Dispositivo, App, File, Terminale, Impostazioni)
project.yml      progetto XcodeGen
scripts/build-boringssl.sh
.github/workflows/build-ipa.yml
```

## Build

La workflow GitHub Actions esegue questi passi:

1. compila BoringSSL per iOS arm64 (con cache);
2. genera il progetto con XcodeGen;
3. compila l'app senza firma;
4. pubblica `ADBClient-unsigned.ipa` come artifact.

L'IPA va poi firmato o installato con lo strumento che preferisci.

## Installazione

L'IPA non è firmato: scaricalo dall'ultima build di GitHub Actions e installalo con SideStore, AltStore o Sideloadly. Con un Apple ID gratuito la firma dura 7 giorni.

## Sviluppo

Il progetto è stato sviluppato con l'aiuto di un'AI (Claude, di Anthropic) ed è in versione iniziale. Le segnalazioni di bug, con modello del telefono e versione di Android, sono benvenute nelle Issue.

## Limiti noti

- iOS sospende le connessioni di rete quando l'app va in background.
- `forward`, `reverse`, `sideload`, `backup` e `bugreport` non sono supportati.
- I nomi visualizzati delle app non sono disponibili via shell: viene mostrato il nome del pacchetto.

## Licenza

Distribuito con licenza [GPL-3.0](LICENSE). Le componenti di terze parti (BoringSSL, Apache-2.0) sono elencate in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Android è un marchio di Google LLC. Questo progetto non è affiliato a Google né approvato da Google.
