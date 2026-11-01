/* Phelps USB audio configuration / normal-mode recovery helper.
 * No firmware download, persistent-store write, arbitrary USB request, or driver detach.
 * inspect: standard GET_DESCRIPTOR only; configure: verified config 1; normal: HID Feature 1 FFFF.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>

static int number(io_service_t service, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, NULL, 0);
    int result = -1;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue(value, kCFNumberIntType, &result);
    }
    if (value) CFRelease(value);
    return result;
}

static int expected_product(io_service_t service) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR("USB Product Name"), NULL, 0);
    int matches = value && CFGetTypeID(value) == CFStringGetTypeID() &&
                  CFEqual(value, CFSTR("Bose Flex SoundLink"));
    if (value) CFRelease(value);
    return matches;
}

static void release_device(IOCFPlugInInterface **plugin, IOUSBDeviceInterface320 **device,
                           io_service_t service) {
    if (device && *device) (*device)->Release(device);
    if (plugin && *plugin) (*plugin)->Release(plugin);
    if (service) IOObjectRelease(service);
}

int main(int argc, char **argv) {
    const char *operation = argc == 2 ? argv[1] : "inspect";
    if (argc > 2 || (strcmp(operation, "inspect") && strcmp(operation, "configure") &&
                     strcmp(operation, "normal"))) {
        fprintf(stderr, "usage: native_usb [inspect|configure|normal]\n");
        return 2;
    }

    io_iterator_t iterator = 0;
    kern_return_t kr = IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                                 kIORegistryIterateRecursively, &iterator);
    if (kr != KERN_SUCCESS || !iterator) {
        fprintf(stderr, "USB registry enumeration failed: 0x%08x\n", kr);
        return 5;
    }

    io_service_t target = IO_OBJECT_NULL, service = IO_OBJECT_NULL;
    unsigned candidates = 0;
    while ((service = IOIteratorNext(iterator))) {
        if (IOObjectConformsTo(service, "IOUSBHostDevice") &&
            number(service, CFSTR("idVendor")) == 0x05a7 &&
            number(service, CFSTR("idProduct")) == 0x40fa) {
            candidates++;
            if (candidates == 1) target = service;
            else IOObjectRelease(service);
        } else {
            IOObjectRelease(service);
        }
    }
    IOObjectRelease(iterator);
    if (candidates == 0) {
        fprintf(stderr, "no matching USB device 05a7:40fa\n");
        return 3;
    }
    if (candidates != 1) {
        if (target) IOObjectRelease(target);
        fprintf(stderr, "ambiguous USB device matches for 05a7:40fa: %u\n", candidates);
        return 4;
    }
    if (!expected_product(target)) {
        IOObjectRelease(target);
        fprintf(stderr, "USB product-name guard failed\n");
        return 5;
    }

    IOCFPlugInInterface **plugin = NULL;
    IOUSBDeviceInterface320 **device = NULL;
    SInt32 score = 0;
    IOReturn result = IOCreatePlugInInterfaceForService(target, kIOUSBDeviceUserClientTypeID,
                                                         kIOCFPlugInInterfaceID, &plugin, &score);
    printf("plugin result=%08x score=%d\n", result, (int)score);
    if (result != kIOReturnSuccess || !plugin) {
        release_device(plugin, device, target);
        return 5;
    }
    HRESULT query = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID320),
                                               (LPVOID *)&device);
    printf("QueryInterface=%08x device=%s\n", (unsigned)query, device ? "yes" : "no");
    if (query != S_OK || !device) {
        release_device(plugin, device, target);
        return 5;
    }

    IOUSBConfigurationDescriptorPtr cached = NULL;
    result = (*device)->GetConfigurationDescriptorPtr(device, 0, &cached);
    if (result != kIOReturnSuccess || !cached) {
        fprintf(stderr, "configuration descriptor unavailable: 0x%08x\n", result);
        release_device(plugin, device, target);
        return 6;
    }
    unsigned cached_length = USBToHostWord(cached->wTotalLength);
    if (cached_length > 4096) {
        fprintf(stderr, "cached descriptor exceeds safe inspection bound\n");
        release_device(plugin, device, target);
        return 6;
    }

    result = (*device)->USBDeviceOpen(device);
    printf("open=%08x\n", result);
    if (result != kIOReturnSuccess) {
        release_device(plugin, device, target);
        return 5;
    }

    unsigned char bytes[4096] = {0};
    IOUSBDevRequestTO request = {0};
    request.bmRequestType = 0x80;
    request.bRequest = 6;
    request.wValue = 0x0200;
    request.wIndex = 0;
    request.wLength = 9;
    request.pData = bytes;
    request.noDataTimeout = 1000;
    request.completionTimeout = 1500;
    result = (*device)->DeviceRequestTO(device, &request);
    printf("GET_DESCRIPTOR config header=%08x len=%u\n", result, (unsigned)request.wLenDone);
    if (result != kIOReturnSuccess || request.wLenDone != 9 || bytes[0] != 9 || bytes[1] != 2) {
        goto descriptor_failure;
    }
    unsigned descriptor_length = bytes[2] | ((unsigned)bytes[3] << 8);
    if (descriptor_length != 156 || descriptor_length > sizeof(bytes)) goto descriptor_failure;
    request.wLength = (UInt16)descriptor_length;
    request.wLenDone = 0;
    result = (*device)->DeviceRequestTO(device, &request);
    printf("GET_DESCRIPTOR config full=%08x len=%u hex=", result, (unsigned)request.wLenDone);
    for (unsigned i = 0; i < request.wLenDone && i < sizeof(bytes); i++) printf("%02x", bytes[i]);
    puts("");
    if (result != kIOReturnSuccess || request.wLenDone != 156 || bytes[4] != 3 || bytes[5] != 1 || bytes[2] != 156 || bytes[3] != 0) {
        goto descriptor_failure;
    }

    int hid = -1, audio_control = 0, audio_streaming = 0;
    for (unsigned offset = 9; offset < request.wLenDone;) {
        unsigned length = bytes[offset];
        if (length < 2 || offset + length > request.wLenDone) goto descriptor_failure;
        if (bytes[offset + 1] == 4 && length >= 9) {
            if (bytes[offset + 5] == 3) hid = bytes[offset + 2];
            if (bytes[offset + 5] == 1 && bytes[offset + 6] == 1) audio_control++;
            if (bytes[offset + 5] == 1 && bytes[offset + 6] == 2) audio_streaming++;
        }
        offset += length;
    }
    if (hid != 2 || audio_control != 1 || audio_streaming != 2) {
        fprintf(stderr, "REFUSED: expected HID 2, one AudioControl and two AudioStreaming interfaces\n");
        result = kIOReturnUnsupported;
        goto operation_failure;
    }

    if (!strcmp(operation, "configure")) {
        UInt8 current_configuration = 0;
        result = (*device)->GetConfiguration(device, &current_configuration);
        if (result != kIOReturnSuccess) {
            fprintf(stderr, "GetConfiguration failed: 0x%08x\n", result);
            goto operation_failure;
        }
        if (current_configuration == 1) {
            puts("configuration 1 already active; no reset sent");
        } else {
            result = (*device)->SetConfiguration(device, 1);
            printf("SET_CONFIGURATION 1=%08x\n", result);
            if (result != kIOReturnSuccess) goto operation_failure;
        }
    } else if (!strcmp(operation, "normal")) {
        unsigned char normal[3] = {1, 0xff, 0xff};
        IOUSBDevRequestTO back = {0};
        back.bmRequestType = 0x21;
        back.bRequest = 9;
        back.wValue = 0x0301;
        back.wIndex = (UInt16)hid;
        back.wLength = 3;
        back.pData = normal;
        back.noDataTimeout = 1000;
        back.completionTimeout = 1500;
        result = (*device)->DeviceRequestTO(device, &back);
        printf("normal mode SET_REPORT interface=%d data=01ffff result=%08x len=%u\n",
               hid, result, (unsigned)back.wLenDone);
        if (result != kIOReturnSuccess || back.wLenDone != 3) goto operation_failure;
    }

    (*device)->USBDeviceClose(device);
    release_device(plugin, device, target);
    return 0;

descriptor_failure:
    fprintf(stderr, "descriptor read/shape guard failed: status=0x%08x length=%u\n",
            result, (unsigned)request.wLenDone);
    result = kIOReturnBadArgument;
operation_failure:
    (*device)->USBDeviceClose(device);
    release_device(plugin, device, target);
    return 7;
}
