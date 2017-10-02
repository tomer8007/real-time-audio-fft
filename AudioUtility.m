//
//  AudioUtility.m
//  Equalizer
//
//  Created by Tomer Hadad on 3/8/14.
//  Copyright (c) 2014 Tomer Hadad. All rights reserved.
//

// AudioUtility.m: a bounch of low-level C functions for dealing with audio stored as float*
//                 using vDSP optimizations sometimes

#import "AudioUtility.h"
#import <AVFoundation/AVFoundation.h>
#import "AudioFile.h"
#import <Accelerate/Accelerate.h>
#import "TPCircularBuffer.h"
#include "dsp_centercut.h"

@implementation AudioUtility

BOOL AddStereoAudioToLiveStream(float *stereoSamples, int numSamplesToAddPerChannel, CircularAudioStorage *liveAudioData)
{
    float samples1[numSamplesToAddPerChannel], samples2[numSamplesToAddPerChannel];
    SplitStereoSamples(stereoSamples, numSamplesToAddPerChannel * 2, samples1, samples2);
    BOOL success1 = AddAudioToLiveStream(samples1, numSamplesToAddPerChannel, &liveAudioData->channel1);
    BOOL success2 = AddAudioToLiveStream(samples2, numSamplesToAddPerChannel, &liveAudioData->channel2);
    return success1 && success2;
}

BOOL AddAudioToLiveStream(float *samples, int numSamplesToAdd, CircularAudioStream *stream)
{
    CircularAudioStorage *liveAudioData = stream->fatherAudioData;
    
    UInt32 floatsNeededToStoreSamples = numSamplesToAdd;
    UInt32 floatsNeededToStoreFFTResults = numSamplesToAdd / liveAudioData->fftOverlapJumpSize * CHUNK_SIZE;
    
    // If there is no enough space to add the new audio, remove the oldest data (which must be already-played)
    if (!canAddToStream(stream, numSamplesToAdd)) return NO;
    PrepareAudioCircularBuffer(&stream->samples, floatsNeededToStoreSamples, numSamplesToAdd);
    PrepareAudioCircularBuffer(&stream->fftResults, floatsNeededToStoreFFTResults, numSamplesToAdd);
    
    // Actually processing and adding the audio
    
    float modifiedSamples[numSamplesToAdd];
    AmplitudeFactor(samples, numSamplesToAdd, liveAudioData->amplitudeFactor, modifiedSamples);

    for (int i=0;i<numSamplesToAdd / CHUNK_SIZE;i++)
        AddAudioChunkToBuffer(&stream->samples, &stream->fftResults, modifiedSamples + i * CHUNK_SIZE, CHUNK_SIZE, liveAudioData->fftOverlapJumpSize);
    
    return YES;
}

void AddAudioChunkToBuffer(AudioCircularBuffer *samplesBuffer, AudioCircularBuffer *fftResultsBuffer, float *newSamples, int chunkSize, int jumpSize)
{
    float fftResults[chunkSize];
    int chunkSizeInBytes = chunkSize * sizeof(float);
    if (samplesBuffer->circularBuffer.fillCount < chunkSizeInBytes)
    {
        AcceleratedFFT(newSamples, chunkSize, fftResults);
        TPCircularBufferProduceBytes(&fftResultsBuffer->circularBuffer, fftResults, chunkSizeInBytes);
        TPCircularBufferProduceBytes(&samplesBuffer->circularBuffer, newSamples, chunkSizeInBytes);
        return;
    }
    
    int availableBytes = 0;
    float *lastChunk = TPCircularBufferTail(&samplesBuffer->circularBuffer, &availableBytes) + availableBytes - chunkSizeInBytes;
    float mergedChunks[chunkSize * 2];
    memcpy(mergedChunks, lastChunk, chunkSizeInBytes);
    memcpy(mergedChunks + chunkSize, newSamples, chunkSizeInBytes);
    for (float *currentChunk = mergedChunks + jumpSize; currentChunk <= mergedChunks + chunkSize; currentChunk+=jumpSize)
    {
        AcceleratedFFT(currentChunk, chunkSize, fftResults);
        TPCircularBufferProduceBytes(&fftResultsBuffer->circularBuffer, fftResults, chunkSizeInBytes);
    }
    TPCircularBufferProduceBytes(&samplesBuffer->circularBuffer, newSamples, chunkSizeInBytes);
    
}

void CopySamples(float *samples, int numSamples, float *result)
{
    cblas_scopy(numSamples, samples, 1, result, 1);
}

void AmplitudeFactor(float *samples, UInt64 numSamples, float factor, float *result)
{
    if (factor == 1.0 && result == NULL) return;
    if (result == NULL) result = samples;
    vDSP_vsmul(samples, 1, &factor, result, 1, numSamples);
}

float AvaragePowerForSamples(float *samples, int numSamples)
{
    float result = 0;
    vDSP_measqv(samples, 1, &result, numSamples);
    return sqrt(result);
}

