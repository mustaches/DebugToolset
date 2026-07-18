/*******************************************************************************
 * fft_2048.c
 *
 * FFT implementation with window size 2048.
 * This is a straightforward radix-2 complex FFT intended for medium-length
 * signal analysis.
 ******************************************************************************/

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define FFT_WINDOW_SIZE     2048
#define FFT_PI              3.14159265358979323846

#ifndef M_PI
#define M_PI                FFT_PI
#endif

/* Complex number for internal FFT processing */
typedef struct {
    double real;
    double imag;
} complex_t;

/* Global working buffer (single precision output) */
static float g_fft_output[FFT_WINDOW_SIZE];

/*******************************************************************************
 * Reverse bits for Cooley-Tukey bit-reversal permutation.
 ******************************************************************************/
static unsigned int _fft_reverse_bits(unsigned int x, int bits)
{
    unsigned int reversed = 0;
    for (int i = 0; i < bits; i++) {
        reversed = (reversed << 1) | (x & 1);
        x >>= 1;
    }
    return reversed;
}

/*******************************************************************************
 * In-place iterative complex FFT (radix-2, DIT).
 * input/output: interleaved real/imag floats, length = 2 * FFT_WINDOW_SIZE.
 ******************************************************************************/
void fft_2048_process(float *io_buffer)
{
    int n = FFT_WINDOW_SIZE;
    int bits = 11; /* log2(2048) */
    complex_t temp[FFT_WINDOW_SIZE];

    /* Convert interleaved input to complex array */
    for (int i = 0; i < n; i++) {
        temp[i].real = io_buffer[2 * i];
        temp[i].imag = io_buffer[2 * i + 1];
    }

    /* Bit-reversal permutation */
    for (int i = 0; i < n; i++) {
        int j = _fft_reverse_bits(i, bits);
        if (j > i) {
            complex_t t = temp[i];
            temp[i] = temp[j];
            temp[j] = t;
        }
    }

    /* Butterfly stages */
    for (int stage = 1; stage <= bits; stage++) {
        int m = 1 << stage;
        int half = m >> 1;
        double w_m_real = cos(2.0 * M_PI / m);
        double w_m_imag = -sin(2.0 * M_PI / m);

        for (int k = 0; k < n; k += m) {
            double w_real = 1.0;
            double w_imag = 0.0;

            for (int j = 0; j < half; j++) {
                double t_real = w_real * temp[k + j + half].real - w_imag * temp[k + j + half].imag;
                double t_imag = w_real * temp[k + j + half].imag + w_imag * temp[k + j + half].real;

                double u_real = temp[k + j].real;
                double u_imag = temp[k + j].imag;

                temp[k + j].real = u_real + t_real;
                temp[k + j].imag = u_imag + t_imag;
                temp[k + j + half].real = u_real - t_real;
                temp[k + j + half].imag = u_imag - t_imag;

                double next_w_real = w_real * w_m_real - w_imag * w_m_imag;
                double next_w_imag = w_real * w_m_imag + w_imag * w_m_real;
                w_real = next_w_real;
                w_imag = next_w_imag;
            }
        }
    }

    /* Copy magnitude back to interleaved output */
    for (int i = 0; i < n; i++) {
        g_fft_output[i] = (float)sqrt(temp[i].real * temp[i].real + temp[i].imag * temp[i].imag);
        io_buffer[2 * i] = temp[i].real;
        io_buffer[2 * i + 1] = temp[i].imag;
    }
}

/*******************************************************************************
 * Retrieve the magnitude buffer computed by the last FFT call.
 ******************************************************************************/
const float *fft_2048_get_magnitude(void)
{
    return g_fft_output;
}

/*******************************************************************************
 * Initialize all internal buffers to zero.
 ******************************************************************************/
void fft_2048_init(void)
{
    memset(g_fft_output, 0, sizeof(g_fft_output));
}

/*******************************************************************************
 * Simple entry point for testing.
 ******************************************************************************/
int fft_2048_demo(void)
{
    float sample_buffer[2 * FFT_WINDOW_SIZE];

    fft_2048_init();

    for (int i = 0; i < FFT_WINDOW_SIZE; i++) {
        sample_buffer[2 * i] = (float)sin(2.0 * M_PI * 100.0 * i / FFT_WINDOW_SIZE);
        sample_buffer[2 * i + 1] = 0.0f;
    }

    fft_2048_process(sample_buffer);
    const float *mag = fft_2048_get_magnitude();

    (void)mag;
    return 0;
}
