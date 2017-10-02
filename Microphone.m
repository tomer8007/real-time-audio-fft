//
//  AudioFile.m
//  Equalizer
//
//  Created by Tomer Hadad on 4/19/14.
//  Copyright (c) 2014 Tomer Hadad. All rights reserved.
//

#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AudioToolbox/AudioToolbox.h>
#import "Configuration.h"
#import "Microphone.h"
#import "AppDelegate.h"

#define USE_REALTIME_EFFECTS 0

@implementation Microphone
{
    AudioQueueTimelineRef timeline;
    TPCircularBuffer circularBuffer1;
    TPCircularBuffer circularBuffer2;
}

- (id)init
{
    self = [self initWithAudioController:[Microphone sharedPlayAndRecordAudioController]];
    return self;
}

-(id)initWithAudioController:(AEAudioController *)audioController
{
    self = [Microphone alloc];
    _refToSelf = self;
    
    self.audioController = audioController;
    self.amplitudeFactor = 1.0f;
    
    syncQueue = dispatch_queue_create("microphoneDataQueue", DISPATCH_QUEUE_SERIAL);
    
    self.audioFormat = self.audioController.inputAudioDescription;
    self.numOfChannels = self.audioController.numberOfInputChannels;
    
    TPCircularBufferInit(&circularBuffer1, CHUNK_SIZE_FOR_RECORDING * 4 * sizeof(float));
    TPCircularBufferInit(&circularBuffer2, CHUNK_SIZE_FOR_RECORDING * 4 * sizeof(float));
    
    return self;
    
}

+ (AEAudioController *)sharedPlayAndRecordAudioController
{
    static AEAudioController *controller = nil;
    if (controller == nil)
    {
        controller = [[AEAudioController alloc] initWithAudioDescription:[AEAudioController nonInterleavedFloatStereoAudioDescription] inputEnabled:YES];
        controller.useMeasurementMode = YES;
        controller.automaticLatencyManagement = YES;
        //self.playAndRecordyAudioController.inputGain = 1.0f;
        controller.preferredBufferDuration = 512.0/44100.0;
    }
    return controller;
}

id _refToSelf = NULL;

double previousCallbackTime = 0;
int counter = 0;

uint64_t micGenTime = 0;

static void receiverCallback(id receiver, AEAudioController *audioController, void *source, const AudioTimeStamp *time, UInt32 frames, AudioBufferList *audio)
{
    // TODO: support for more than one channel
    micGenTime = time->mHostTime;
    __unsafe_unretained Microphone *microphone = (Microphone*)receiver;
    
    // Adding the received audio to the toProcess buffers. If the buffer is full, overwrite from the beginning
    AppendToCircularBuffer(&microphone->circularBuffer1, audio->mBuffers[0].mData, frames * sizeof(float));
    AppendToCircularBuffer(&microphone->circularBuffer2, audio->mBuffers[1].mData, frames * sizeof(float));
    dispatch_async(microphone->syncQueue, ^
    {
        processLiveAudio();
    });
    
    // TOOD: make sure those oporations are performed serially. for example, it must not be possible that
    // two instances of processLiveAudio() will run concurrency. (Or, that two instances of this function, if somehow this inputReceiver is added multiple times to the audio controller)
}

void processLiveAudio()
{
    static BOOL isProcessingAudio = NO;
    while (isProcessingAudio) {}
    isProcessingAudio = YES;
    
    __unsafe_unretained Microphone *THIS = (Microphone *)_refToSelf;
    
    // Processing only the last CHUNK_SIZE_FOR_RECORDING samples in the circular buffer
    
    if (THIS->circularBuffer1.fillCount >= CHUNK_SIZE_FOR_RECORDING * sizeof(float))
    {
        int avaliableBytes = 0;
        float *samples = (float *)TPCircularBufferTail(&THIS->circularBuffer1, &avaliableBytes) + THIS->circularBuffer1.fillCount / sizeof(float) - CHUNK_SIZE_FOR_RECORDING;
        AmplitudeFactor(samples, CHUNK_SIZE_FOR_RECORDING, THIS->_amplitudeFactor, THIS->liveMicrophoneData.samples1);
        
        // FFting
        Chunked_FFT(THIS->liveMicrophoneData.samples1, CHUNK_SIZE_FOR_RECORDING, (float *)THIS->liveMicrophoneData.fftResults1, CHUNK_SIZE_FOR_RECORDING);
    }
    
    if (THIS->_audioController.numberOfInputChannels == 1)
    {
        memcpy(THIS->liveMicrophoneData.samples2, THIS->liveMicrophoneData.samples1, CHUNK_SIZE_FOR_RECORDING * sizeof(float));
        memcpy(THIS->liveMicrophoneData.fftResults2, THIS->liveMicrophoneData.fftResults1, CHUNK_SIZE_FOR_RECORDING * sizeof(float));
    }
    else if (THIS->circularBuffer2.fillCount >= CHUNK_SIZE_FOR_RECORDING * sizeof(float))
    {
        int avaliableBytes = 0;
        float *samples = (float *)TPCircularBufferTail(&THIS->circularBuffer2, &avaliableBytes) + THIS->circularBuffer2.fillCount / sizeof(float) - CHUNK_SIZE_FOR_RECORDING;;
        AmplitudeFactor(samples, CHUNK_SIZE_FOR_RECORDING, THIS->_amplitudeFactor, THIS->liveMicrophoneData.samples2);
        
        // FFting
        Chunked_FFT(THIS->liveMicrophoneData.samples2, CHUNK_SIZE_FOR_RECORDING, (float *)THIS->liveMicrophoneData.fftResults2, CHUNK_SIZE_FOR_RECORDING);
    }
    isProcessingAudio = NO;

}

