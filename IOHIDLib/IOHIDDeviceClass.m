/*
 *
 * @APPLE_LICENSE_HEADER_START@
 *
 * Copyright (c) 2017 Apple Computer, Inc.  All Rights Reserved.
 *
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 *
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 *
 * @APPLE_LICENSE_HEADER_END@
 */

#import <Foundation/Foundation.h>
#import "IOHIDDeviceClass.h"
#import "IOHIDQueueClass.h"
#import "IOHIDTransactionClass.h"
#import <AssertMacros.h>
#import "IOHIDLibUserClient.h"
#import "HIDLibElement.h"
#import <IOKit/IODataQueueClient.h>
#import <mach/mach_port.h>
#import <mach/message.h>
#import <IOKit/hid/IOHIDLibPrivate.h>
#import <IOKit/hid/IOHIDPrivateKeys.h>
#import "IOHIDDescriptorParser.h"
#import "IOHIDDescriptorParserPrivate.h"
#import <IOKit/hidsystem/IOHIDLib.h>
#import "IOHIDFamilyPrivate.h"
#import "IOHIDFamilyProbe.h"
#if __has_include(<Rosetta/Rosetta.h>)
#  include <Rosetta/Rosetta.h>
#endif

IOHID_DYN_LINK_DYLIB(/usr/lib, Rosetta)
IOHID_DYN_LINK_FUNCTION(Rosetta, rosetta_is_current_process_translated, dyn_rosetta_is_current_process_translated, bool, false, (void), ())
IOHID_DYN_LINK_FUNCTION(Rosetta, rosetta_convert_to_rosetta_absolute_time, dyn_rosetta_convert_to_rosetta_absolute_time, uint64_t, system_time, (uint64_t system_time), (system_time))

#ifndef min
#define min(a, b) ((a < b) ? a : b)
#endif

@implementation IOHIDDeviceClass

/**
 *  Lifetime: Object, created in init, released in dealloc. Safe to read outside lock.
 *  IOHIDDeviceTimeStampedDeviceInterface   *_device;
 *  Lifetime: Object, created in start, released in dealloc. Safe to read outside lock.
 *  io_service_t                            _service;
 *  Lifetime: Object, created in initConnect, released in dealloc. Doesn't change. Safe to read outside lock, after calling initConnect.
 *  io_connect_t                            _connect;
 *
 *  os_unfair_recursive_lock_t              _deviceLock;
 *  Lifetime: Object, created in initPort, released in dealloc. Doesn't change. Safe to read outside lock, after calling initPort.
 *  mach_port_t                             _port;  
 *  Lifetime: Object, created in initPort, released in dealloc. Doesn't change. Safe to read outside lock, after calling initPort.
 *  CFMachPortRef                           _machPort;
 *  Lifetime: Object, created in initPort, released in dealloc. Doesn't change. Safe to read outside lock, after calling initPort.
 *  CFRunLoopSourceRef                      _runLoopSource;
 *  Lifetime: Object, need to sync with _deviceLock for reading/writing.
 *  BOOL                                    _opened;
 *  Lifetime: Object, need to sync with _deviceLock for reading/writing.
 *  BOOL                                    _tccRequested;
 *  Lifetime: Object, need to sync with _deviceLock for reading/writing.
 *  BOOL                                    _tccGranted;
 * 
 *  Lifetime: Object, need to sync with _deviceLock for reading/writing.
 *  IOHIDQueueClass                         *_queue;
 *  Lifetime: Object, created in initElements, released in dealloc. Doesn't change. Mutating or reading/writing elements requires the _deviceLock.
 *  NSMutableArray                          *_elements;
 *  Lifetime: Object, created in initElements, released in dealloc. Doesn't change. Mutating or reading/writing elements requires the _deviceLock.
 *  NSMutableArray                          *_sortedElements;
 *  Lifetime: Object, created in initElements, released in dealloc. Doesn't change. Mutating or reading/writing elements requires the _deviceLock.
 *  NSMutableArray                          *_reportElements;
 *  Lifetime: Object, created in init, released in dealloc. Only read/write under _deviceLock.
 *  NSMutableDictionary                     *_properties;
 * 
 *  Lifetime: None, use _deviceLock for reading the value. _callbackLock should be held when calling into the service or to update callback to ensure that the callback isn't used after it's requested to change.
 *  IOHIDReportCallback                     _inputReportCallback;
 *  IOHIDReportWithTimeStampCallback        _inputReportTimestampCallback;
 *  void                                    *_inputReportContext;
 *  
 *  uint8_t                                 *_inputReportBuffer;
 *  CFIndex                                 _inputReportBufferLength;
 */

@synthesize port = _port;
@synthesize runLoopSource = _runLoopSource;
@synthesize connect = _connect;
@synthesize service = _service;

- (HRESULT)queryInterface:(REFIID)uuidBytes
             outInterface:(LPVOID *)outInterface
{
    CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(NULL, uuidBytes);
    HRESULT result = E_NOINTERFACE;
    
    if (CFEqual(uuid, IUnknownUUID) || CFEqual(uuid, kIOCFPlugInInterfaceID)) {
        *outInterface = &self->_plugin;
        CFRetain((__bridge CFTypeRef)self);
        result = S_OK;
    } else if (CFEqual(uuid, kIOHIDDeviceDeviceInterfaceID) ||
               CFEqual(uuid, kIOHIDDeviceDeviceInterfaceID2)) {
        *outInterface = (LPVOID *)&_device;
        CFRetain((__bridge CFTypeRef)self);
        result = S_OK;
    } else if (CFEqual(uuid, kIOHIDDeviceQueueInterfaceID)) {
        [self initPort];
        [self initElements];
        
        IOHIDQueueClass *queue = [[IOHIDQueueClass alloc] initWithDevice:self];
        result = [queue queryInterface:uuidBytes outInterface:outInterface];
    } else if (CFEqual(uuid, kIOHIDDeviceTransactionInterfaceID)) {
        [self initPort];
        [self initElements];
        
        IOHIDTransactionClass *transaction;
        transaction = [[IOHIDTransactionClass alloc] initWithDevice:self];
        result = [transaction queryInterface:uuidBytes
                                outInterface:outInterface];
    }

    if (uuid) {
        CFRelease(uuid);
    }
    
    return result;
}

- (IOReturn)probe:(NSDictionary * __unused)properties
          service:(io_service_t)service
         outScore:(SInt32 * __unused)outScore
{
    if (IOObjectConformsTo(service, "IOHIDDevice")) {
        return kIOReturnSuccess;
    }
    
    return kIOReturnUnsupported;
}

