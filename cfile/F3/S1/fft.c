/*******************************************************************************
 * fft_4096.c
 *
 * Upgraded FFT implementation with window size 4096.
 * Adds a Hanning window, phase extraction, and normalized magnitude scaling.
 ******************************************************************************/

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define FFT_WINDOW_SIZE     4096
#define FFT_PI              3.14159265358979323846

#ifndef M_PI
#define M_PI                FFT_PI
#endif

/* Complex number for internal FFT processing */
typedef struct {
    double real;
    double imag;
} complex_t;

/* Working buffers upgraded to the larger window size */
static float g_fft_output[FFT_WINDOW_SIZE];
static float g_fft_phase[FFT_WINDOW_SIZE];
static float g_window_coeff[FFT_WINDOW_SIZE];
static int g_window_initialized = 0;

/*******************************************************************************
 * Reverse bits for Cooley-Tukey bit-reversal permutation.
 * Upgraded to support up to 12 bits (4096 samples).
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
 * Pre-compute Hanning window coefficients to reduce spectral leakage.
 ******************************************************************************/
static void _fft_init_hanning_window(void)
{
    if (g_window_initialized) {
        return;
    }
    for (int i = 0; i < FFT_WINDOW_SIZE; i++) {
        g_window_coeff[i] = (float)(0.5 - 0.5 * cos(2.0 * M_PI * i / (FFT_WINDOW_SIZE - 1)));
    }
    g_window_initialized = 1;
}

/*******************************************************************************
 * Apply the Hanning window to the input samples before FFT.
 ******************************************************************************/
static void _fft_apply_window(float *io_buffer)
{
    for (int i = 0; i < FFT_WINDOW_SIZE; i++) {
        io_buffer[2 * i] *= g_window_coeff[i];
        io_buffer[2 * i + 1] *= g_window_coeff[i];
    }
}

/*******************************************************************************
 * In-place iterative complex FFT (radix-2, DIT), upgraded for 4096 points.
 * input/output: interleaved real/imag floats, length = 2 * FFT_WINDOW_SIZE.
 ******************************************************************************/
void fft_4096_process(float *io_buffer, int apply_window)
{
    int n = FFT_WINDOW_SIZE;
    int bits = 12; /* log2(4096) */
    complex_t temp[FFT_WINDOW_SIZE];

    _fft_init_hanning_window();

    if (apply_window) {
        _fft_apply_window(io_buffer);
    }

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

    /* Butterfly stages with cache-friendly sequential access */
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

    /* Compute magnitude and phase, with normalization scaling */
    double scale = 1.0 / n;
    for (int i = 0; i < n; i++) {
        double mag = sqrt(temp[i].real * temp[i].real + temp[i].imag * temp[i].imag);
        g_fft_output[i] = (float)(mag * scale);
        g_fft_phase[i] = (float)atan2(temp[i].imag, temp[i].real);
        io_buffer[2 * i] = (float)(temp[i].real * scale);
        io_buffer[2 * i + 1] = (float)(temp[i].imag * scale);
    }
}

/*******************************************************************************
 * Retrieve the magnitude buffer computed by the last FFT call.
 ******************************************************************************/
const float *fft_4096_get_magnitude(void)
{
    return g_fft_output;
}

/*******************************************************************************
 * Retrieve the phase buffer computed by the last FFT call.
 * New feature in the 4096 upgrade.
 ******************************************************************************/
const float *fft_4096_get_phase(void)
{
    return g_fft_phase;
}

/*******************************************************************************
 * Initialize all internal buffers and window coefficients to zero.
 ******************************************************************************/
void fft_4096_init(void)
{
    memset(g_fft_output, 0, sizeof(g_fft_output));
    memset(g_fft_phase, 0, sizeof(g_fft_phase));
    memset(g_window_coeff, 0, sizeof(g_window_coeff));
    g_window_initialized = 0;
}

/*******************************************************************************
 * Advanced entry point for testing with a 100 Hz tone.
 ******************************************************************************/
int fft_4096_demo(void)
{
    float sample_buffer[2 * FFT_WINDOW_SIZE];

    fft_4096_init();

    for (int i = 0; i < FFT_WINDOW_SIZE; i++) {
        sample_buffer[2 * i] = (float)sin(2.0 * M_PI * 100.0 * i / FFT_WINDOW_SIZE);
        sample_buffer[2 * i + 1] = 0.0f;
    }

    fft_4096_process(sample_buffer, 1);
    const float *mag = fft_4096_get_magnitude();
    const float *phase = fft_4096_get_phase();

    (void)mag;
    (void)phase;
    return 0;
}
