# CTKBridge - Fix firma digitale su macOS 15+

Bridge PCSC per risolvere l'errore **"CKR_FUNCTION_FAILED, rimuovere e reinserire la carta"** su InfoCamere Sign Desktop con smartcard CNS/Firma Digitale su macOS Sequoia (15+).

## Il problema

Su macOS 15+ (Sequoia), InfoCamere Sign Desktop non riesce a firmare documenti con smartcard CNS (es. NXP JCOP-4, carte Camera di Commercio). L'errore mostrato e':

> Errore Smartcard: CKR_FUNCTION_FAILED, rimuovere e reinserire la carta

### Causa root

macOS gestisce i lettori smartcard USB tramite due sistemi:

1. **CryptoTokenKit** (moderno, nativo macOS) - gestito da `usbsmartcardreaderd`
2. **PC/SC** (legacy, cross-platform) - usato da Sign Desktop

Il driver **bit4id** (`ifd-libifdvirtual.bundle`) dovrebbe fare da ponte tra i due sistemi, ma e' compilato per **macOS 10.12 (Sierra)** con Xcode 8.1 (2016-2017). Su macOS 15+ le connessioni XPC vengono invalidate immediatamente, impedendo al bridge di funzionare.

**Risultato**: CryptoTokenKit vede la carta (i certificati appaiono in Area personale), ma Sign Desktop usa PCSC e non la raggiunge.

```
Carta smartcard (NXP JCOP-4)
    |
Lettore USB fisico
    |
CryptoTokenKit (macOS)     <-- FUNZIONA
    |
Bridge bit4id (2016)       <-- ROTTO su macOS 15+
    |
PC/SC
    |
Sign Desktop               <-- non riceve la carta
```

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

CTKBridge e' un nuovo driver IFD handler che sostituisce il bridge rotto di bit4id. Usa le API moderne di CryptoTokenKit per accedere al lettore fisico e lo espone come lettore virtuale PCSC.

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

## Note

- **Code signing**: macOS potrebbe rifiutare il caricamento di driver non firmati. In tal caso, potrebbe essere necessario disabilitare temporaneamente SIP o firmare il bundle con un certificato sviluppatore.
- **Alternativa immediata**: Se il bridge non funziona, [DiKe 6](https://www.firma.infocert.it/installazione/installazione_DiKe6.php) (gratuito, di InfoCert) usa CryptoTokenKit direttamente e bypassa PCSC.
- Questo progetto non e' affiliato a InfoCamere, bit4id o InfoCert.

## Dispositivi testati

- MacBook Pro M3 - macOS 15 (Sequoia)
- Carta CNS NXP JCOP-4 (Camera di Commercio / InfoCamere)
- Lettore Generic EMV Smartcard Reader (Alcor Micro AU9540)

## Licenza

MIT