- (IOHIDElementRef)getElement:(uint32_t)cookie
{
    IOHIDElementRef elementRef = NULL;
    
    if (cookie < _sortedElements.count) {
        id obj = [_sortedElements objectAtIndex:cookie];
        
        if (obj && [obj isKindOfClass:[HIDLibElement class]]) {
            elementRef = ((HIDLibElement *)obj).elementRef;
        }
    }
    
    return elementRef;
}

- (IOReturn)initElements
{
    IOReturn ret = kIOReturnError;
    uint64_t output[2];
    uint32_t outputCount = 2;
    uint64_t input = kHIDElementType;
    uint32_t elementCount;
    uint32_t reportCount;
    size_t bufferSize;
    NSMutableData *data = nil;
    uint32_t maxCookie = 0;

    os_unfair_recursive_lock_lock(&_deviceLock);
    require_action_quiet(!_elements, exit, os_unfair_recursive_lock_unlock(&_deviceLock); ret = kIOReturnSuccess);
    os_unfair_recursive_lock_unlock(&_deviceLock);
    
    ret = [self initConnect];
    require_noerr(ret, exit);
    
    ret = IOConnectCallScalarMethod(_connect,
                                    kIOHIDLibUserClientGetElementCount,
                                    0,
                                    0,
                                    output,
                                    &outputCount);
    require_noerr_action(ret, exit, HIDLogError("IOConnectCallScalarMethod(kIOHIDLibUserClientGetElementCount):%x", ret));
    
    elementCount = (uint32_t)output[0];
    reportCount = (uint32_t)output[1];
    bufferSize = sizeof(IOHIDElementStruct) * elementCount;
    data = [[NSMutableData alloc] initWithLength:bufferSize];
    
    ret = IOConnectCallMethod(_connect,
                              kIOHIDLibUserClientGetElements,
                              &input,
                              1,
                              0,
                              0,
                              0,
                              0,
                              [data mutableBytes],
                              &bufferSize);
    require_noerr_action(ret, exit, HIDLogError("IOConnectCallMethod(kIOHIDLibUserClientGetElements):%x", ret));
    
    os_unfair_recursive_lock_lock(&_deviceLock);
    _elements = [[NSMutableArray alloc] init];

    for (uint32_t i = 0; i < bufferSize; i += sizeof(IOHIDElementStruct)) {
        IOHIDElementStruct *elementStruct = &[data mutableBytes][i];
        IOHIDElementRef parentRef = NULL;
        HIDLibElement *element;
        uint32_t cookieCount;
        
        if (elementStruct->cookieMax > maxCookie) {
            maxCookie = elementStruct->cookieMax;
        }
        
        cookieCount = elementStruct->cookieMax - elementStruct->cookieMin + 1;
        
        // Find the parent element, if any
        if (elementStruct->parentCookie) {
            for (HIDLibElement *ele in _elements) {
                if (elementStruct->parentCookie == ele.elementCookie) {
                    parentRef = ele.elementRef;
                }
            }
        }
        
        /*
         * The element structs that are provided to us from the IOConnect call
         * may contain a range of cookies. It's up to us to turn each of those
         * cookies into an element. If cookieMin == cookieMax, then there is
         * only one element.
         */
        if (elementStruct->cookieMin == elementStruct->cookieMax) {
            element = [[HIDLibElement alloc] initWithElementStruct:elementStruct
                                                            parent:parentRef
                                                             index:0];
            _IOHIDElementSetDeviceInterface(element.elementRef,
                                            (IOHIDDeviceDeviceInterface **)&_device);
            [_elements addObject:element];
            continue;
        } else {
            /*
             * Iterate through the cookies and generate elements for each one.
             * The index that we pass in will determine the element's usage,
             * among other things.
             */
            for (uint32_t j = 0; j < cookieCount; j++) {
                element = [[HIDLibElement alloc] initWithElementStruct:elementStruct
                                                                parent:parentRef
                                                                 index:j];
                _IOHIDElementSetDeviceInterface(element.elementRef,
                                                (IOHIDDeviceDeviceInterface **)&_device);
                [_elements addObject:element];
            }
        }
    }
    os_unfair_recursive_lock_unlock(&_deviceLock);
    
    input = kHIDReportHandlerType;
    bufferSize = sizeof(IOHIDElementStruct) * reportCount;
    data = [[NSMutableData alloc] initWithLength:bufferSize];
    
    ret = IOConnectCallMethod(_connect,
                              kIOHIDLibUserClientGetElements,
                              &input,
                              1,
                              0,
                              0,
                              0,
                              0,
                              [data mutableBytes],
                              &bufferSize);
    
    if (ret == kIOReturnSuccess) {
        /*
         * These report handler elements are by our IOHIDQueue for receiving
         * input reports.
         */
        os_unfair_recursive_lock_lock(&_deviceLock);
        _reportElements = [[NSMutableArray alloc] init];
        
        for (uint32_t i = 0; i < bufferSize; i += sizeof(IOHIDElementStruct)) {
            IOHIDElementStruct *elementStruct = &[data mutableBytes][i];
            HIDLibElement *element;
            
            element = [[HIDLibElement alloc] initWithElementStruct:elementStruct
                                                            parent:NULL
                                                             index:0];
            [_reportElements addObject:element];
            
            if (element.elementCookie > maxCookie) {
                maxCookie = element.elementCookie;
            }
        }
    } else {
        os_unfair_recursive_lock_lock(&_deviceLock);
    }
    
    // Keep an array of elements sorted by cookie, for faster access in
    // getElement method.
    _sortedElements = [[NSMutableArray alloc] initWithCapacity:maxCookie + 1];
    for (uint32_t i = 0; i < maxCookie + 1; i++) {
        _sortedElements[i] = @NO;
    }
    
    for (HIDLibElement *element in _elements) {
        [_sortedElements replaceObjectAtIndex:element.elementCookie withObject:element];
    }
    
    for (HIDLibElement *element in _reportElements) {
        [_sortedElements replaceObjectAtIndex:element.elementCookie withObject:element];
    }
    os_unfair_recursive_lock_unlock(&_deviceLock);
    
    ret = kIOReturnSuccess;
    
exit:
    return ret;
}

static void _portCallback(CFMachPortRef port,
                          void *msg,
                          CFIndex size,
                          void *info)
{
    IOHIDDeviceClass *me = (__bridge id)info;

    if (((mach_msg_header_t *)msg)->msgh_id == kOSNotificationMessageID) {
        IODispatchCalloutFromMessage(0, msg, 0);
    } else {
        [me->_queue queueCallback:port msg:msg size:size info:info];
    }
}

- (void)initPort
{
    CFMachPortContext context = { 0, (__bridge void *)self, NULL, NULL, NULL };

    os_unfair_recursive_lock_lock(&_deviceLock);
    
    require_quiet(!_port, exit);
    
    _port = IODataQueueAllocateNotificationPort();
    require(_port, exit);
    
    _machPort = CFMachPortCreateWithPort(kCFAllocatorDefault,
                                         _port,
                                         (CFMachPortCallBack)_portCallback,
                                         &context, NULL);
    require(_machPort, exit);
    
    _runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault,
                                                   _machPort,
                                                   0);
    require(_runLoopSource, exit);
