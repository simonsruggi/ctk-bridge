/*
 * CTKBridge - PCSC IFD Handler that bridges CryptoTokenKit to PCSC
 *
 * Replaces the broken bit4id libifdvirtual driver.
 * Uses modern CryptoTokenKit APIs to access the physical smartcard reader
 * and exposes it as a virtual PCSC reader.
 */

#import <Foundation/Foundation.h>
#import <CryptoTokenKit/CryptoTokenKit.h>
#include <string.h>

// PCSC IFD Handler types
typedef unsigned long DWORD;
typedef unsigned char UCHAR;
typedef unsigned char *PUCHAR;
typedef DWORD *PDWORD;
typedef char *LPSTR;
typedef long RESPONSECODE;

typedef struct {
    DWORD Protocol;
    DWORD Length;
} SCARD_IO_HEADER, *PSCARD_IO_HEADER;

// Return codes
#define IFD_SUCCESS                 0
#define IFD_ERROR_TAG               600
#define IFD_ERROR_SET_FAILURE       601
#define IFD_ERROR_VALUE_READ_ONLY   602
#define IFD_ERROR_PTS_FAILURE       605
#define IFD_NOT_SUPPORTED           606
#define IFD_COMMUNICATION_ERROR     612
#define IFD_RESPONSE_TIMEOUT        613
#define IFD_ICC_PRESENT             615
#define IFD_ICC_NOT_PRESENT         616
#define IFD_ERROR_POWER_ACTION      620
#define IFD_ERROR_INSUFFICIENT_BUFFER 624

// Tags
#define TAG_IFD_ATR                     0x0303
#define TAG_IFD_SIMULTANEOUS_ACCESS     0x0FAF
#define TAG_IFD_SLOT_THREAD_SAFE        0x0FAC
#define TAG_IFD_SLOTS_NUMBER            0x0FAE
#define SCARD_ATTR_VENDOR_NAME          0x00010100
#define SCARD_ATTR_VENDOR_IFD_VERSION   0x00010102

// Power actions
#define IFD_POWER_UP    500
#define IFD_POWER_DOWN  501
#define IFD_RESET       502

// Global state
static TKSmartCard *g_smartCard = nil;
static TKSmartCardSlot *g_slot = nil;
static NSData *g_atr = nil;
static BOOL g_sessionActive = NO;

#pragma mark - Helper Functions

static void logMsg(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[CTKBridge] %@", msg);
}

static TKSmartCardSlot *findPhysicalReader(void) {
    TKSmartCardSlotManager *manager = [TKSmartCardSlotManager defaultManager];
    if (!manager) {
        logMsg(@"TKSmartCardSlotManager not available");
        return nil;
    }

    NSArray *slotNames = [manager slotNames];
    logMsg(@"Available slots: %@", slotNames);

    // Find a physical reader (not virtual)
    NSString *targetSlot = nil;
    for (NSString *name in slotNames) {
        if ([name rangeOfString:@"vreader" options:NSCaseInsensitiveSearch].location == NSNotFound &&
            [name rangeOfString:@"virtual" options:NSCaseInsensitiveSearch].location == NSNotFound) {
            targetSlot = name;
            break;
        }
    }

    if (!targetSlot) {
        logMsg(@"No physical reader found");
        return nil;
    }

    logMsg(@"Using reader: %@", targetSlot);

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block TKSmartCardSlot *foundSlot = nil;

    [manager getSlotWithName:targetSlot reply:^(TKSmartCardSlot *slot) {
        foundSlot = slot;
        dispatch_semaphore_signal(sem);
    }];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    return foundSlot;
}