void Normalize(float *samples, int numSamples, float *result)
{
    float max = samples[0];
    for (int i=0;i<numSamples;i++)
    {
        if (samples[i] > max)
            max = samples[i];
    }
    
    float multiplier = 1.0 / max;
    if (max == 0) multiplier = 1;
    for (int i=0;i<numSamples;i++)
    {
        result[i] = samples[i] * multiplier;
    }
}

float MagnitudeToDb(float magnitude)
{
    return log10f(magnitude) * 20.0;
}

void LowPassFilter(float *samples, NSUInteger numSamples, float lpfBeta, float *result)
{
    return LowPassFilterWithInitializer(samples, numSamples, lpfBeta, samples[0], result);
}

void LowPassFilterWithInitializer(float *samples, NSUInteger numSamples, float lpfBeta, float initializer, float *result)
{
    // see https://kiritchatterjee.wordpress.com/2014/11/10/a-simple-digital-low-pass-filter-in-c/
    
    result[0] = initializer;
    for (int i=1;i<numSamples;i++)
    {
        result[i] = lpfBeta * samples[i] + (1-lpfBeta) * result[i-1];
    }
}

void PhaseCancellation(float *samples1, float* samples2, long numOfSamples, float *results)
{
    for (long i=0;i<numOfSamples;i++)
    {
        results[i] = samples1[i] * -1 + samples2[i];
    }
}

void SplitStereoSamples(float *samples, long samplesCount, float *leftChannnel, float *rightChannel)
{
    int numChannels = 2;
    float zero = 0.0;
    vDSP_vsadd(samples, numChannels, &zero, leftChannnel, 1, samplesCount/2);
    vDSP_vsadd(samples+1, numChannels, &zero, rightChannel, 1, samplesCount/2);
}

void CombineStereoSamples(float *leftChannel, float *rightChannel, float *result, long numSamplesPerChannel)
{
    int numChannels = 2;
    float zero = 0.0;
    vDSP_vsadd(leftChannel, 1, &zero, result, numChannels, numSamplesPerChannel);
    vDSP_vsadd(rightChannel, 1, &zero, result+1, numChannels, numSamplesPerChannel);
}

void Mix(float *samples1, float *samples2, float *result, UInt64 size)
{
    vDSP_vadd(samples1, 1, samples2, 1, result, 1, size);
}

int TimeToSampleTime(float seconds, int sampleRate)
{
    return sampleRate * (seconds);
}

float SampleTimeToSeconds(UInt64 sampleTime, int sampleRate)
{
    return (float)sampleTime / sampleRate;
}

int FFTBinToFrequency(int binIndex, int sampleRate, int chunkSize)
{
    return binIndex * sampleRate / chunkSize;
}

int FrequencyToBinIndex(int frequency, int sampleRate, int chunkSize)
{
    return frequency * chunkSize / (float)sampleRate;
}

// Takes some samples and a pointer to a two dimensional array in the form of arr[samplesCount / CHUNK_SIZE][CHUNK_SIZE]
// Fills the array with the FFT results (in magnitudes) divided to chunks of time.
// The frequencies can later be accessed as arr[chunkIndex][binIndex]
void Chunked_FFT(float *samples, long sampleCount, float *fftResults, int chunkSize)
{
    for (int i =0;i<sampleCount / chunkSize;i++)
    {
        float *currentChunk = &samples[i * chunkSize];
        float *chunkResult = &(fftResults[i*chunkSize]);
        AcceleratedFFT(currentChunk, chunkSize, chunkResult);
    }
}

void AcceleratedFFT(float *samples, int numSamples, float *result)
{
    static FFTSetup fftSetup = NULL;
    static int maxFFTSize = 0;
    
    vDSP_Length log2n = log2f(numSamples);
    
    if (fftSetup && maxFFTSize < numSamples)
    {
        vDSP_destroy_fftsetup(fftSetup);
        fftSetup = NULL;
    }
    
    if (fftSetup == NULL)
    {
        // Calculate the weights array. This is a one-off operation.
        fftSetup = vDSP_create_fftsetup(log2n, FFT_RADIX2);
        maxFFTSize = numSamples;
    }
    
    // For an FFT, numSamples must be a power of 2, i.e. is always even
    int nOver2 = numSamples/2;
    
    // Populate *window with the values for a hamming window function
    float windowed[numSamples];
    vDSP_hann_window(windowed, numSamples, 0);
    //vDSP_blkman_window(windowed, numSamples, 0);
    // Window the samples
    vDSP_vmul(windowed, 1, samples, 1, windowed, 1, numSamples);
    float realp[nOver2], imagp[nOver2];
    // Define complex buffer
    COMPLEX_SPLIT A;
    A.realp = (float *)realp;
    A.imagp = (float *)imagp;
    
    // Pack samples:
    // C(re) -> A[n], C(im) -> A[n+1]
    vDSP_ctoz((COMPLEX*)windowed, 2, &A, 1, numSamples/2);
    vDSP_fft_zrip(fftSetup, &A, 1, log2n, FFT_FORWARD);
    
    //Convert COMPLEX_SPLIT A result to magnitudes
    //result[0] = A.realp[0]/(numSamples*2);
    for(int i=0; i<numSamples; i++)
    {
        result[i]=(sqrtf(A.realp[i]*A.realp[i]+A.imagp[i]*A.imagp[i]));
    }
}