exit:
    os_unfair_recursive_lock_unlock(&_deviceLock);
    return;
}

- (mach_port_t)getPort
{
    [self initPort];
    return _port;
}

- (void)initQueue
{   
    os_unfair_recursive_lock_lock(&_deviceLock);
    require_quiet(!_queue, exit);

    [self initPort];
    
    require_noerr([self initElements], exit);
    _queue = [[IOHIDQueueClass alloc] initWithDevice:self
                                                port:_port
                                              source:_runLoopSource];
    require_action(_queue, exit, HIDLogError("Failed to create queue"));
    
    [_queue setValueAvailableCallback:_valueAvailableCallback
                              context:(__bridge void *)self];
    
    for (HIDLibElement *element in _reportElements) {
        [_queue addElement:element.elementRef];
    }
    
exit:
    os_unfair_recursive_lock_unlock(&_deviceLock);
    return;
}

- (IOReturn)initConnect
{
    IOReturn ret = kIOReturnError;
    io_connect_t connection;

    os_unfair_recursive_lock_lock(&_deviceLock);
    if (_connect) {
        os_unfair_recursive_lock_unlock(&_deviceLock);
        return kIOReturnSuccess;
    }
    os_unfair_recursive_lock_unlock(&_deviceLock);
    
    uint64_t regID;
    
    IORegistryEntryGetRegistryEntryID(_service, &regID);
    os_unfair_recursive_lock_lock(&_deviceLock);
    if (!_tccRequested) {
        NSNumber *tcc = CFBridgingRelease(IORegistryEntryCreateCFProperty(
                                    _service,
                                    CFSTR(kIOHIDRequiresTCCAuthorizationKey),
                                    kCFAllocatorDefault,
                                    0));
        
        if (tcc && [tcc isEqual:@YES]) {
            _tccGranted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
        } else {
            _tccGranted = true;
        }
        
        _tccRequested = true;
    }
    
    if (!_tccGranted) {
        HIDLogError("0x%llx: TCC deny IOHIDDeviceOpen", regID);
    }
    require_action(_tccGranted, exit, {
        ret = kIOReturnNotPermitted;
        os_unfair_recursive_lock_unlock(&_deviceLock);
    });
    os_unfair_recursive_lock_unlock(&_deviceLock);
    
    ret = IOServiceOpen(_service,
                        mach_task_self(),
                        kIOHIDLibUserClientConnectManager,
                        &connection);
    require_action(ret == kIOReturnSuccess && connection, exit,
                   HIDLogError("IOServiceOpen failed: 0x%x", ret));

    ret = kIOReturnSuccess;
    os_unfair_recursive_lock_lock(&_deviceLock);
    _connect = connection;
    os_unfair_recursive_lock_unlock(&_deviceLock);
    
exit:
    return ret;
}

- (IOReturn)start:(NSDictionary * __unused)properties
          service:(io_service_t)service
{
    IOReturn ret  = IOObjectRetain(service);
    require_noerr_action(ret, exit, HIDLogError("IOHIDDeviceClass failed to retain service object with err %x", ret));
    os_unfair_recursive_lock_lock(&_deviceLock);
    _service = service;
    os_unfair_recursive_lock_unlock(&_deviceLock);
exit:
    return ret;
}

- (IOReturn)stop
{
    return kIOReturnSuccess;
}

static IOReturn _open(void *iunknown, IOOptionBits options)
{
    IUnknownVTbl *vtbl = *((IUnknownVTbl**)iunknown);
    IOHIDDeviceClass *me = (__bridge id)vtbl->_reserved;
    
    return [me open:options];
}

- (IOReturn)open:(IOOptionBits)options
{
    IOReturn ret = kIOReturnError;
    uint64_t input = options;
    
    ret = [self initConnect];
    require_noerr(ret, exit);
    
    ret = IOConnectCallScalarMethod(_connect, kIOHIDLibUserClientOpen, &input, 1, 0, NULL);
    if (ret == kIOReturnExclusiveAccess) {
        HIDLogInfo("Device is seized, reports will be dropped until the seizing client closes");
    } else {
        require_noerr_action(ret, exit, HIDLogError("IOConnectCallMethod(kIOHIDLibUserClientOpen):%x", ret));
    }
    
    os_unfair_recursive_lock_lock(&_deviceLock);
    _opened = (ret == kIOReturnSuccess || ret == kIOReturnExclusiveAccess);
        
    if (_inputReportCallback || _inputReportTimestampCallback) {
        [_queue start];
    }
    os_unfair_recursive_lock_unlock(&_deviceLock);
    
exit:
    return ret;
}

static IOReturn _close(void * iunknown, IOOptionBits options)
{
    IUnknownVTbl *vtbl = *((IUnknownVTbl**)iunknown);
    IOHIDDeviceClass *me = (__bridge id)vtbl->_reserved;
    
    return [me close:options];
}

- (IOReturn)close:(IOOptionBits __unused)options
{
    IOReturn ret;
    
    os_unfair_recursive_lock_lock(&_deviceLock);
    require_action(_opened, exit, ret = kIOReturnNotOpen);
    os_unfair_recursive_lock_unlock(&_deviceLock);
    
    ret = [self initConnect];
    require_noerr_action(ret, exit, os_unfair_recursive_lock_lock(&_deviceLock));
    
    os_unfair_recursive_lock_lock(&_deviceLock);
    if (_inputReportCallback || _inputReportTimestampCallback) {
        [_queue stop];
    }
    os_unfair_recursive_lock_unlock(&_deviceLock);

    ret = IOConnectCallScalarMethod(_connect,
                                    kIOHIDLibUserClientClose,
                                    0,
                                    0,
                                    0,
                                    NULL);
    
    os_unfair_recursive_lock_lock(&_deviceLock);
    _opened = false;
    
exit:
    os_unfair_recursive_lock_unlock(&_deviceLock);
    return ret;
}

static IOReturn _getProperty(void *iunknown,
                             CFStringRef key,
                             CFTypeRef *pProperty)
{
    IUnknownVTbl *vtbl = *((IUnknownVTbl**)iunknown);
    IOHIDDeviceClass *me = (__bridge id)vtbl->_reserved;
    
    return [me getProperty:(__bridge NSString *)key property:pProperty];
}