static BOOL ensureSession(void) {
    if (g_sessionActive && g_smartCard) return YES;

    @autoreleasepool {
        // Find the physical reader
        TKSmartCardSlot *slot = findPhysicalReader();
        if (!slot) return NO;

        g_slot = slot;

        if (slot.state != TKSmartCardSlotStateValidCard) {
            logMsg(@"No valid card in slot (state=%ld)", (long)slot.state);
            return NO;
        }

        // Get ATR
        g_atr = slot.ATR.bytes;
        logMsg(@"Card ATR: %@", g_atr);

        // Create smartcard object
        TKSmartCard *card = [slot makeSmartCard];
        if (!card) {
            logMsg(@"Failed to create TKSmartCard");
            return NO;
        }

        // Begin session
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block BOOL sessionOK = NO;
        __block NSError *sessionError = nil;

        [card beginSessionWithReply:^(BOOL success, NSError *error) {
            sessionOK = success;
            sessionError = error;
            dispatch_semaphore_signal(sem);
        }];

        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

        if (!sessionOK) {
            logMsg(@"Failed to begin session: %@", sessionError);
            return NO;
        }

        g_smartCard = card;
        g_sessionActive = YES;
        logMsg(@"Session established successfully");
        return YES;
    }
}

static void closeSession(void) {
    if (g_smartCard && g_sessionActive) {
        [g_smartCard endSession];
    }
    g_smartCard = nil;
    g_slot = nil;
    g_atr = nil;
    g_sessionActive = NO;
}

#pragma mark - IFD Handler Interface

RESPONSECODE IFDHCreateChannelByName(DWORD Lun, LPSTR DeviceName) {
    logMsg(@"CreateChannelByName Lun=%lu Device=%s", Lun, DeviceName ? DeviceName : "null");
    @autoreleasepool {
        if (ensureSession()) return IFD_SUCCESS;
        return IFD_COMMUNICATION_ERROR;
    }
}

RESPONSECODE IFDHCreateChannel(DWORD Lun, DWORD Channel) {
    logMsg(@"CreateChannel Lun=%lu Channel=%lu", Lun, Channel);
    @autoreleasepool {
        if (ensureSession()) return IFD_SUCCESS;
        return IFD_COMMUNICATION_ERROR;
    }
}

RESPONSECODE IFDHCloseChannel(DWORD Lun) {
    logMsg(@"CloseChannel Lun=%lu", Lun);
    @autoreleasepool {
        closeSession();
    }
    return IFD_SUCCESS;
}

RESPONSECODE IFDHGetCapabilities(DWORD Lun, DWORD Tag, PDWORD Length, PUCHAR Value) {
    @autoreleasepool {
        switch (Tag) {
            case TAG_IFD_ATR:
                if (g_atr && g_sessionActive) {
                    DWORD atrLen = (DWORD)[g_atr length];
                    if (atrLen > *Length) return IFD_ERROR_INSUFFICIENT_BUFFER;
                    *Length = atrLen;
                    memcpy(Value, [g_atr bytes], atrLen);
                    return IFD_SUCCESS;
                }
                // Try to connect
                if (ensureSession() && g_atr) {
                    DWORD atrLen = (DWORD)[g_atr length];
                    if (atrLen > *Length) return IFD_ERROR_INSUFFICIENT_BUFFER;
                    *Length = atrLen;
                    memcpy(Value, [g_atr bytes], atrLen);
                    return IFD_SUCCESS;
                }
                return IFD_ICC_NOT_PRESENT;

            case TAG_IFD_SIMULTANEOUS_ACCESS:
                *Length = 1;
                *Value = 1;
                return IFD_SUCCESS;

            case TAG_IFD_SLOTS_NUMBER:
                *Length = 1;
                *Value = 1;
                return IFD_SUCCESS;

            case TAG_IFD_SLOT_THREAD_SAFE:
                *Length = 1;
                *Value = 0;
                return IFD_SUCCESS;

            case SCARD_ATTR_VENDOR_NAME: {
                const char *vendor = "CTKBridge";
                DWORD len = (DWORD)strlen(vendor);
                if (len > *Length) return IFD_ERROR_INSUFFICIENT_BUFFER;
                *Length = len;
                memcpy(Value, vendor, len);
                return IFD_SUCCESS;
            }

            default:
                return IFD_ERROR_TAG;
        }
    }
}

