//
//  Configuration.h
//  Equalizer
//
//  Created by Tomer Hadad on 4/19/14.
//  Copyright (c) 2014 Tomer Hadad. All rights reserved.
//

#import "TPCircularBuffer.h"
#include <mach/mach_time.h>

#define TRACK_FRAME_RATE 0

#define IS_SIMULATOR TARGET_IPHONE_SIMULATOR

#define TICK uint64_t startTime = mach_absolute_time()
#define TOCK(operation) NSLog(@"%@ took %f ms.",(operation),machToMiliseconds(mach_absolute_time() - startTime));
#define _TICK startTime = mach_absolute_time()
#define _TOCK TOCK

#if defined __cplusplus
extern "C" {
#endif
    
double machToMiliseconds(signed long long machTime);
bool isThereEnoughPlaceToWrite(TPCircularBuffer *buffer, int bytes);
void AppendToCircularBuffer(TPCircularBuffer *buffer, void *data, int dataSizeInBytes);
bool AppendToCircularBufferWithoutOverwriting(TPCircularBuffer *buffer, void *data, int dataSizeInBytes, int protectionOffsetIntoBuffer);
    
#if defined __cplusplus
};
#endif