- (IOReturn)getProperty:(NSString *)key property:(CFTypeRef *)pProperty
{
    if (!pProperty) {
        return kIOReturnBadArgument;
    }

    os_unfair_recursive_lock_lock(&_deviceLock);
    CFTypeRef prop = (__bridge CFTypeRef)_properties[key];
    os_unfair_recursive_lock_unlock(&_deviceLock);
    if (!prop) {
        if ([key isEqualToString:@(kIOHIDUniqueIDKey)]) {
            uint64_t regID;
            IORegistryEntryGetRegistryEntryID(_service, &regID);
            prop = CFNumberCreate(kCFAllocatorDefault,
                                  kCFNumberLongLongType,
                                  &regID);
        } else {
            prop = IORegistryEntrySearchCFProperty(_service,
                                                   kIOServicePlane,
                                                   (__bridge CFStringRef)key,
                                                   kCFAllocatorDefault,
                                                   kIORegistryIterateRecursively
                                                   | kIORegistryIterateParents);
        }
        
        if (prop) {
            // Force a copy of the string to avoid the key reference from getting courrpted
            NSString * dictKey = [key mutableCopy];
            os_unfair_recursive_lock_lock(&_deviceLock);
            _properties[dictKey] = (__bridge id)prop;
            os_unfair_recursive_lock_unlock(&_deviceLock);
            CFRelease(prop);
        }
    }
    
    *pProperty = prop;

    return kIOReturnSuccess;
}

static IOReturn _setProperty(void *iunknown,
                             CFStringRef key,
                             CFTypeRef property)
{
    IUnknownVTbl *vtbl = *((IUnknownVTbl**)iunknown);
    IOHIDDeviceClass *me = (__bridge id)vtbl->_reserved;
    
    return [me setProperty:(__bridge NSString *)key
                  property:(__bridge id)property];
}

- (IOReturn)setProperty:(NSString *)key property:(id)property
{
    // Force a copy of the key and property to avoid the client from courrpting the storage.
    // CFPropertyList is used to do a deep copy. Only types that are supported by Property Lists are valid then.
    kern_return_t ret = kIOReturnSuccess;
    NSString* keyCopy = [key mutableCopy];
    id propertyCopy = property ? (__bridge_transfer id)CFPropertyListCreateDeepCopy(kCFAllocatorDefault, (__bridge CFTypeRef)property, kCFPropertyListMutableContainersAndLeaves) : nil;

    os_unfair_recursive_lock_lock(&_deviceLock);
    if ([key isEqualToString:@(kIOHIDDeviceSuspendKey)]) {
        require(_queue, exit);
        
        if ([property boolValue]) {
            [_queue stop];
        } else {
            [_queue start];
        }
    } else if ([key isEqualToString:@kIOHIDMaxReportBufferCountKey] || [key isEqualToString:@kIOHIDReportBufferEntrySizeKey] || [key isEqualToString:@kIOHIDDeviceForceInterfaceRematchKey]) {
        os_unfair_recursive_lock_unlock(&_deviceLock);
        ret = IOConnectSetCFProperty(_connect, (__bridge CFStringRef)key, (__bridge CFTypeRef)property);
        os_unfair_recursive_lock_lock(&_deviceLock);
    }
    
exit:
    _properties[keyCopy] = propertyCopy;
    os_unfair_recursive_lock_unlock(&_deviceLock);

    return ret;
}

static IOReturn _getAsyncEventSource(void *iunknown, CFTypeRef *pSource)
{
    IUnknownVTbl *vtbl = *((IUnknownVTbl**)iunknown);
    IOHIDDeviceClass *me = (__bridge id)vtbl->_reserved;
    
    return [me getAsyncEventSource:pSource];
}

- (IOReturn)getAsyncEventSource:(CFTypeRef *)pSource
{
    if (!pSource) {
        return kIOReturnBadArgument;
    }
    
    [self initPort];
    
    os_unfair_recursive_lock_lock(&_deviceLock);
    *pSource = _runLoopSource;
    os_unfair_recursive_lock_unlock(&_deviceLock);
    
    return kIOReturnSuccess;
}

- (NSString *)propertyForElementKey:(NSString *)key
{
    /*
     * This will just convert the first letter in the kIOHIDElement key to
     * lowercase, so we can use it with NSPredicate.
     */
    
    NSString *firstChar = [[key substringToIndex:1] lowercaseString];
    NSString *prop = [key stringByReplacingCharactersInRange:NSMakeRange(0,1)
                                                  withString:firstChar];
    
    return prop;
}

- (NSMutableArray *)copyObsoleteDictionary:(NSArray *)elements
{
    /*
     * The IOHIDObsoleteDeviceClass's version of copyMatchingElements returns an
     * array of dictionaries that contains key/value pairs for each element's
     * values. We have to go through the arduous process of converting the
     * elements' properties into these dictionaries.
     */
    
    NSMutableArray *result = [[NSMutableArray alloc] init];
    
    for (HIDLibElement *element in elements) {
        IOHIDElementStruct eleStruct = element.elementStruct;
        NSMutableDictionary *props = [[NSMutableDictionary alloc] init];
        
        bool nullState = eleStruct.flags & kHIDDataNullStateBit;
        bool prefferedState = eleStruct.flags & kHIDDataNoPreferredBit;
        bool nonLinear = eleStruct.flags & kHIDDataNonlinearBit;
        bool relative = eleStruct.flags & kHIDDataRelativeBit;
        bool wrapping = eleStruct.flags & kHIDDataWrapBit;
        bool array = eleStruct.flags & kHIDDataArrayBit;
        
        props[@(kIOHIDElementCookieKey)] = @(element.elementCookie);
        props[@(kIOHIDElementCollectionCookieKey)] = @(eleStruct.parentCookie);
        props[@(kIOHIDElementTypeKey)] = @(element.type);
        props[@(kIOHIDElementUsageKey)] = @(element.usage);
        props[@(kIOHIDElementUsagePageKey)] = @(element.usagePage);
        props[@(kIOHIDElementReportIDKey)] = @(element.reportID);
        if (eleStruct.duplicateValueSize &&
            eleStruct.duplicateIndex != 0xFFFFFFFF) {
            props[@(kIOHIDElementDuplicateIndexKey)] = @(eleStruct.duplicateIndex);
        }
        props[@(kIOHIDElementSizeKey)] = @(eleStruct.size);
        props[@(kIOHIDElementReportSizeKey)] = @(eleStruct.reportSize);
        props[@(kIOHIDElementReportCountKey)] = @(eleStruct.reportCount);
        props[@(kIOHIDElementHasNullStateKey)] = @(nullState);
        props[@(kIOHIDElementHasPreferredStateKey)] = @(prefferedState);
        props[@(kIOHIDElementIsNonLinearKey)] = @(nonLinear);
        props[@(kIOHIDElementIsRelativeKey)] = @(relative);
        props[@(kIOHIDElementIsWrappingKey)] = @(wrapping);
        props[@(kIOHIDElementIsArrayKey)] = @(array);
        props[@(kIOHIDElementMaxKey)] = @(eleStruct.max);
        props[@(kIOHIDElementMinKey)] = @(eleStruct.min);
        props[@(kIOHIDElementScaledMaxKey)] = @(eleStruct.scaledMax);
        props[@(kIOHIDElementScaledMinKey)] = @(eleStruct.scaledMin);
        props[@(kIOHIDElementUnitKey)] = @(element.unit);
        props[@(kIOHIDElementUnitExponentKey)] = @(element.unitExponent);
        
        [result addObject:props];
    }
    
    return result;
}