RESPONSECODE IFDHSetCapabilities(DWORD Lun, DWORD Tag, DWORD Length, PUCHAR Value) {
    return IFD_NOT_SUPPORTED;
}

RESPONSECODE IFDHSetProtocolParameters(DWORD Lun, DWORD Protocol, UCHAR Flags,
                                        UCHAR PTS1, UCHAR PTS2, UCHAR PTS3) {
    logMsg(@"SetProtocolParameters Protocol=%lu", Protocol);
    return IFD_SUCCESS;
}

RESPONSECODE IFDHPowerICC(DWORD Lun, DWORD Action, PUCHAR Atr, PDWORD AtrLength) {
    logMsg(@"PowerICC Action=%lu", Action);
    @autoreleasepool {
        switch (Action) {
            case IFD_POWER_UP:
            case IFD_RESET:
                // Reconnect
                closeSession();
                if (!ensureSession()) return IFD_ERROR_POWER_ACTION;
                if (g_atr) {
                    *AtrLength = (DWORD)[g_atr length];
                    memcpy(Atr, [g_atr bytes], [g_atr length]);
                }
                return IFD_SUCCESS;

            case IFD_POWER_DOWN:
                closeSession();
                return IFD_SUCCESS;

            default:
                return IFD_NOT_SUPPORTED;
        }
    }
}

RESPONSECODE IFDHTransmitToICC(DWORD Lun, SCARD_IO_HEADER SendPci,
                                PUCHAR TxBuffer, DWORD TxLength,
                                PUCHAR RxBuffer, PDWORD RxLength,
                                PSCARD_IO_HEADER RecvPci) {
    @autoreleasepool {
        if (!g_smartCard || !g_sessionActive) {
            if (!ensureSession()) return IFD_COMMUNICATION_ERROR;
        }

        NSData *command = [NSData dataWithBytes:TxBuffer length:TxLength];

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block NSData *response = nil;
        __block NSError *txError = nil;

        [g_smartCard transmitRequest:command reply:^(NSData *replyData, NSError *error) {
            response = replyData;
            txError = error;
            dispatch_semaphore_signal(sem);
        }];

        // 30 second timeout for signing operations
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));

        if (txError || !response) {
            logMsg(@"Transmit error: %@", txError);
            // Try to reconnect for next call
            closeSession();
            return IFD_COMMUNICATION_ERROR;
        }

        DWORD respLen = (DWORD)[response length];
        if (respLen > *RxLength) {
            logMsg(@"Response too large: %lu > %lu", respLen, *RxLength);
            return IFD_ERROR_INSUFFICIENT_BUFFER;
        }

        *RxLength = respLen;
        memcpy(RxBuffer, [response bytes], respLen);

        if (RecvPci) {
            RecvPci->Protocol = SendPci.Protocol;
            RecvPci->Length = sizeof(SCARD_IO_HEADER);
        }

        return IFD_SUCCESS;
    }
}

RESPONSECODE IFDHControl(DWORD Lun, DWORD dwControlCode,
                          PUCHAR TxBuffer, DWORD TxLength,
                          PUCHAR RxBuffer, PDWORD RxLength) {
    return IFD_NOT_SUPPORTED;
}

RESPONSECODE IFDHICCPresence(DWORD Lun) {
    @autoreleasepool {
        // Quick check without full reconnect
        if (g_slot) {
            TKSmartCardSlotState state = g_slot.state;
            if (state == TKSmartCardSlotStateValidCard) {
                return IFD_ICC_PRESENT;
            }
        }

        // Try to find the reader
        TKSmartCardSlot *slot = findPhysicalReader();
        if (slot && slot.state == TKSmartCardSlotStateValidCard) {
            g_slot = slot;
            return IFD_ICC_PRESENT;
        }

        return IFD_ICC_NOT_PRESENT;
    }
}
