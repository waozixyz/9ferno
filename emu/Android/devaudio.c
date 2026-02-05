/*
 * Android audio driver using OpenSLES
 * Ported from Linux OSS audio to OpenSLES for Android
 */

#include <SLES/OpenSLES.h>
#include <SLES/OpenSLES_Android.h>
#include <android/log.h>

#include "dat.h"
#include "fns.h"
#include "error.h"
#include "audio.h"

#define LOG_TAG "TaijiOS-Audio"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/*
 * Audio engine state
 */
static struct {
	SLObjectItf engineObject;
	SLEngineItf engine;
	SLObjectItf outputMixObject;
	SLObjectItf playerObject;
	SLPlayItf player;
	SLBufferQueueItf bufferQueue;

	int initialized;
	int playing;
	int sampleRate;
	int channels;
	int bufferSize;
	uchar* buffer;
} audio = {0};

/*
 * Default audio configuration
 */
#define DEFAULT_SAMPLE_RATE	44100
#define DEFAULT_CHANNELS	2
#define DEFAULT_BUFFER_SIZE	8192

/*
 * Buffer queue callback
 */
static void
buffer_queue_callback(SLBufferQueueItf bq, void* context)
{
	USED(bq);
	USED(context);
	/* Signal that buffer is ready for more data */
}

/*
 * Initialize audio engine
 */
void
audio_init(void)
{
	SLresult result;

	if(audio.initialized)
		return;

	/* Create engine */
	result = slCreateEngine(&audio.engineObject, 0, NULL, 0, NULL, NULL);
	if(result != SL_RESULT_SUCCESS) {
		LOGE("slCreateEngine failed");
		return;
	}

	/* Realize the engine */
	result = (*audio.engineObject)->Realize(audio.engineObject, SL_BOOLEAN_FALSE);
	if(result != SL_RESULT_SUCCESS) {
		LOGE("Engine Realize failed");
		return;
	}

	/* Get the engine interface */
	result = (*audio.engineObject)->GetInterface(audio.engineObject, SL_IID_ENGINE, &audio.engine);
	if(result != SL_RESULT_SUCCESS) {
		LOGE("Engine GetInterface failed");
		return;
	}

	/* Create output mix */
	result = (*audio.engine)->CreateOutputMix(audio.engine, &audio.outputMixObject, 0, NULL, NULL);
	if(result != SL_RESULT_SUCCESS) {
		LOGE("CreateOutputMix failed");
		return;
	}

	/* Realize the output mix */
	result = (*audio.outputMixObject)->Realize(audio.outputMixObject, SL_BOOLEAN_FALSE);
	if(result != SL_RESULT_SUCCESS) {
		LOGE("OutputMix Realize failed");
		return;
	}

	audio.sampleRate = DEFAULT_SAMPLE_RATE;
	audio.channels = DEFAULT_CHANNELS;
	audio.bufferSize = DEFAULT_BUFFER_SIZE;
	audio.buffer = malloc(audio.bufferSize);

	if(audio.buffer == nil) {
		LOGE("Failed to allocate audio buffer");
		return;
	}

	audio.initialized = 1;
	LOGI("Audio initialized: %d Hz, %d channels", audio.sampleRate, audio.channels);
}

/*
 * Create audio player
 */