static IOReturn _copyMatchingElements(void *iunknown,
                                      CFDictionaryRef matchingDict,
                                      CFArrayRef *pElements,
                                      IOOptionBits options)
{
    IUnknownVTbl *vtbl = *((IUnknownVTbl**)iunknown);
    IOHIDDeviceClass *me = (__bridge id)vtbl->_reserved;
    
    return [me copyMatchingElements:(__bridge NSDictionary *)matchingDict
                           elements:pElements
                            options:options];
}

- (IOReturn)copyMatchingElements:(NSDictionary *)matching
                        elements:(CFArrayRef *)pElements
                         options:(IOOptionBits __unused)options
{
    IOReturn ret;
    
    if (!pElements) {
        return kIOReturnBadArgument;
    }
    
    ret = [self initElements];
    if (ret != kIOReturnSuccess) {
        return ret;
    }
    
    os_unfair_recursive_lock_lock(&_deviceLock);
    NSMutableArray *elements = [[NSMutableArray alloc] initWithArray:_elements];
    os_unfair_recursive_lock_unlock(&_deviceLock);
    NSMutableArray *result = nil;
    
    [matching enumerateKeysAndObjectsUsingBlock:^(NSString *key,
                                                  NSNumber *val,
                                                  BOOL *stop __unused)
    {
        @autoreleasepool {
            NSPredicate *predicate = nil;
            NSString *prop;
            NSPredicateOperatorType type = NSEqualToPredicateOperatorType;
            NSExpression *left;
            NSExpression *right;
            
            /*
             * Special case for usage/cookie min/max keys. We want to check
             * the actual usage/cookie key, and verify that is within the range.
             * We use >=/<= operators, rather than == here.
             */
            if ([key isEqualToString:@kIOHIDElementUsageMinKey]) {
                prop = [self propertyForElementKey:@kIOHIDElementUsageKey];
                type = NSGreaterThanOrEqualToPredicateOperatorType;
            } else if ([key isEqualToString:@kIOHIDElementUsageMaxKey]) {
                prop = [self propertyForElementKey:@kIOHIDElementUsageKey];
                type = NSLessThanOrEqualToPredicateOperatorType;
            } else if ([key isEqualToString:@kIOHIDElementCookieMinKey]) {
                prop = [self propertyForElementKey:@kIOHIDElementCookieKey];
                type = NSGreaterThanOrEqualToPredicateOperatorType;
            } else if ([key isEqualToString:@kIOHIDElementCookieMaxKey]) {
                prop = [self propertyForElementKey:@kIOHIDElementCookieKey];
                type = NSLessThanOrEqualToPredicateOperatorType;
            } else {
                prop = [self propertyForElementKey:key];
            }
            
            /*
             * This will continuously filter the elements until we are left with
             * only matching elements.
             */
            
            left = [NSExpression expressionForKeyPath:prop];
            right = [NSExpression expressionForConstantValue:val];
            
            predicate = [NSComparisonPredicate
                         predicateWithLeftExpression:left
                         rightExpression:right
                         modifier:NSDirectPredicateModifier
                         type:type
                         options:0];
            
            @try {
                [elements filterUsingPredicate:predicate];
            } @catch (NSException *e) {
                HIDLogError("Unsupported matching criteria: %@ %@", prop, e);
            }
        }
    }];
    
    require(elements.count, exit);
    
    if (options & kHIDCopyMatchingElementsDictionary) {
        // Handle IOHIDObsoleteDeviceClass's copyMatchingElements
        result = [self copyObsoleteDictionary:elements];
    } else {
        result = [[NSMutableArray alloc] init];
        
        for (HIDLibElement *element in elements) {
            [result addObject:(__bridge id)element.elementRef];
        }
    }
    
exit:
    *pElements = (CFArrayRef)CFBridgingRetain(result);
    
    return kIOReturnSuccess;
}

static IOReturn _setValue(void *iunknown,
                          IOHIDElementRef element,
                          IOHIDValueRef value,
                          uint32_t timeout,
                          IOHIDValueCallback callback,
                          void *context,
                          IOOptionBits options)
{
    IUnknownVTbl *vtbl = *((IUnknownVTbl**)iunknown);
    IOHIDDeviceClass *me = (__bridge id)vtbl->_reserved;
    
    return [me setValue:element
                  value:value
                timeout:timeout
               callback:callback
                context:context
                options:options];
}

- (IOReturn)setValue:(IOHIDElementRef)elementRef
               value:(IOHIDValueRef)value
             timeout:(uint32_t __unused)timeout
            callback:(IOHIDValueCallback __unused)callback
             context:(void * __unused)context
             options:(IOOptionBits)options
{
    IOReturn ret = kIOReturnError;
    HIDLibElement *element = nil;
    HIDLibElement *tmp = nil;
    IOHIDElementValueHeader *inputStruct = NULL;
    uint32_t inputSize = 0;
    uint64_t input = 0;
    NSUInteger elementIndex;
    CFIndex valueLength = 0;
    
    os_unfair_recursive_lock_lock(&_deviceLock);
    require_action(_opened, exit, ret = kIOReturnNotOpen);
    
    ret = [self initElements];
    require_noerr(ret, exit);

    tmp = [[HIDLibElement alloc] initWithElementRef:elementRef];
    require_action(tmp, exit, ret = kIOReturnError);
    
    elementIndex = [_elements indexOfObject:tmp];
    require_action(elementIndex != NSNotFound, exit, ret = kIOReturnBadArgument);
    
    element = [_elements objectAtIndex:elementIndex];
    require_action(element.type == kIOHIDElementTypeOutput ||
                   element.type == kIOHIDElementTypeFeature,
                   exit,
                   ret = kIOReturnBadArgument);

    require_action(value, exit, ret = kIOReturnBadArgument);

    // Allows checking element is valid without informing kernel. Used by HIDTransactionClass.
    require_action(!(options & kHIDSetElementValuePendEvent),
                   exit,
                   ret = kIOReturnSuccess);

    // Send the value to the kernel.
    valueLength = IOHIDValueGetLength(value);
    require_action(valueLength>=0, exit, ret = kIOReturnError);

    inputSize = (uint32_t)(sizeof(IOHIDElementValueHeader) + valueLength);
    inputStruct = malloc(inputSize);
    _IOHIDValueCopyToElementValueHeader(value, inputStruct);
    
    ret = IOConnectCallMethod(_connect,
                              kIOHIDLibUserClientPostElementValues,
                              &input,
                              1,
                              inputStruct,
                              inputSize,
                              0,
                              NULL,
                              NULL,
                              NULL);
    free(inputStruct);
    if (ret) {
        uint64_t regID;
        IORegistryEntryGetRegistryEntryID(_service, &regID);
        HIDLogError("kIOHIDLibUserClientPostElementValues(%llx):%x", regID, ret);
    } else {
        [element setValueRef:value];
    }
exit:
    os_unfair_recursive_lock_unlock(&_deviceLock);
    return ret;
}

