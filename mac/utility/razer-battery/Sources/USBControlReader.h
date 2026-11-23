#include <IOKit/IOKitLib.h>
#include <stddef.h>
#include <stdint.h>

int RazerReadUSBFeature(io_service_t service, const uint8_t *request, uint8_t *response,
                       char *errorMessage, size_t errorCapacity);
