//
//  AudioUtility.h
//  Equalizer
//
//  Created by Tomer Hadad on 3/8/14.
//  Copyright (c) 2014 Tomer Hadad. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AudioToolbox/AudioToolbox.h>
#import "Configuration.h"

@class MPMediaItem;
@class AVAssetReader;
@class AVAssetReaderTrackOutput;
@class AudioFile;

@interface AudioUtility : NSObject

#define CHUNK_SIZE 2048
#define CHUNK_SIZE_FOR_RECORDING 2048
#define FFT_BUFFER_DEFINE float[BUFFER_SIZE / CHUNK_SIZE][CHUNK_SIZE]

#define MAX_FFT_LEN(sampleCount) (sampleCount / CHUNK_SIZE * CHUNK_SIZE)

typedef struct CircularAudioStorage CircularAudioStorage;

typedef struct AudioCircularBuffer
{
    TPCircularBuffer circularBuffer;
    SInt64 offset;
} AudioCircularBuffer;

typedef struct CircularAudioStream
{
    CircularAudioStorage *fatherAudioData;
    AudioCircularBuffer samples;
    AudioCircularBuffer fftResults;
    
} CircularAudioStream;

struct CircularAudioStorage
{
    SInt64 currentlyPlayingFrame;
    SInt32 fftOverlapJumpSize;
    CGFloat amplitudeFactor;
    
    CircularAudioStream channel1;
    CircularAudioStream channel2;
    CircularAudioStream extractedChannel;
};

typedef struct LiveSamples
{
    SInt64 timeInFrames;
    float *data;
    unsigned long numSamplesAvailable;
    
} LiveSamples;

typedef struct LiveFFTResults
{
    SInt64 timeInFrames;
    float *data;
    unsigned long numChunksAvailable;
} LiveFFTResults;

typedef struct LiveAudioChannelData
{
    BOOL containsData;
    LiveSamples samples;
    LiveFFTResults fftResults;
} LiveAudioChannelData;

typedef struct LiveAudioData
{
    SInt64 timeInFrames;
    LiveAudioChannelData channel1;
    LiveAudioChannelData channel2;
    LiveAudioChannelData extractedChannel;

} LiveAudioData;

typedef struct LiveMicrophoneData
{
    float samples1[CHUNK_SIZE_FOR_RECORDING];
    float samples2[CHUNK_SIZE_FOR_RECORDING];
    float fftResults1[CHUNK_SIZE_FOR_RECORDING / CHUNK_SIZE_FOR_RECORDING][CHUNK_SIZE_FOR_RECORDING];
    float fftResults2[CHUNK_SIZE_FOR_RECORDING / CHUNK_SIZE_FOR_RECORDING][CHUNK_SIZE_FOR_RECORDING];
    
} LiveMicrophoneData;


#if defined __cplusplus
extern "C" {
#endif
    
void AudioStreamSetBuffersOffset(CircularAudioStream *stream, int64_t offset);
void AudioStreamReset(CircularAudioStream *stream);
void AudioStreamInit(CircularAudioStream *stream, int samplesBufferSize, int fftResultsBufferSize, CircularAudioStorage *father);
void LiveAudioDataReset(CircularAudioStorage *liveAudioData);
    
void SplitStereoSamples(float *samples, long samplesCount, float *leftChannnel, float *rightChannel);
void CombineStereoSamples(float *leftChannel, float *rightChannel, float *result, long numSamplesPerChannel);

void CopySamples(float *samples, int numSamples, float *result);
void AmplitudeFactor(float *samples, UInt64 numSamples, float factor, float *result);
void Chunked_FFT(float *samples, long samplesCount, float *fftResults, int chunkSize);
void PhaseCancellation(float *samples1, float* samples2, long numOfSamples, float *results);
void Normalize(float *samples, int numSamples, float *result);
float AvaragePowerForSamples(float *samples, int numSamples);
float MagnitudeToDb(float magnitude);
void Mix(float *samples1, float *samples2, float *result, UInt64 size);
    
void CenterCut_Init();
bool CenterCut(float *samples, int numSamples, float *result, int sampleRate, bool outputCenter, bool bassToSides);
bool CenterCut2(float *samples1, float *samples2, int numSamplesPerChannel, float *result, int sampleRate, bool outputCenter, bool bassToSides);

int FindPeaks(float *data, int size, int *peak_list, int *peak_list_size);
void LowPassFilter(float *samples, NSUInteger numSamples, float lpfBeta, float *result);
void LowPassFilterWithInitializer(float *samples, NSUInteger numSamples, float lpfBeta, float initializer, float *result);
void LowPassFilterWithOffset(float *samples, NSUInteger offset, NSUInteger numSamples, float lpfBeta, float *result);

int FFTBinToFrequency(int binIndex, int sampleRate, int chunkSize);
int FrequencyToBinIndex(int frequency, int sampleRate, int chunkSize);
int TimeToSampleTime(float seconds, int sampleRate);
float SampleTimeToSeconds(UInt64 sampleTime, int sampleRate);

void LiveAudioDataEmpty(LiveAudioData *liveAudioData);
BOOL AddStereoAudioToLiveStream(float *stereoSamples, int numSamplesToAddPerChannel, CircularAudioStorage *liveAudioData);
BOOL AddAudioToLiveStream(float *samples, int numSamplesToAdd, CircularAudioStream *stream);
BOOL canAddToLiveAudioData(CircularAudioStorage *liveAudioData, int numSamples);
BOOL canAddToStream(CircularAudioStream *stream, int numSamples);
    
#if defined __cplusplus
};
#endif


@end

enum AudioSupplyMode { AudioSupplyMode_NotSupplying = 0, AudioSupplyMode_Regular = 1, AudioSupplyMode_Secondary = 2 };

@protocol LiveAudioSupplier <NSObject>

@property(readonly) LiveAudioData liveAudioData;
@property(readonly) enum AudioSupplyMode audioSupplyMode;

@optional
@property CGFloat amplitudeFactor;
- (LiveAudioChannelData)getLiveAudioDataForChannel:(UInt32)channelID;
- (LiveAudioChannelData)getLiveAudioDataForFrame:(SInt64)frameOffset andChannel:(UInt32)channelID;

@end

@protocol LiveAudioVisualizer <NSObject>

@property id<LiveAudioSupplier> activeAudioSupplier;

@end