static IOReturn _getValue(void *iunknown,
                          IOHIDElementRef element,
                          IOHIDValueRef *pValue,
                          uint32_t timeout,
                          IOHIDValueCallback callback,
                          void *context,
                          IOOptionBits options)
{
    IUnknownVTbl *vtbl = *((IUnknownVTbl**)iunknown);
    IOHIDDeviceClass *me = (__bridge id)vtbl->_reserved;
    
    return [me getValue:element
                  value:pValue
                timeout:timeout
               callback:callback
                context:context
                options:options];
}

- (IOReturn)getValue:(IOHIDElementRef)elementRef
               value:(IOHIDValueRef *)pValue
             timeout:(uint32_t __unused)timeout
            callback:(IOHIDValueCallback __unused)callback
             context:(void * __unused)context
             options:(IOOptionBits)options
{
    IOReturn ret = kIOReturnError;
    HIDLibElement *element = nil;
    HIDLibElement *tmp = nil;
    IOHIDElementValue *elementValue = NULL;
    uint64_t timestamp;
    uint32_t input = 0;
    size_t inputSize = 0;
    size_t outputSize = 0;
    size_t elementSize = 0;
    uint64_t updateOptions[3] = {0};
    NSUInteger elementIndex;
    
    if (!pValue) {
        return kIOReturnBadArgument;
    }
    
    os_unfair_recursive_lock_lock(&_deviceLock);
    require_action(_opened, exit, ret = kIOReturnNotOpen);
    
    ret = [self initElements];
    require_noerr(ret, exit);

    tmp = [[HIDLibElement alloc] initWithElementRef:elementRef];
    require_action(tmp, exit, ret = kIOReturnError);
    
    elementIndex = [_elements indexOfObject:tmp];
    require_action(elementIndex != NSNotFound,
                   exit,
                   ret = kIOReturnBadArgument);
    
    element = [_elements objectAtIndex:elementIndex];
    require_action(element.type != kIOHIDElementTypeCollection,
                   exit,
                   ret = kIOReturnBadArgument);

    if (element.valueRef) {
        *pValue = element.valueRef;
    }

    // Allows checking element is valid without informing kernel. Used by HIDTransactionClass.
    require_action(!(options & kHIDGetElementValuePendEvent),
                   exit,
                   ret = kIOReturnSuccess);

    // Do not poll to the device if options prevent poll, or we are not getting a feature report
    if (options & kHIDGetElementValuePreventPoll ||
        element.type != kIOHIDElementTypeFeature) {
        updateOptions[2] |= kIOHIDElementPreventPoll;
    }

    // Call to device if Forcing Poll
    if (options & kHIDGetElementValueForcePoll && updateOptions[2] & kIOHIDElementPreventPoll) {
        updateOptions[2] ^= kIOHIDElementPreventPoll;
    }

    input =  (uint32_t)element.elementCookie;
    inputSize = sizeof(uint32_t);
    elementSize = sizeof(IOHIDElementValue) + _IOHIDElementGetLength(element.elementRef);
    outputSize = elementSize;
    elementValue = (IOHIDElementValue*)malloc(elementSize);

    ret = IOConnectCallMethod(_connect,
                              kIOHIDLibUserClientUpdateElementValues,
                              updateOptions,
                              3,
                              &input,
                              sizeof(input),
                              0,
                              NULL,
                              elementValue,
                              &outputSize);
    require_noerr(ret, exit);
    
    // Update our value after kernel call
    timestamp = *((uint64_t *)&(elementValue->timestamp));

    // Convert to the same time base as element.timestamp
    timestamp = dyn_rosetta_is_current_process_translated() ?
        dyn_rosetta_convert_to_rosetta_absolute_time(timestamp) : timestamp;
    
    // Check if we need to update our value
    if (!element.valueRef ||
        element.timestamp < timestamp ||
        element.type == kIOHIDElementTypeFeature) {
        IOHIDValueRef valueRef;
        
        valueRef = _IOHIDValueCreateWithElementValuePtr(kCFAllocatorDefault,
                                                        element.elementRef,
                                                        elementValue);

        if (valueRef) {
            element.valueRef = valueRef;
            CFRelease(valueRef);
        }
    }
    
    *pValue = element.valueRef;
    
exit:
    os_unfair_recursive_lock_unlock(&_deviceLock);
    if (elementValue) {
        free(elementValue);
    }
    return ret;
}

static void _valueAvailableCallback(void *context,
                                    IOReturn result,
                                    void *sender __unused)
{
    IOHIDDeviceClass *me = (__bridge IOHIDDeviceClass *)context;
    [me valueAvailableCallback:result];
}

- (void)valueAvailableCallback:(IOReturn)result
{
    IOHIDValueRef value;
    CFIndex size = 0;
    
    os_unfair_recursive_lock_lock(&_deviceLock);
    while ((result = [_queue copyNextValue:&value]) == kIOReturnSuccess) {
        os_unfair_recursive_lock_unlock(&_deviceLock);
        IOHIDElementRef element;
        uint32_t reportID;
        uint64_t timestamp;
        
        if (IOHIDValueGetBytePtr(value) && IOHIDValueGetLength(value)) {
            size = min(_inputReportBufferLength, IOHIDValueGetLength(value));
            if (size < 0) {
                CFRelease(value);
                os_unfair_recursive_lock_lock(&_deviceLock);
                continue;
            }
            
            bcopy(IOHIDValueGetBytePtr(value), _inputReportBuffer, size);
        }
        
        element = IOHIDValueGetElement(value);
        reportID = IOHIDElementGetReportID(element);
        timestamp = IOHIDValueGetTimeStamp(value);
        if (IOHIDFAMILY_HID_TRACE_ENABLED()) {
            
            uint64_t regID;
            IORegistryEntryGetRegistryEntryID(_service, &regID);
            
            IOHIDFAMILY_HID_TRACE(kHIDTraceHandleReport, (uintptr_t)regID, (uintptr_t)reportID, (uintptr_t)size, (uintptr_t)timestamp, (uintptr_t)_inputReportBuffer);
            
        }

        os_unfair_recursive_lock_lock(&_deviceLock);
        IOHIDReportCallback inputReportCallback = _inputReportCallback;
        IOHIDReportWithTimeStampCallback inputReportTimestampCallback = _inputReportTimestampCallback;
        void * inputReportContext = _inputReportContext;
        uint8_t * inputReportBuffer = _inputReportBuffer;
        os_unfair_recursive_lock_unlock(&_deviceLock);
        
        if (inputReportCallback) {
            os_unfair_recursive_lock_lock(&_callbackLock);
            (inputReportCallback)(inputReportContext,
                                   result,
                                   &_device,
                                   kIOHIDReportTypeInput,
                                   reportID,
                                   inputReportBuffer,
                                   size);
            os_unfair_recursive_lock_unlock(&_callbackLock);
        }

        if (inputReportTimestampCallback) {
            os_unfair_recursive_lock_lock(&_callbackLock);
            (inputReportTimestampCallback)(inputReportContext,
                                            result,
                                            &_device,
                                            kIOHIDReportTypeInput,
                                            reportID,
                                            inputReportBuffer,
                                            size,
                                            timestamp);
            os_unfair_recursive_lock_unlock(&_callbackLock);
        }

        CFRelease(value);
        os_unfair_recursive_lock_lock(&_deviceLock);
    }

    // If there are any blocked reports signal that they can be dequeued
    [_queue signalQueueEmpty];
    os_unfair_recursive_lock_unlock(&_deviceLock);
    
}

