/*
 * Android audio interface
 * OpenSLES audio driver for TaijiOS on Android
 */

#ifndef AUDIO_H
#define AUDIO_H

/*
 * Initialize the audio engine
 * Must be called before any other audio functions
 */
extern void	audio_init(void);

/*
 * Close the audio engine and release resources
 */
extern void	audio_close(void);

/*
 * Write audio samples to the audio output
 * addr: pointer to audio samples
 * n: number of samples to write
 * Returns: number of samples written, or -1 on error
 */
extern long	audio_write(void* addr, long n);

#endif /* AUDIO_H */
