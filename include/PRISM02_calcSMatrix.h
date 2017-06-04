// Copyright Alan (AJ) Pryor, Jr. 2017
// Transcribed from MATLAB code by Colin Ophus
// PRISM is distributed under the GNU General Public License (GPL)
// If you use PRISM, we ask that you cite the following papers:

#ifndef PRISM_PRISM02_H
#define PRISM_PRISM02_H
#include <mutex>
#include <complex>
#include "params.h"
#include "fftw3.h"
#include "configure.h"
#include "defines.h"

namespace PRISM {
	inline void setupCoordinates(Parameters<PRISM_FLOAT_PRECISION>& pars);
	inline void setupBeams(Parameters<PRISM_FLOAT_PRECISION>& pars);
	inline void setupSMatrixCoordinates(Parameters<PRISM_FLOAT_PRECISION>& pars);
	inline void downsampleFourierComponents(Parameters<PRISM_FLOAT_PRECISION> &pars);

	void propagatePlaneWave_CPU(Parameters<PRISM_FLOAT_PRECISION> &pars,
	                            size_t currentBeam,
	                            Array2D<std::complex<PRISM_FLOAT_PRECISION> > &psi,
	                            const PRISM_FFTW_PLAN &plan_forward,
	                            const PRISM_FFTW_PLAN &plan_inverse,
	                            std::mutex& fftw_plan_lock);

	void propagatePlaneWave_CPU_batch(Parameters<PRISM_FLOAT_PRECISION> &pars,
	                                  size_t currentBeam,
	                                  size_t stopBeam,
	                                  Array1D<std::complex<PRISM_FLOAT_PRECISION> > &psi_stack,
	                                  const PRISM_FFTW_PLAN &plan_forward,
	                                  const PRISM_FFTW_PLAN &plan_inverse,
	                                  std::mutex &fftw_plan_lock);

	void fill_Scompact_CPUOnly(Parameters<PRISM_FLOAT_PRECISION> &pars);

	void PRISM02_calcSMatrix(Parameters<PRISM_FLOAT_PRECISION>& pars);

}
#endif //PRISM_PRISM02_H