static IOReturn _setInputReportCallback(void *iunknown,
                                        uint8_t *report,
                                        CFIndex reportLength,
                                        IOHIDReportCallback callback,
                                        void *context,
                                        IOOptionBits options)
{
    IUnknownVTbl *vtbl = *((IUnknownVTbl**)iunknown);
    IOHIDDeviceClass *me = (__bridge id)vtbl->_reserved;
    
    return [me setInputReportCallback:report
                         reportLength:reportLength
                             callback:callback
                              context:context
                              options:options];
}

- (IOReturn)setInputReportCallback:(uint8_t *)report
                      reportLength:(CFIndex)reportLength
                          callback:(IOHIDReportCallback)callback
                           context:(void *)context
                           options:(IOOptionBits __unused)options
{
    os_unfair_recursive_lock_lock(&_deviceLock);
    os_unfair_recursive_lock_lock(&_callbackLock);
    _inputReportBuffer = report;
    _inputReportBufferLength = reportLength;
    _inputReportContext = context;
    _inputReportCallback = callback;
    os_unfair_recursive_lock_unlock(&_callbackLock);
    os_unfair_recursive_lock_unlock(&_deviceLock);
    
    [self initQueue];
    
    os_unfair_recursive_lock_lock(&_deviceLock);
    if (_opened) {
        [_queue start];
    }
    os_unfair_recursive_lock_unlock(&_deviceLock);
    
    return kIOReturnSuccess;
}

typedef struct {
    IOHIDReportType     type;
    uint8_t           * buffer;
    uint32_t            reportID;
    IOHIDReportCallback callback;
    void              * context;
    void              * sender;
    void              * device;
} AsyncReportContext;

static void _asyncCallback(void * context, IOReturn result, uint32_t bufferSize, uint64_t addr)
{
    AsyncReportContext * asyncContext = (AsyncReportContext *)context;

    if (!asyncContext || !asyncContext->callback) {
        return;
    }

    if (addr && asyncContext->sender) {
        bcopy((void *)addr, asyncContext->buffer, bufferSize);
        [(__bridge IOHIDDeviceClass *)asyncContext->sender releaseReport:addr];
    }

    ((IOHIDReportCallback)asyncContext->callback)(asyncContext->context,
                                                  result,
                                                  asyncContext->device,
                                                  asyncContext->type,
                                                  asyncContext->reportID,
                                                  asyncContext->buffer,
                                                  bufferSize);
    free(asyncContext);
}

static IOReturn _setReport(void *iunknown,
                           IOHIDReportType reportType,
                           uint32_t reportID,
                           const uint8_t *report,
                           CFIndex reportLength,
                           uint32_t timeout,
                           IOHIDReportCallback callback,
                           void *context,
                           IOOptionBits options)
{
    IUnknownVTbl *vtbl = *((IUnknownVTbl**)iunknown);
    IOHIDDeviceClass *me = (__bridge id)vtbl->_reserved;
    
    return [me setReport:reportType
                reportID:reportID
                  report:report
            reportLength:reportLength
                 timeout:timeout
                callback:callback
                 context:context
                 options:options];
}

- (IOReturn)setReport:(IOHIDReportType)reportType
             reportID:(uint32_t)reportID
               report:(const uint8_t *)report
         reportLength:(CFIndex)reportLength
              timeout:(uint32_t)timeout
             callback:(IOHIDReportCallback)callback
              context:(void *)context
              options:(IOOptionBits __unused)options
{
    IOReturn ret = kIOReturnError;
    uint64_t input[3] = { 0 };
    
    input[0] = reportType;
    input[1] = reportID;
    
    os_unfair_recursive_lock_lock(&_deviceLock);
    require_action(_opened, exit, {
        ret = kIOReturnNotOpen;
        os_unfair_recursive_lock_unlock(&_deviceLock);
    });
    os_unfair_recursive_lock_unlock(&_deviceLock);

    if (callback) {
        io_async_ref64_t asyncRef;
        AsyncReportContext *asyncContext;
        
        input[2] = timeout;
        
        asyncContext = (AsyncReportContext *)malloc(sizeof(AsyncReportContext));
        require(asyncContext, exit);
        
        asyncContext->type = reportType;
        asyncContext->buffer = (uint8_t *)report;
        asyncContext->reportID = reportID;
        asyncContext->callback = callback;
        asyncContext->context = context;
        asyncContext->sender = (__bridge void *) self;
        asyncContext->device = &_device;
        
        asyncRef[kIOAsyncCalloutFuncIndex] = (uint64_t)_asyncCallback;
        asyncRef[kIOAsyncCalloutRefconIndex] = (uint64_t)asyncContext;
        
        [self initPort];
        
        ret = IOConnectCallAsyncMethod(_connect,
                                       kIOHIDLibUserClientSetReport,
                                       _port,
                                       asyncRef,
                                       kIOAsyncCalloutCount,
                                       input,
                                       3,
                                       report,
                                       reportLength,
                                       0,
                                       0,
                                       0,
                                       0);
        if (ret != kIOReturnSuccess) {
            free(asyncContext);
        }
    }
    else {
        ret = IOConnectCallMethod(_connect,
                                  kIOHIDLibUserClientSetReport,
                                  input,
                                  3,
                                  report,
                                  reportLength,
                                  0,
                                  0,
                                  0,
                                  0);
    }
    
exit:
    return ret;
}

