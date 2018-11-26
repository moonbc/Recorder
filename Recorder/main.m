//
//  main.m
//  Recorder
//
//  Created by ByungChen Moon on 26/11/2018.
//  Copyright © 2018 ByungChen Moon. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

#define kNumberRecordBuffers    3

#pragma mark user data struct

//오디오 큐 콜백을 녹음하기 위한 사용자 정보 구조체
typedef struct  MyRecorder {
    AudioFileID recordFile;
    SInt64 recordPacket;
    Boolean running;
    
}MyRecorder;



#pragma mark utility functions
static void CheckError(OSStatus error, const char *operation)
{
    if(error == noErr) return;
    
    char errorString[20];
    //4 문자코드로 나타날때 확인
    *(UInt32 *)(errorString + 1) = CFSwapInt32HostToBig(error);
    if( isprint(errorString[1]) && isprint(errorString[2]) && isprint(errorString[3]) && isprint(errorString[4])) {
        errorString[0] = errorString[5] = '\'';
        errorString[6] = '\0';
        
    }else {
        //그렇지 않으면 정수로 취급
        sprintf(errorString, "%d", (int)error);
        fprintf(stderr, "Error: %s (%s) \n", operation, errorString);
        exit(1);
    }
    
}

//오디오 하드웨어 서비스에서 현재 오디오 입력 장치 얻기
OSStatus MyGetDefaultInputDeviceSampleRate(Float64 *outSampleRate)
{
    OSStatus error;
    AudioDeviceID deviceID = 0;
    
    AudioObjectPropertyAddress propertyAddress;
    UInt32 propertySize;
    propertyAddress.mSelector =kAudioHardwarePropertyDefaultInputDevice;
    propertyAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propertyAddress.mElement = 0;
    propertySize = sizeof(AudioDeviceID);
    error = AudioHardwareServiceGetPropertyData(kAudioObjectSystemObject, &propertyAddress, 0, NULL, &propertySize,  &deviceID);
    if(error) return error;
    
    propertyAddress.mSelector = kAudioDevicePropertyNominalSampleRate;
    propertyAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propertyAddress.mElement = 0;
    propertySize = sizeof(Float64);
    error = AudioHardwareServiceGetPropertyData(deviceID, &propertyAddress, 0, NULL,&propertySize,outSampleRate);
    
    return error;
}

//오디오 큐의 매직 쿠키를 오디오 파일에서 복사
static void MyCopyEncoderCookieToFile(AudioQueueRef queue, AudioFileID theFile)
{
    OSStatus error;
    UInt32 propertySize;
    error = AudioQueueGetPropertySize(queue, kAudioConverterCompressionMagicCookie, &propertySize);
    
    if(error == noErr && propertySize > 0)
    {
        Byte *magicCookie = (Byte *)malloc(propertySize);
        CheckError(AudioQueueGetProperty(queue, kAudioQueueProperty_MagicCookie, magicCookie, &propertySize), "Couldn't get audio queue's magic cookie");
        
        CheckError(AudioFileSetProperty(theFile, kAudioFilePropertyMagicCookieData, propertySize, magicCookie), "Couldn't set audio file's magic cookie");
        
        free(magicCookie);
    }
    
    
}
//ASBD를 위한 녹음 버퍼 크기 계산
static int MyComputeRecordBufferSize( const AudioStreamBasicDescription *format, AudioQueueRef queue, float seconds) {
    int packets, frames, bytes;
    frames = (int)ceil(seconds * format->mSampleRate);
    
    // 우선 각 버퍼에 몇개의 프로임(모든 채널에 하나의 샘플)이 있는 지 알 필요가 있다.
    
    if(format->mBytesPerFrame > 0)
        bytes = frames * format->mBytesPerFrame;
    else
    {
        UInt32 maxPacketSize;
        if(format->mBytesPerPacket  > 0)
            //고정된 패킷 크기
            maxPacketSize = format->mBytesPerPacket;
        else {
            //가능한 가장 큰 패킷 크기 획득
            UInt32 propertySize = sizeof(maxPacketSize);
            CheckError(AudioQueueGetProperty(queue, kAudioConverterPropertyMaximumOutputPacketSize, &maxPacketSize, &propertySize), "Couldn't get queue' smaximum output packet size");
        }
        if( format->mFramesPerPacket > 0)
            packets = frames / format->mFramesPerPacket;
        else
            //최악의 경우: 패킷에 하나의 프레임
            packets = frames;
        
        //오류 검사
        if(packets == 0)
            packets = 1;
        bytes = packets * maxPacketSize;
            
    }
    
    return bytes;
    
}


#pragma mark record callback function