static int
create_player(void)
{
	SLDataLocator_AndroidSimpleBufferQueue loc_bufq = {
		.locatorType = SL_DATALOCATOR_ANDROIDSIMPLEBUFFERQUEUE,
		.numBuffers = 2
	};

	/* Configure PCM format */
	SLDataFormat_PCM format_pcm = {
		.formatType = SL_DATAFORMAT_PCM,
		.numChannels = audio.channels,
		.samplesPerSec = audio.sampleRate * 1000,
		.bitsPerSample = SL_PCMSAMPLEFORMAT_FIXED_16,
		.containerSize = 16,
		.channelMask = SL_SPEAKER_FRONT_LEFT | SL_SPEAKER_FRONT_RIGHT,
		.endianness = SL_BYTEORDER_LITTLEENDIAN
	};

	SLDataSource audioSrc = {&loc_bufq, &format_pcm};

	SLDataLocator_OutputMix loc_outmix = {
		.locatorType = SL_DATALOCATOR_OUTPUTMIX,
		.outputMix = audio.outputMixObject
	};

	SLDataSink audioSnk = {&loc_outmix, NULL};

	const SLInterfaceID ids[1] = {SL_IID_BUFFERQUEUE};
	const SLboolean req[1] = {SL_BOOLEAN_TRUE};

	SLresult result = (*audio.engine)->CreateAudioPlayer(audio.engine,
		&audio.playerObject, &audioSrc, &audioSnk,
		1, ids, req);

	if(result != SL_RESULT_SUCCESS) {
		LOGE("CreateAudioPlayer failed");
		return -1;
	}

	/* Realize the player */
	result = (*audio.playerObject)->Realize(audio.playerObject, SL_BOOLEAN_FALSE);
	if(result != SL_RESULT_SUCCESS) {
		LOGE("Player Realize failed");
		return -1;
	}

	/* Get the play interface */
	result = (*audio.playerObject)->GetInterface(audio.playerObject, SL_IID_PLAY, &audio.player);
	if(result != SL_RESULT_SUCCESS) {
		LOGE("Player GetInterface failed");
		return -1;
	}

	/* Get the buffer queue interface */
	result = (*audio.playerObject)->GetInterface(audio.playerObject, SL_IID_BUFFERQUEUE, &audio.bufferQueue);
	if(result != SL_RESULT_SUCCESS) {
		LOGE("BufferQueue GetInterface failed");
		return -1;
	}

	/* Register callback */
	result = (*audio.bufferQueue)->RegisterCallback(audio.bufferQueue, buffer_queue_callback, NULL);
	if(result != SL_RESULT_SUCCESS) {
		LOGE("RegisterCallback failed");
		return -1;
	}

	return 0;
}

/*
 * Write audio data
 */
long
audio_write(void* addr, long n)
{
	SLresult result;
	short* samples = addr;
	int i, nsamples;

	if(!audio.initialized)
		audio_init();

	if(audio.playerObject == nil) {
		if(create_player() < 0)
			return -1;
	}

	/* Convert to 16-bit PCM */
	nsamples = n / audio.channels;
	for(i = 0; i < nsamples; i++) {
		/* Assume input is 8-bit unsigned, convert to 16-bit signed */
		((short*)audio.buffer)[i] = ((uchar*)samples)[i] * 256 - 32768;
	}

	/* Enqueue buffer */
	result = (*audio.bufferQueue)->Enqueue(audio.bufferQueue, audio.buffer, nsamples * 2);
	if(result != SL_RESULT_SUCCESS) {
		LOGE("Enqueue failed");
		return -1;
	}

	/* Start playback if not already playing */
	if(!audio.playing) {
		result = (*audio.player)->SetPlayState(audio.player, SL_PLAYSTATE_PLAYING);
		if(result == SL_RESULT_SUCCESS) {
			audio.playing = 1;
		}
	}

	return n;
}

/*
 * Close audio
 */
void
audio_close(void)
{
	if(audio.playerObject != nil) {
		(*audio.playerObject)->Destroy(audio.playerObject);
		audio.playerObject = nil;
	}

	if(audio.outputMixObject != nil) {
		(*audio.outputMixObject)->Destroy(audio.outputMixObject);
		audio.outputMixObject = nil;
	}

	if(audio.engineObject != nil) {
		(*audio.engineObject)->Destroy(audio.engineObject);
		audio.engineObject = nil;
	}

	if(audio.buffer != nil) {
		free(audio.buffer);
		audio.buffer = nil;
	}

	audio.initialized = 0;
	audio.playing = 0;
}