static IOReturn _getReport(void *iunknown,
                           IOHIDReportType reportType,
                           uint32_t reportID,
                           uint8_t *report,
                           CFIndex *pReportLength,
                           uint32_t timeout,
                           IOHIDReportCallback callback,
                           void *context,
                           IOOptionBits options)
{
    IUnknownVTbl *vtbl = *((IUnknownVTbl**)iunknown);
    IOHIDDeviceClass *me = (__bridge id)vtbl->_reserved;
    
    return [me getReport:reportType
                reportID:reportID
                  report:report
            reportLength:pReportLength
                 timeout:timeout
                callback:callback
                 context:context
                 options:options];
}

- (IOReturn)getReport:(IOHIDReportType)reportType
             reportID:(uint32_t)reportID
               report:(uint8_t *)report
         reportLength:(CFIndex *)pReportLength
              timeout:(uint32_t)timeout
             callback:(IOHIDReportCallback)callback
              context:(void *)context
              options:(IOOptionBits __unused)options
{
    IOReturn ret = kIOReturnError;
    uint64_t input[3] = { 0 };
    size_t reportLength = *pReportLength;
    
    if (!pReportLength || *pReportLength <= 0) {
        return kIOReturnBadArgument;
    }
    
    os_unfair_recursive_lock_lock(&_deviceLock);
    require_action(_opened, exit, {
        ret = kIOReturnNotOpen;
        os_unfair_recursive_lock_unlock(&_deviceLock);
    });
    os_unfair_recursive_lock_unlock(&_deviceLock);
    
    input[0] = reportType;
    input[1] = reportID;
    
    if (callback) {
        io_async_ref64_t asyncRef;
        AsyncReportContext *asyncContext;
        
        input[2] = timeout;
        
        asyncContext = (AsyncReportContext *)malloc(sizeof(AsyncReportContext));
        require(asyncContext, exit);
        
        asyncContext->type = reportType;
        asyncContext->buffer = (uint8_t *)report;
        asyncContext->reportID = reportID;
        asyncContext->callback = callback;
        asyncContext->context = context;
        asyncContext->sender = (__bridge void *)self;
        asyncContext->device = &_device;
        
        asyncRef[kIOAsyncCalloutFuncIndex] = (uint64_t)_asyncCallback;
        asyncRef[kIOAsyncCalloutRefconIndex] = (uint64_t)asyncContext;
        
        [self initPort];
        
        ret = IOConnectCallAsyncMethod(_connect,
                                       kIOHIDLibUserClientGetReport,
                                       _port,
                                       asyncRef,
                                       kIOAsyncCalloutCount,
                                       input,
                                       3,
                                       0,
                                       0,
                                       0,
                                       0,
                                       report,
                                       &reportLength);
        if (ret != kIOReturnSuccess) {
            free(asyncContext);
        }
    }
    else {
        ret = IOConnectCallMethod(_connect,
                                  kIOHIDLibUserClientGetReport,
                                  input,
                                  3,
                                  0,
                                  0,
                                  0,
                                  0,
                                  report,
                                  &reportLength);
    }
    
    *pReportLength = reportLength;
    
exit:
    return ret;
}

static IOReturn _setInputReportWithTimeStampCallback(void *iunknown,
                                    uint8_t *report,
                                    CFIndex reportLength,
                                    IOHIDReportWithTimeStampCallback callback,
                                    void *context,
                                    IOOptionBits options)
{
    IUnknownVTbl *vtbl = *((IUnknownVTbl**)iunknown);
    IOHIDDeviceClass *me = (__bridge id)vtbl->_reserved;
    
    return [me setInputReportWithTimeStampCallback:report
                                      reportLength:reportLength
                                          callback:callback
                                           context:context
                                           options:options];
}

- (IOReturn)setInputReportWithTimeStampCallback:(uint8_t *)report
                        reportLength:(CFIndex)reportLength
                            callback:(IOHIDReportWithTimeStampCallback)callback
                            context:(void *)context
                            options:(IOOptionBits __unused)options
{
    os_unfair_recursive_lock_lock(&_deviceLock);
    _inputReportBuffer = report;
    _inputReportBufferLength = reportLength;
    _inputReportContext = context;
    _inputReportTimestampCallback = callback;
    os_unfair_recursive_lock_unlock(&_deviceLock);

    [self initQueue];
    
    os_unfair_recursive_lock_lock(&_deviceLock);
    if (_opened) {
        [_queue start];
    }
    os_unfair_recursive_lock_unlock(&_deviceLock);
    return kIOReturnSuccess;
}

- (void)releaseReport:(uint64_t)reportAddress
{
    // Release report from kernel mapping.
    uint64_t inputs[] = {reportAddress};
    IOConnectCallScalarMethod(_connect,
                              kIOHIDLibUserClientReleaseReport,
                              inputs, 1,
                              NULL, NULL);
}

- (instancetype)init
{
    self = [super init];
    
    if (!self) {
        return nil;
    }
    
    _device = (IOHIDDeviceTimeStampedDeviceInterface *)malloc(sizeof(*_device));
    
    *_device = (IOHIDDeviceTimeStampedDeviceInterface) {
        // IUNKNOWN_C_GUTS
        ._reserved = (__bridge void *)self,
        .QueryInterface = self->_vtbl->QueryInterface,
        .AddRef = self->_vtbl->AddRef,
        .Release = self->_vtbl->Release,
        
        // IOHIDDeviceTimeStampedDeviceInterface
        .open = _open,
        .close = _close,
        .getProperty = _getProperty,
        .setProperty = _setProperty,
        .getAsyncEventSource = _getAsyncEventSource,
        .copyMatchingElements = _copyMatchingElements,
        .setValue = _setValue,
        .getValue = _getValue,
        .setInputReportCallback = _setInputReportCallback,
        .setReport = _setReport,
        .getReport = _getReport,
        .setInputReportWithTimeStampCallback = _setInputReportWithTimeStampCallback
    };
    
    _properties = [[NSMutableDictionary alloc] init];
    _deviceLock = OS_UNFAIR_RECURSIVE_LOCK_INIT;
    _callbackLock = OS_UNFAIR_RECURSIVE_LOCK_INIT;

    return self;
}

- (void)dealloc
{
    free(_device);

    if (_runLoopSource) {
        CFRelease(_runLoopSource);
    }
    
    if (_machPort) {
        CFMachPortInvalidate(_machPort);
        CFRelease(_machPort);
    }
    
    if (_port) {
        mach_port_mod_refs(mach_task_self(),
                           _port,
                           MACH_PORT_RIGHT_RECEIVE,
                           -1);
    }
    
    if (_connect) {
        IOServiceClose(_connect);
    }
    
    if (_service) {
        IOObjectRelease(_service);
    }
}

@end
