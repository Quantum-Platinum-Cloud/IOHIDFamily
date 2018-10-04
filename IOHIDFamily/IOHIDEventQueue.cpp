/*
 * @APPLE_LICENSE_HEADER_START@
 * 
 * Copyright (c) 1999-2003 Apple Computer, Inc.  All Rights Reserved.
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

#include <IOKit/system.h>
#include <IOKit/IOLib.h>
#include <IOKit/IODataQueueShared.h>
#include "IOHIDEventQueue.h"
    
#define super IOSharedDataQueue
OSDefineMetaClassAndStructors(IOHIDEventQueue, super)

IOHIDEventQueue *IOHIDEventQueue::withCapacity(UInt32 size)
{
    IOHIDEventQueue *queue = new IOHIDEventQueue;
    
    if (queue && !queue->initWithCapacity(size)) {
        queue->release();
        queue = 0;
    }
    
    return queue;
}

IOHIDEventQueue *IOHIDEventQueue::withEntries(UInt32 numEntries, UInt32 entrySize)
{
    IOHIDEventQueue *queue = NULL;
    UInt32 size = numEntries * entrySize;
    
    if (numEntries > UINT32_MAX / entrySize) {
        return NULL;
    }

    if (size < HID_QUEUE_CAPACITY_MIN) {
        size = HID_QUEUE_CAPACITY_MIN;
    }
    
    if (size > HID_QUEUE_CAPACITY_MAX_ENTITLED) {
        size = HID_QUEUE_CAPACITY_MAX_ENTITLED;
    }
    
    queue = IOHIDEventQueue::withCapacity(size);
    if (queue) {
        queue->_numEntries = numEntries;
        queue->_entrySize = entrySize;
    }
    
    return queue;
}

Boolean IOHIDEventQueue::enqueue(void *data, UInt32 dataSize)
{
    Boolean ret = true;
    
    // if we are not started, then dont enqueue
    // for now, return true, since we dont wish to push an error back
    if ((_state & (kHIDQueueStarted | kHIDQueueDisabled)) == kHIDQueueStarted) {
        ret = super::enqueue(data, dataSize);
        if (!ret) {
            _enqueueErrorCount++;
            //Send notification for queue full
            sendDataAvailableNotification();
        }
    }
    
    return ret;
}

bool IOHIDEventQueue::serialize(OSSerialize * serializer) const
{
    bool ret = false;
    
    if (serializer->previouslySerialized(this)) {
        return true;
    }
    
    OSDictionary *dict = OSDictionary::withCapacity(2);
    if (dict) {
        OSNumber *num = OSNumber::withNumber(dataQueue->head, 32);
        if (num) {
            dict->setObject("head", num);
            num->release();
        }
        num = OSNumber::withNumber(dataQueue->tail, 32);
        if (num) {
            dict->setObject("tail", num);
            num->release();
        }
        num = OSNumber::withNumber(_enqueueErrorCount, 64);
        if (num) {
            dict->setObject("EnqueueErrorCount", num);
            num->release();
        }
        num = OSNumber::withNumber(_reserved->queueSize, 64);
        if (num) {
            dict->setObject("QueueSize", num);
            num->release();
        }
        num = OSNumber::withNumber(_numEntries, 64);
        if (num) {
            dict->setObject("numEntries", num);
            num->release();
        }
        num = OSNumber::withNumber(_entrySize, 64);
        if (num) {
            dict->setObject("entrySize", num);
            num->release();
        }
        ret = dict->serialize(serializer);
        dict->release();
    }
    
    return ret;
}
