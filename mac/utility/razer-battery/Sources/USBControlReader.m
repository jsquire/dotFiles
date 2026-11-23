#import <Foundation/Foundation.h>
#import <IOUSBHost/IOUSBHost.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "USBControlReader.h"

static void reportError(char *message, size_t capacity, const char *operation, NSError *error)
{
    snprintf(message, capacity, "%s failed: 0x%08X", operation,
             (unsigned int)(error ? error.code : kIOReturnError));
}

int RazerReadUSBFeature(io_service_t service, const uint8_t *request, uint8_t *response,
                       char *errorMessage, size_t errorCapacity)
{
    @autoreleasepool {
        NSError *error = nil;
        IOUSBHostDevice *device = [[IOUSBHostDevice alloc]
            initWithIOService:service
                      options:IOUSBHostObjectInitOptionsNone
                        queue:nil
                        error:&error
              interestHandler:nil];
        if (!device) {
            reportError(errorMessage, errorCapacity, "USB open", error);
            return -1;
        }

        int result = -1;
        do {
            // Razer's control report belongs to interface 0, not each HID collection.
            IOUSBDeviceRequest setRequest = {
                .bmRequestType = 0x21,
                .bRequest = 0x09,
                .wValue = 0x0300,
                .wIndex = 0,
                .wLength = 90,
            };
            NSMutableData *data = [NSMutableData dataWithBytes:request length:90];
            NSUInteger transferred = 0;
            if (![device sendDeviceRequest:setRequest data:data bytesTransferred:&transferred
                         completionTimeout:2 error:&error]) {
                reportError(errorMessage, errorCapacity, "USB set feature", error);
                break;
            }
            if (transferred != 90) {
                snprintf(errorMessage, errorCapacity, "Short USB write: %lu bytes",
                         (unsigned long)transferred);
                break;
            }
            usleep(500000);

            IOUSBDeviceRequest getRequest = {
                .bmRequestType = 0xa1,
                .bRequest = 0x01,
                .wValue = 0x0300,
                .wIndex = 0,
                .wLength = 90,
            };
            data = [NSMutableData dataWithLength:90];
            if (![device sendDeviceRequest:getRequest data:data bytesTransferred:&transferred
                         completionTimeout:2 error:&error]) {
                reportError(errorMessage, errorCapacity, "USB get feature", error);
                break;
            }
            if (transferred != 90) {
                snprintf(errorMessage, errorCapacity, "Short USB reply: %lu bytes",
                         (unsigned long)transferred);
                break;
            }
            memcpy(response, data.bytes, 90);
            result = 90;
        } while (0);

        [device destroy];
        return result;
    }
}
