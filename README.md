# CTKBridge - Fix firma digitale su macOS 15+

Bridge PCSC per risolvere l'errore **"CKR_FUNCTION_FAILED, rimuovere e reinserire la carta"** su InfoCamere Sign Desktop con smartcard CNS/Firma Digitale su macOS Sequoia (15+).

## Il problema

Quando firmi un PDF con **InfoCamere Sign Desktop** su macOS 15 (Sequoia), esce:

> Errore Smartcard: CKR_FUNCTION_FAILED, rimuovere e reinserire la carta

La carta funziona, il lettore funziona, i certificati si vedono in Area personale. Ma la firma fallisce.

### Perche' succede

macOS ha **due sistemi** per parlare con le smartcard:

- **CryptoTokenKit** — il sistema moderno di Apple. Quando inserisci il lettore USB, macOS lo "cattura" con `usbsmartcardreaderd` e lo rende disponibile solo tramite CryptoTokenKit.
- **PC/SC** — il sistema legacy, standard cross-platform. E' quello che Sign Desktop usa internamente per comunicare con la carta.

Il problema e' che **Sign Desktop usa PC/SC, ma macOS espone il lettore solo tramite CryptoTokenKit**. I due sistemi non si parlano.

Per risolvere questo, bit4id (il fornitore del driver) installa un **bridge**: un lettore virtuale (`ifd-libifdvirtual.bundle`) che dovrebbe prendere la carta dal lettore fisico (via CryptoTokenKit) e presentarla a PC/SC come se fosse un lettore locale.

**Ma questo bridge e' compilato per macOS 10.12 (Sierra), del 2016.** Le API XPC di comunicazione inter-processo sono cambiate radicalmente da allora. Su macOS 15 la connessione viene aperta e immediatamente chiusa, in loop ogni 3 secondi. Il lettore virtuale resta vuoto, Sign Desktop non vede la carta, e la firma fallisce.

```
Carta NXP JCOP-4
    |
Lettore USB fisico
    |
CryptoTokenKit (macOS)      ✅ funziona
    |
Bridge bit4id (2016)         ❌ rotto su macOS 15+
    |
PC/SC
    |
Sign Desktop                 ❌ non riceve la carta
```

InfoCamere distribuisce ancora questo driver obsoleto nella versione piu' recente di Sign Desktop.

## Diagnosi

### 1. Verificare che la carta sia vista da CryptoTokenKit

```bash
system_profiler SPSmartCardsDataType
```

Dovresti vedere il tuo lettore fisico (es. "Generic EMV Smartcard Reader") con i certificati. Se non lo vedi, il problema e' hardware (lettore/carta).

### 2. Verificare che PCSC NON veda la carta

```bash
# Installa opensc se non presente
brew install opensc

# Testa PCSC
pkcs11-tool --module /opt/homebrew/lib/opensc-pkcs11.so --list-slots
```

Se vedi solo `bit4id ddna-vreader (empty)` e NON il lettore fisico, hai confermato il bug del bridge.

### 3. Verificare il bridge rotto (opzionale)

```bash
# Controlla la versione del bridge bit4id
defaults read /usr/local/libexec/SmartCardServices/drivers/ifd-libifdvirtual.bundle/Contents/Info.plist DTSDKName
```

Se mostra `macosx10.12`, il bridge e' obsoleto.

Puoi anche verificare nei log di sistema:

```bash
log stream --debug --predicate 'process CONTAINS "ifdreader"'
```

Se vedi connessioni XPC che vengono attivate e invalidate ogni 3 secondi, il bridge e' rotto:

```
com.apple.ifdreader: [com.apple.xpc:connection] activating connection...
com.apple.ifdreader: [com.apple.xpc:connection] invalidated because the client process either cancelled the connection or exited
```

## Soluzione: CTKBridge

CTKBridge e' un nuovo driver IFD handler scritto in Objective-C che sostituisce il bridge rotto di bit4id. Usa le API moderne di CryptoTokenKit per:

1. Trovare il lettore fisico (escludendo i lettori virtuali)
2. Aprire una sessione con la smartcard
3. Esporsi come lettore virtuale PC/SC ("CryptoTokenKit Bridge Reader")
4. Inoltrare tutti i comandi APDU da PC/SC alla carta via CryptoTokenKit

```
Carta NXP JCOP-4
    |
Lettore USB fisico
    |
CryptoTokenKit (macOS)      ✅ funziona
    |
CTKBridge (nuovo)            ✅ API moderne macOS 13+
    |
PC/SC
    |
Sign Desktop                 ✅ vede la carta
```

### Requisiti

- macOS 13+ (Ventura o successivo)
- Xcode Command Line Tools (`xcode-select --install`)
- Lettore smartcard USB con carta CNS/Firma Digitale

### Compilazione

```bash
git clone https://github.com/simonsruggi/ctk-bridge.git
cd ctk-bridge
chmod +x build.sh
./build.sh
```

### Installazione

```bash
# Installa il bridge
sudo cp -r ifd-ctkbridge.bundle /usr/local/libexec/SmartCardServices/drivers/

# (Opzionale) Disabilita il bridge rotto di bit4id
sudo mv /usr/local/libexec/SmartCardServices/drivers/ifd-libifdvirtual.bundle \
        /usr/local/libexec/SmartCardServices/drivers/ifd-libifdvirtual.bundle.disabled

# Riavvia i servizi smartcard
sudo killall com.apple.ifdreader com.apple.ctkpcscd usbsmartcardreaderd 2>/dev/null
```

### Verifica

```bash
# Dopo 3-5 secondi, controlla che il bridge funzioni
pcsctest
```

Dovresti vedere **"CryptoTokenKit Bridge Reader"** con la carta presente.

### Disinstallazione

```bash
# Rimuovi CTKBridge
sudo rm -rf /usr/local/libexec/SmartCardServices/drivers/ifd-ctkbridge.bundle

# Ripristina il bridge originale bit4id (se disabilitato)
sudo mv /usr/local/libexec/SmartCardServices/drivers/ifd-libifdvirtual.bundle.disabled \
        /usr/local/libexec/SmartCardServices/drivers/ifd-libifdvirtual.bundle

# Riavvia i servizi
sudo killall com.apple.ifdreader com.apple.ctkpcscd 2>/dev/null
```

## Alternativa immediata

Se il bridge non funziona (es. per code signing), puoi usare **[DiKe 6](https://www.firma.infocert.it/installazione/installazione_DiKe6.php)** (gratuito, di InfoCert). DiKe usa CryptoTokenKit direttamente e bypassa PC/SC, quindi non ha questo problema.

## Note

- **Code signing**: macOS potrebbe rifiutare il caricamento di driver non firmati. In tal caso, potrebbe essere necessario disabilitare temporaneamente SIP o firmare il bundle con un certificato sviluppatore.
- Questo progetto non e' affiliato a InfoCamere, bit4id o InfoCert.

## Dispositivi testati

- MacBook Pro M3 - macOS 15 (Sequoia)
- Carta CNS NXP JCOP-4 (Camera di Commercio / InfoCamere)
- Lettore Generic EMV Smartcard Reader (Alcor Micro AU9540)

## Licenza

MIT