static void MyAQInputCallback(void *inUserData, AudioQueueRef inQueue, AudioQueueBufferRef inBuffer,const AudioTimeStamp *inStartTime, UInt32 inNumPackets, const AudioStreamPacketDescription * inPacketDesc)
{
    MyRecorder *recorder = (MyRecorder *)inUserData;
    
    //캡쳐된 패킷을 오디오 파일에 작성
    if(inNumPackets > 0)
    {
        //패킷을 파일에 작성
        
        CheckError(AudioFileWritePackets(recorder->recordFile, FALSE, inBuffer->mAudioDataByteSize, inPacketDesc, recorder->recordPacket, &inNumPackets, inBuffer->mAudioData), "AudioFileWritePackets failed");
        
        //패킷 인덱스를 증가
        recorder->recordPacket += inNumPackets;
        
    }
    
    //사용된 버퍼를 다시 큐에 넣음
    if(recorder->running) {
        CheckError(AudioQueueEnqueueBuffer(inQueue, inBuffer, 0, NULL), "AudioQueueEnqueueBuffer failed");
    }
}

#pragma mark 주 함수
int main(int argc, const char * argv[]) {
    @autoreleasepool {
        //형식을 설정
        //
        
        //오디오 큐를 위해 MyRecorder 구조체와 ASBD를 생성
        MyRecorder recorder = {0};
        AudioStreamBasicDescription recordFormat;
        memset(&recordFormat, 0, sizeof(recordFormat));
        
        //오디오 큐를 위한 위한 ASBD의 형식 설정
        recordFormat.mFormatID = kAudioFormatMPEG4AAC;
        recordFormat.mChannelsPerFrame = 2; //스테레오 AAC
        
        
        //정확한 샘플율을 위한 함수
        MyGetDefaultInputDeviceSampleRate(&recordFormat.mSampleRate);
        
        UInt32 propSize = sizeof(recordFormat);
        
        //AudioFormatGetProperty()로 ASBD채우기
        CheckError(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, NULL, &propSize, &recordFormat), "AudioFormatGetProperty failed");
        
        //큐를 설정
        //입력을 위한 새로운 오디오 큐 생성
        AudioQueueRef queue = {0};
        CheckError(AudioQueueNewInput(&recordFormat, MyAQInputCallback, &recorder, NULL, NULL, 0, &queue), "AudioQueueNewInput Failed");
        
        //오디오 큐에서 채워진 ASBD를 추출
        UInt32 size = sizeof(recordFormat);
        CheckError(AudioQueueGetProperty(queue, kAudioConverterCurrentOutputStreamDescription, &recordFormat, &size), "Couldn't get queue's format");
        
        //파일을 설정
        //출력을 위한 오디오 파일 생성
        CFURLRef myFileURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, CFSTR("output.caf"), kCFURLPOSIXPathStyle, false);
        
        CheckError(AudioFileCreateWithURL(myFileURL, kAudioFileCAFType,&recordFormat,  kAudioFileFlags_EraseFile, &recorder.recordFile), "AudioFileCreateWithURL failed");
        
        CFRelease(myFileURL);
        
        //매직쿠키를 처리하는 편의 함수 호출
        MyCopyEncoderCookieToFile(queue, recorder.recordFile);
      
        //필요한 다른 설정
        //녹음 버퍼 크기를 계산하기 위한 편의 함수 호출
        int bufferByteSize = MyComputeRecordBufferSize(&recordFormat, queue, 0.5);
        
        //버퍼 할당과 큐에 삽입
        int bufferIndex;
        for( bufferIndex = 0; bufferIndex < kNumberRecordBuffers; ++ bufferIndex)
        {
            AudioQueueBufferRef buffer;
            CheckError(AudioQueueAllocateBuffer(queue, bufferByteSize, &buffer), "AudioQueueAllocateBuffer failed");
            
            CheckError(AudioQueueEnqueueBuffer(queue, buffer, 0, NULL), "AudioQueueEnqueueBuffer failed");
        }
        //큐를 시작
        recorder.running = TRUE;
        CheckError(AudioQueueStart(queue, NULL), "AudioQueueStart failed");
        
        printf("Recording, press <return> to stop:\n");
        getchar();
        
        
        //큐를 중지
        printf("* recording done *\n");
        recorder.running = FALSE;
        
        CheckError(AudioQueueStop(queue, TRUE), "AudioQueueStop failed");
        
        
        //매직 쿠키 편의 함수를 재호출
        MyCopyEncoderCookieToFile(queue, recorder.recordFile);
        
        
        //오디오 큐와 오디오 파일을 해제
        AudioQueueDispose(queue, TRUE);
        AudioFileClose(recorder.recordFile);

        
    }
    return 0;
}