-(AEAudioControllerAudioCallback)receiverCallback
{
    return receiverCallback;
}

-(NSError *)resumeRecording
{
    return [self startRecording];
}

-(NSError *)startRecording
{
    NSError *error;
    if (!self.audioController.running) [self.audioController start:&error]; if (error) return error;
    if (self.isRecording || [self.audioController.inputReceivers containsObject:self]) return nil;
    [self.audioController addInputReceiver:self];
    self.isRecording = YES;
    
    return nil;
}

-(NSError *)stopRecording
{
    if (!self.isRecording || !self.audioController.running) return nil;
    
    [self.audioController removeInputReceiver:self];
    [self.audioController stop];
    self.isRecording = NO;
    
    return nil;
}

- (LiveAudioData)liveAudioData
{
    LiveAudioData audioData;
    audioData.timeInFrames = 0; // TODO: provide true frame time
    audioData.channel1 = [self getAudioDataForChannelID:1];
    audioData.channel2 = [self getAudioDataForChannelID:2];
    
    return audioData;
}

- (LiveAudioChannelData)getAudioDataForChannelID:(UInt32)channelID
{
    LiveAudioChannelData audioData;
    
    float *samples = channelID == 2 && self.audioFormat.mChannelsPerFrame == 2 ? liveMicrophoneData.samples2 : liveMicrophoneData.samples1;
    float *fftResults = (float *)(channelID == 2 && self.audioFormat.mChannelsPerFrame == 2 ? liveMicrophoneData.fftResults2 : liveMicrophoneData.fftResults1);
    
    LiveSamples liveSamples = (LiveSamples){0, samples, CHUNK_SIZE_FOR_RECORDING};
    LiveFFTResults liveFFTResults = (LiveFFTResults) {0,fftResults, 1};
    
    audioData.containsData = YES;
    audioData.samples = liveSamples;
    audioData.fftResults = liveFFTResults;
    
    return audioData;
}

- (enum AudioSupplyMode)audioSupplyMode
{
    if (!self.isRecording) return AudioSupplyMode_NotSupplying;
    
    return AudioSupplyMode_Regular;
}

/*
 - (void)processLiveAudio
 {
 // TODO: do this on another thread to improve render times
 //__unsafe_unretained Microphone *THIS = (Microphone *)_refToSelf;
 
 if (circularBuffer1.fillCount >= CHUNK_SIZE_FOR_RECORDING * sizeof(float))
 {
 // Processing only the last CHUNK_SIZE_FOR_RECORDING samples in the circular buffer
 
 int avaliableBytes = 0;
 float *samples = (float *)TPCircularBufferTail(&circularBuffer1, &avaliableBytes) + circularBuffer1.fillCount / sizeof(float) - CHUNK_SIZE_FOR_RECORDING;
 memcpy((void *)liveMicrophoneData.samples1, (void *)samples, CHUNK_SIZE_FOR_RECORDING * sizeof(float));
 
 // FFting
 Chunked_FFT(liveMicrophoneData.samples1, CHUNK_SIZE_FOR_RECORDING, (float *)liveMicrophoneData.fftResults1, CHUNK_SIZE_FOR_RECORDING);
 }
 
 if (circularBuffer2.fillCount >= CHUNK_SIZE_FOR_RECORDING * sizeof(float))
 {
 // Processing only the last CHUNK_SIZE_FOR_RECORDING samples in the circular buffer
 
 int avaliableBytes = 0;
 float *samples = (float *)TPCircularBufferTail(&circularBuffer2, &avaliableBytes) + circularBuffer2.fillCount / sizeof(float) - CHUNK_SIZE_FOR_RECORDING;;
 memcpy((void *)liveMicrophoneData.samples2, (void *)samples, CHUNK_SIZE_FOR_RECORDING * sizeof(float));
 
 // FFting
 Chunked_FFT(liveMicrophoneData.samples2, CHUNK_SIZE_FOR_RECORDING, (float *)liveMicrophoneData.fftResults2, CHUNK_SIZE_FOR_RECORDING);
 }
 }
 */


@end