// call this function once in a program, before calling CenterCut()
void CenterCut_Init()
{
    Init_CenterCut();
}

bool CenterCut2(float *samples1, float *samples2, int numSamplesPerChannel, float *result, int sampleRate, bool outputCenter, bool bassToSides)
{
    float combined[numSamplesPerChannel*2];
    CombineStereoSamples(samples1, samples2, combined, numSamplesPerChannel);
    return CenterCut(combined, numSamplesPerChannel*2, result, sampleRate, outputCenter, bassToSides);
}

bool CenterCut(float *samples, int numSamples, float *result, int sampleRate, bool outputCenter, bool bassToSides)
{
    int numberOfTries = 10;
    int samplesProcessed = 0;
    while (--numberOfTries > 0 && samplesProcessed < numSamples)
    {
        samplesProcessed+= CenterCutProcessSamples((uint8 *)&samples[samplesProcessed], numSamples/2 - samplesProcessed/2, (uint8 *)&result[samplesProcessed], sizeof(float)*8, sampleRate, outputCenter, bassToSides)*2;
    }
    
    return numSamples == samplesProcessed;
}

void PrepareAudioCircularBuffer(AudioCircularBuffer *buffer, int floatsNeededToStoreData, int numSamples)
{
    if (!isThereEnoughPlaceToWrite(&buffer->circularBuffer, floatsNeededToStoreData * sizeof(float)))
    {
        TPCircularBufferConsume(&buffer->circularBuffer, floatsNeededToStoreData * sizeof(float));
        buffer->offset += numSamples;
    }
}

BOOL canAddToLiveAudioData(CircularAudioStorage *liveAudioData, int numSamples)
{
    return canAddToStream(&liveAudioData->channel1, numSamples) && canAddToStream(&liveAudioData->channel1, numSamples);
}

BOOL canAddToStream(CircularAudioStream *stream, int numSamples)
{
    CircularAudioStorage *fatherAudioData = stream->fatherAudioData;
    
    UInt32 floatsNeededToStoreSamples = numSamples;
    UInt32 floatsNeededToStoreFFTResults = numSamples / fatherAudioData->fftOverlapJumpSize * CHUNK_SIZE;
    
    UInt32 playingOffsetIntoSamplesBuffer = (UInt32)(fatherAudioData->currentlyPlayingFrame - stream->samples.offset);
    UInt32 playingOffsetIntoFFTBuffer = (UInt32)((fatherAudioData->currentlyPlayingFrame - stream->fftResults.offset) / fatherAudioData->fftOverlapJumpSize * CHUNK_SIZE);
    
    if (!isThereEnoughPlaceToWrite(&stream->samples.circularBuffer, floatsNeededToStoreSamples * sizeof(float)) && playingOffsetIntoSamplesBuffer < floatsNeededToStoreSamples) return NO;
    if (!isThereEnoughPlaceToWrite(&stream->fftResults.circularBuffer, floatsNeededToStoreFFTResults * sizeof(float)) && playingOffsetIntoFFTBuffer < floatsNeededToStoreFFTResults) return NO;
    
    return YES;
}

void LiveAudioDataEmpty(LiveAudioData *liveAudioData)
{
    LiveAudioChannelData* channels[] = {&liveAudioData->channel1, &liveAudioData->channel2 , &liveAudioData->extractedChannel};
    for (int i=0;i<3;i++)
    {
        LiveAudioChannelData *channel = channels[i];
        memset(channel->fftResults.data, 0, channel->fftResults.numChunksAvailable * CHUNK_SIZE * sizeof(float));
        memset(channel->samples.data, 0, channel->samples.numSamplesAvailable * sizeof(float));
        channel->containsData = NO;
    }
}

void AudioStreamSetBuffersOffset(CircularAudioStream *stream, int64_t offset)
{
    stream->fftResults.offset = offset;
    stream->samples.offset = offset;
}

void AudioStreamReset(CircularAudioStream *stream)
{
    stream->fftResults.offset = 0;
    stream->samples.offset = 0;
}

void AudioStreamInit(CircularAudioStream *stream, int samplesBufferSize, int fftResultsBufferSize, CircularAudioStorage *father)
{
    TPCircularBufferInit(&stream->samples.circularBuffer, samplesBufferSize);
    TPCircularBufferInit(&stream->fftResults.circularBuffer, fftResultsBufferSize);
    stream->fftResults.offset = 0;
    stream->samples.offset = 0;
    stream->fatherAudioData = father;
    AudioStreamReset(stream);
}

void LiveAudioDataReset(CircularAudioStorage *liveAudioData)
{
    liveAudioData->currentlyPlayingFrame = 0;
    liveAudioData->amplitudeFactor = 1.0;
    AudioStreamReset(&liveAudioData->channel1);
    AudioStreamReset(&liveAudioData->channel2);
    if (liveAudioData->fftOverlapJumpSize == 0) liveAudioData->fftOverlapJumpSize = CHUNK_SIZE;
}

@end
