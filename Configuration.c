//
//  Configuration.cpp
//  Equalizer
//
//  Created by Tomer Hadad on 8/11/15.
//  Copyright (c) 2015 Tomer Hadad. All rights reserved.
//

#include "Configuration.h"
//#include <stdio.h>

typedef struct _ccVertex2F
{
    float x;
    float y;
} ccVertex2F;

inline double machToMiliseconds(signed long long machTime)
{
    mach_timebase_info_data_t timeBaseInfo;
    mach_timebase_info(&timeBaseInfo);
    double miliseconds = machTime  * timeBaseInfo.numer / timeBaseInfo.denom / 1000000.0;
    return miliseconds;
}

inline bool isThereEnoughPlaceToWrite(TPCircularBuffer *buffer, int bytes)
{
    return buffer->length - buffer->fillCount >= bytes;
}

void AppendToCircularBuffer(TPCircularBuffer *buffer, void *data, int dataSizeInBytes)
{
    if (!isThereEnoughPlaceToWrite(buffer, dataSizeInBytes))
    {
        TPCircularBufferConsume(buffer, dataSizeInBytes);
    }
    TPCircularBufferProduceBytes(buffer, data, dataSizeInBytes);
}

void makeRectangle(float x, float y, float width, float height, ccVertex2F points[4])
{
    //y = y - self.contentSize.height/2;
    //x = roundf(x); y = roundf(y); width = roundf(width); height = roundf(height);
    
    points[0] = (ccVertex2F){x, y+height};       // top left
    points[1] = (ccVertex2F){x+width, y+height}; // top right
    points[2] = (ccVertex2F){x+width, y};        // right botton
    points[3] = (ccVertex2F){x, y};              // left botton
}