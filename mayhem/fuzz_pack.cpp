// Fuzzes tools/adpenc's ADPCM encoder (adpcm_encode -> find_predict -> pack) on raw PCM bytes.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern "C" int adpcm_encode(FILE *fp, FILE *sad, int offset, int sample_len, int flag_loop, int bytes_per_sample);

// find_predict() and pack() keep their filter history in function-local statics. A block of 28 zero
// samples drives both histories back to exactly 0.0, so each input starts from the same state.
static void reset_encoder_history()
{
    static const unsigned char zeros[28 * 2] = {0};
    char *obuf = NULL;
    size_t olen = 0;
    FILE *in = fmemopen((void *)zeros, sizeof(zeros), "rb");
    FILE *out = open_memstream(&obuf, &olen);
    if (in && out)
        adpcm_encode(in, out, 0, 28, 0, 2);
    if (in)
        fclose(in);
    if (out)
        fclose(out);
    free(obuf);
}

// Byte 0: bit0 = 16-bit samples, bit1 = stereo (interleaved read, as tools/adpenc/src/main.c does), bit2 = loop flag.
extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size < 2)
        return -1;

    const int bytes_per_sample = (data[0] & 1) ? 2 : 1;
    const int channels = (data[0] & 2) ? 2 : 1;
    const int flag_loop = (data[0] >> 2) & 1;
    const uint8_t *pcm = data + 1;
    const size_t pcm_len = size - 1;
    const size_t frame = (size_t)bytes_per_sample * channels;
    const int sample_len = (int)(pcm_len / frame);
    if (sample_len == 0)
        return -1;

    reset_encoder_history();

    char *obuf = NULL;
    size_t olen = 0;
    FILE *in = fmemopen((void *)pcm, pcm_len, "rb");
    FILE *out = open_memstream(&obuf, &olen);
    if (in && out)
        adpcm_encode(in, out, channels == 2 ? bytes_per_sample : 0, sample_len, flag_loop, bytes_per_sample);
    if (in)
        fclose(in);
    if (out)
        fclose(out);
    free(obuf);
    return 0;
}
