// For variable naming, the suffixes are "_d" for "device" (1 copy per GPU), "_ds" for "device stream (1 copy per stream), "_ph" for "pinned host"

#include "PRISM02.cuh"
#include "PRISM02.h"
#include "configure.h"
#include <mutex>
#include <thread>
#include <complex>
#include <vector>
#include "getWorkID.h"
#include "fftw3.h"
#include "defines.h"
#include "cufft.h"
#include "utility.cuh"


namespace PRISM {
	using namespace std;



	void propagatePlaneWave_GPU_singlexfer(Parameters<PRISM_FLOAT_PRECISION> &pars,
	                                       PRISM_CUDA_COMPLEX_FLOAT* trans_d,
		  	                               PRISM_CUDA_COMPLEX_FLOAT* psi_d,
			                               PRISM_CUDA_COMPLEX_FLOAT* psi_small_d,
			                               complex<PRISM_FLOAT_PRECISION>* Scompact_slice_ph,
			                               const size_t* qyInd_d,
			                               const size_t* qxInd_d,
			                               const PRISM_CUDA_COMPLEX_FLOAT* prop_d,
			                               const size_t* beamsIndex,
			                               const size_t& beamNumber,
			                               const cufftHandle& plan,
			                               const cufftHandle& plan_small,
			                               cudaStream_t& stream){


		const size_t psi_size = pars.imageSize[0] * pars.imageSize[1];
		const size_t psi_small_size = pars.qxInd.size() * pars.qyInd.size();
		initializePsi_oneNonzero<<< (psi_size - 1) / BLOCK_SIZE1D + 1, BLOCK_SIZE1D, 0, stream>>>(psi_d, psi_size, pars.beamsIndex[beamNumber]);


		for (auto planeNum = 0; planeNum < pars.numPlanes; ++planeNum) {
			cufftErrchk(PRISM_CUFFT_EXECUTE(plan, &psi_d[0], &psi_d[0], CUFFT_INVERSE));
			multiply_cx<<<(psi_size-1) / BLOCK_SIZE1D + 1,BLOCK_SIZE1D, 0, stream>>>(psi_d, &trans_d[planeNum*psi_size], psi_size);
			divide_inplace<<<(psi_size-1) / BLOCK_SIZE1D + 1,BLOCK_SIZE1D, 0, stream>>>(psi_d, PRISM_MAKE_CU_COMPLEX(psi_size, 0), psi_size);
			cufftErrchk(PRISM_CUFFT_EXECUTE(plan, &psi_d[0], &psi_d[0], CUFFT_FORWARD));
			multiply_cx<<<(psi_size-1) / BLOCK_SIZE1D + 1,BLOCK_SIZE1D, 0, stream>>>(psi_d, prop_d, psi_size);
		}

		array_subset<<<(pars.qyInd.size()*pars.qxInd.size()-1) / BLOCK_SIZE1D + 1,BLOCK_SIZE1D, 0, stream>>> (
		psi_d, psi_small_d, qyInd_d, qxInd_d, pars.imageSize[1], pars.qyInd.size(), pars.qxInd.size());

		PRISM_CUFFT_EXECUTE(plan_small,&psi_small_d[0], &psi_small_d[0], CUFFT_INVERSE);
        divide_inplace<<<(psi_small_size-1) / BLOCK_SIZE1D + 1,BLOCK_SIZE1D, 0, stream>>>(psi_small_d, PRISM_MAKE_CU_COMPLEX(psi_small_size, 0),psi_small_size);

		cudaErrchk(cudaMemcpyAsync(Scompact_slice_ph,&psi_small_d[0],psi_small_size * sizeof(PRISM_CUDA_COMPLEX_FLOAT),cudaMemcpyDeviceToHost,stream));
		cudaStreamSynchronize(stream);
		memcpy(&pars.Scompact[beamNumber * pars.Scompact.get_dimj() * pars.Scompact.get_dimi()], &Scompact_slice_ph[0], psi_small_size * sizeof(PRISM_CUDA_COMPLEX_FLOAT));

	}

	void propagatePlaneWave_GPU_streaming(Parameters<PRISM_FLOAT_PRECISION> &pars,
	                                      PRISM_CUDA_COMPLEX_FLOAT* trans_d,
	                                      const std::complex<PRISM_FLOAT_PRECISION> *trans_ph,
	                                      PRISM_CUDA_COMPLEX_FLOAT* psi_d,
	                                      PRISM_CUDA_COMPLEX_FLOAT* psi_small_d,
	                                      complex<PRISM_FLOAT_PRECISION>* Scompact_slice_ph,
	                                      const size_t* qyInd_d,
	                                      const size_t* qxInd_d,
	                                      const PRISM_CUDA_COMPLEX_FLOAT* prop_d,
	                                      const size_t* beamsIndex,
	                                      const size_t& beamNumber,
	                                      const cufftHandle& plan,
	                                      const cufftHandle& plan_small,
	                                      cudaStream_t& stream){
		// In this version, each slice of the transmission matrix is streamed to the device

		const size_t psi_size = pars.imageSize[0] * pars.imageSize[1];
		const size_t psi_small_size = pars.qxInd.size() * pars.qyInd.size();
		initializePsi_oneNonzero<<< (psi_size - 1) / BLOCK_SIZE1D + 1, BLOCK_SIZE1D, 0, stream>>>(psi_d, psi_size, pars.beamsIndex[beamNumber]);

		for (auto planeNum = 0; planeNum < pars.numPlanes ; ++planeNum) {
			cudaErrchk(cudaMemcpyAsync(trans_d, &trans_ph[planeNum*psi_size], psi_size * sizeof(PRISM_CUDA_COMPLEX_FLOAT), cudaMemcpyHostToDevice, stream));
			cufftErrchk(PRISM_CUFFT_EXECUTE(plan, &psi_d[0], &psi_d[0], CUFFT_INVERSE));
			multiply_cx<<<(psi_size-1) / BLOCK_SIZE1D + 1,BLOCK_SIZE1D, 0, stream>>>(psi_d, trans_d, psi_size);
			divide_inplace<<<(psi_size-1) / BLOCK_SIZE1D + 1,BLOCK_SIZE1D, 0, stream>>>(psi_d, PRISM_MAKE_CU_COMPLEX(psi_size, 0), psi_size);
			cufftErrchk(PRISM_CUFFT_EXECUTE(plan, &psi_d[0], &psi_d[0], CUFFT_FORWARD));
			multiply_cx<<<(psi_size-1) / BLOCK_SIZE1D + 1,BLOCK_SIZE1D, 0, stream>>>(psi_d, prop_d, psi_size);
		}
		array_subset<<<(pars.qyInd.size()*pars.qxInd.size()-1) / BLOCK_SIZE1D + 1,BLOCK_SIZE1D, 0, stream>>> (
				psi_d, psi_small_d, qyInd_d, qxInd_d, pars.imageSize[1], pars.qyInd.size(), pars.qxInd.size());

		PRISM_CUFFT_EXECUTE(plan_small,&psi_small_d[0], &psi_small_d[0], CUFFT_INVERSE);
		divide_inplace<<<(psi_small_size-1) / BLOCK_SIZE1D + 1,BLOCK_SIZE1D, 0, stream>>>(psi_small_d, PRISM_MAKE_CU_COMPLEX(psi_small_size, 0),psi_small_size);

		cudaErrchk(cudaMemcpyAsync(Scompact_slice_ph,&psi_small_d[0],psi_small_size * sizeof(PRISM_CUDA_COMPLEX_FLOAT),cudaMemcpyDeviceToHost,stream));
		cudaStreamSynchronize(stream);
		memcpy(&pars.Scompact[beamNumber * pars.Scompact.get_dimj() * pars.Scompact.get_dimi()], &Scompact_slice_ph[0], psi_small_size * sizeof(PRISM_CUDA_COMPLEX_FLOAT));
	}

	void fill_Scompact_GPU_singlexfer(Parameters <PRISM_FLOAT_PRECISION> &pars) {
		// This version transfers the entire transmission matrix a single time, which results in faster execution but requires more memory
		for (auto g = 0; g < pars.meta.NUM_GPUS; ++g){
			cudaErrchk(cudaSetDevice(g));
			cudaErrchk(cudaSetDeviceFlags(cudaDeviceBlockingSync));
		}
		//initialize data
		const PRISM_FLOAT_PRECISION pi = acos(-1);
		const std::complex<PRISM_FLOAT_PRECISION> i(0, 1);
		pars.Scompact = zeros_ND<3, complex<PRISM_FLOAT_PRECISION> >(
				{{pars.numberBeams, pars.imageSize[0] / 2, pars.imageSize[1] / 2}});
		pars.transmission = zeros_ND<3, complex<PRISM_FLOAT_PRECISION> >(
				{{pars.pot.get_dimk(), pars.pot.get_dimj(), pars.pot.get_dimi()}});
		{
			auto p = pars.pot.begin();
			for (auto &j:pars.transmission)j = exp(i * pars.sigma * (*p++));
		}

		// create CUDA streams
		const int total_num_streams = pars.meta.NUM_GPUS * pars.meta.NUM_STREAMS_PER_GPU;
		cudaStream_t streams[total_num_streams];
		cufftHandle cufft_plan[total_num_streams];
		cufftHandle cufft_plan_small[total_num_streams];
		for (auto j = 0; j < total_num_streams; ++j) {
			cudaSetDevice(j % pars.meta.NUM_GPUS);
			cudaErrchk(cudaStreamCreate(&streams[j]));
			cufftErrchk(cufftPlan2d(&cufft_plan[j], pars.imageSize[1], pars.imageSize[0], PRISM_CUFFT_PLAN_TYPE));
			cufftErrchk(cufftPlan2d(&cufft_plan_small[j], pars.qyInd.size(), pars.qxInd.size(), PRISM_CUFFT_PLAN_TYPE));
			cufftErrchk(cufftSetStream(cufft_plan[j], streams[j]));
			cufftErrchk(cufftSetStream(cufft_plan_small[j], streams[j]));
		}

		// pointers to pinned host memory for async transfers
		std::complex<PRISM_FLOAT_PRECISION> *trans_ph;
		std::complex<PRISM_FLOAT_PRECISION> *prop_ph;
		std::complex<PRISM_FLOAT_PRECISION> *Scompact_slice_ph[total_num_streams];
		size_t *qxInd_ph;
		size_t *qyInd_ph;
		size_t *beamsIndex_ph;

		// allocate pinned memory
		for (auto s = 0; s < total_num_streams; ++s) {
			cudaErrchk(cudaMallocHost((void **) &Scompact_slice_ph[s],
			                          pars.Scompact.get_dimj() * pars.Scompact.get_dimi() *
			                          sizeof(std::complex<PRISM_FLOAT_PRECISION>)));
		}
		cudaErrchk(cudaMallocHost((void **) &trans_ph, pars.transmission.size() * sizeof(std::complex<PRISM_FLOAT_PRECISION>)));
		cudaErrchk(cudaMallocHost((void **) &prop_ph, pars.prop.size() * sizeof(std::complex<PRISM_FLOAT_PRECISION>)));
		cudaErrchk(cudaMallocHost((void **) &qxInd_ph, pars.qxInd.size() * sizeof(size_t)));
		cudaErrchk(cudaMallocHost((void **) &qyInd_ph, pars.qyInd.size() * sizeof(size_t)));
		cudaErrchk(cudaMallocHost((void **) &beamsIndex_ph, pars.beamsIndex.size() * sizeof(size_t)));

		// copy host memory to pinned
		for (auto s = 0; s < total_num_streams; ++s) {
			memset(Scompact_slice_ph[s], 0, pars.Scompact.get_dimj() * pars.Scompact.get_dimi() *
			                                sizeof(std::complex<PRISM_FLOAT_PRECISION>));
		}
		memcpy(trans_ph, &pars.transmission[0], pars.transmission.size() * sizeof(std::complex<PRISM_FLOAT_PRECISION>));
		memcpy(prop_ph, &pars.prop[0], pars.prop.size() * sizeof(std::complex<PRISM_FLOAT_PRECISION>));
		memcpy(qxInd_ph, &pars.qxInd[0], pars.qxInd.size() * sizeof(size_t));
		memcpy(qyInd_ph, &pars.qyInd[0], pars.qyInd.size() * sizeof(size_t));
		memcpy(beamsIndex_ph, &pars.beamsIndex[0], pars.beamsIndex.size() * sizeof(size_t));

		// pointers to read-only GPU memory (one copy per GPU)
		PRISM_CUDA_COMPLEX_FLOAT *trans_d[pars.meta.NUM_GPUS];
		PRISM_CUDA_COMPLEX_FLOAT *prop_d[pars.meta.NUM_GPUS];
		size_t *qxInd_d[pars.meta.NUM_GPUS];
		size_t *qyInd_d[pars.meta.NUM_GPUS];
		size_t *beamsIndex_d[pars.meta.NUM_GPUS];

		// pointers to read/write GPU memory (one per stream)
		PRISM_CUDA_COMPLEX_FLOAT *psi_ds[total_num_streams];
		PRISM_CUDA_COMPLEX_FLOAT *psi_small_ds[total_num_streams];

		// allocate memory on each GPU
		for (auto g = 0; g < pars.meta.NUM_GPUS; ++g) {
			cudaErrchk(cudaSetDevice(g));
			cudaErrchk(cudaMalloc((void **) &trans_d[g], pars.transmission.size() * sizeof(PRISM_CUDA_COMPLEX_FLOAT)));
			cudaErrchk(cudaMalloc((void **) &prop_d[g], pars.prop.size() * sizeof(PRISM_CUDA_COMPLEX_FLOAT)));
			cudaErrchk(cudaMalloc((void **) &qxInd_d[g], pars.qxInd.size() * sizeof(size_t)));
			cudaErrchk(cudaMalloc((void **) &qyInd_d[g], pars.qyInd.size() * sizeof(size_t)));
			cudaErrchk(cudaMalloc((void **) &beamsIndex_d[g], pars.beamsIndex.size() * sizeof(size_t)));
		}

		// allocate memory per stream and 0 it
		for (auto s = 0; s < total_num_streams; ++s) {
			cudaErrchk(cudaSetDevice(s % pars.meta.NUM_GPUS));
			cudaErrchk(cudaMalloc((void **) &psi_ds[s],
			                      pars.imageSize[0] * pars.imageSize[1] * sizeof(PRISM_CUDA_COMPLEX_FLOAT)));
			cudaErrchk(cudaMalloc((void **) &psi_small_ds[s],
			                      pars.qxInd.size() * pars.qyInd.size() * sizeof(PRISM_CUDA_COMPLEX_FLOAT)));
			cudaErrchk(cudaMemset(psi_ds[s], 0,
			                      pars.imageSize[0] * pars.imageSize[1] * sizeof(PRISM_CUDA_COMPLEX_FLOAT)));
			cudaErrchk(cudaMemset(psi_small_ds[s], 0,
			                      pars.qxInd.size() * pars.qyInd.size() * sizeof(PRISM_CUDA_COMPLEX_FLOAT)));
		}

		// Copy memory to each GPU asynchronously from the pinned host memory spaces.
		// The streams are laid out so that consecutive streams represent different GPUs. If we
		// have more than one stream per GPU, then we want to interleave as much as possible
		int stream_id = 0;
		for (auto g = 0; g < pars.meta.NUM_GPUS; ++g) {
			stream_id = g;
			cudaErrchk(cudaSetDevice(g));
			cudaErrchk(cudaMemcpyAsync(trans_d[g], &trans_ph[0],
			                           pars.transmission.size() * sizeof(std::complex<PRISM_FLOAT_PRECISION>),
			                           cudaMemcpyHostToDevice, streams[stream_id]));

			stream_id = (stream_id + pars.meta.NUM_GPUS) % total_num_streams;
			cout << "stream_id = " << stream_id << endl;
			cudaErrchk(cudaMemcpyAsync(prop_d[g], &prop_ph[0],
			                           pars.prop.size() * sizeof(std::complex<PRISM_FLOAT_PRECISION>),
			                           cudaMemcpyHostToDevice, streams[stream_id]));
			stream_id = (stream_id + pars.meta.NUM_GPUS) % total_num_streams;
			cout << "stream_id = " << stream_id << endl;
			cudaErrchk(cudaMemcpyAsync(qxInd_d[g], &qxInd_ph[0],
			                           pars.qxInd.size() * sizeof(size_t), cudaMemcpyHostToDevice, streams[stream_id]));
			stream_id = (stream_id + pars.meta.NUM_GPUS) % total_num_streams;
			cout << "stream_id = " << stream_id << endl;
			cudaErrchk(cudaMemcpyAsync(qyInd_d[g], &qyInd_ph[0],
			                           pars.qyInd.size() * sizeof(size_t), cudaMemcpyHostToDevice, streams[stream_id]));
			stream_id = (stream_id + pars.meta.NUM_GPUS) % total_num_streams;
			cout << "stream_id = " << stream_id << endl;
			cudaErrchk(cudaMemcpyAsync(beamsIndex_d[g], &beamsIndex_ph[0],
			                           pars.beamsIndex.size() * sizeof(size_t), cudaMemcpyHostToDevice,
			                           streams[stream_id]));
		}

		// make sure transfers are complete
		for (auto g = 0; g < pars.meta.NUM_GPUS; ++g) {
			cudaSetDevice(g);
			cudaDeviceSynchronize();
		}

		// launch GPU work
		vector<thread> workers_GPU;
		workers_GPU.reserve(total_num_streams); // prevents multiple reallocations
		int stream_count = 0;
		setWorkStartStop(0, pars.numberBeams, 1);
		for (auto t = 0; t < total_num_streams; ++t) {

			int GPU_num = stream_count % pars.meta.NUM_GPUS; // determine which GPU handles this job
			cudaSetDevice(GPU_num);
			cudaStream_t &current_stream = streams[stream_count];
			cout << "Launching GPU worker on stream #" << stream_count << " of GPU #" << GPU_num << '\n';

			// get pointers to the pre-copied arrays, making sure to get those on the current GPU
			PRISM_CUDA_COMPLEX_FLOAT *current_trans_d = trans_d[GPU_num];
			PRISM_CUDA_COMPLEX_FLOAT *current_prop_d = prop_d[GPU_num];
			size_t *current_qxInd_d = qxInd_d[GPU_num];
			size_t *current_qyInd_d = qyInd_d[GPU_num];
			size_t *current_beamsIndex = beamsIndex_d[GPU_num];
			// get pointers to per-stream arrays
			PRISM_CUDA_COMPLEX_FLOAT *current_psi_ds = psi_ds[stream_count];
			PRISM_CUDA_COMPLEX_FLOAT *current_psi_small_ds = psi_small_ds[stream_count];
			cufftHandle &current_cufft_plan = cufft_plan[stream_count];
			cufftHandle &current_cufft_plan_small = cufft_plan_small[stream_count];
			complex<PRISM_FLOAT_PRECISION> *current_S_slice_ph = Scompact_slice_ph[stream_count];

			workers_GPU.emplace_back(thread([&pars, current_trans_d, current_prop_d, current_qxInd_d, current_qyInd_d,
					                                current_psi_ds, current_psi_small_ds, &current_cufft_plan, &current_cufft_plan_small,
					                                current_S_slice_ph, current_beamsIndex, GPU_num, stream_count, &current_stream]() {
				cudaErrchk(cudaSetDevice(GPU_num));

				size_t currentBeam, stop;
				while (getWorkID(pars, currentBeam, stop)) {
					while (currentBeam != stop) {
						propagatePlaneWave_GPU_singlexfer(pars,
						                                  current_trans_d,
						                                  current_psi_ds,
						                                  current_psi_small_ds,
						                                  current_S_slice_ph,
						                                  current_qyInd_d,
						                                  current_qxInd_d,
						                                  current_prop_d,
						                                  current_beamsIndex,
						                                  currentBeam,
						                                  current_cufft_plan,
						                                  current_cufft_plan_small,
						                                  current_stream);
						++currentBeam;
					}
				}
				cout << "GPU worker on stream #" << stream_count << " of GPU #" << GPU_num << "finished\n";
			}));
			++stream_count;
		}

		if (pars.meta.also_do_CPU_work){
			PRISM_FFTW_INIT_THREADS();
			PRISM_FFTW_PLAN_WITH_NTHREADS(pars.meta.NUM_THREADS);
			// launch CPU work
			vector<thread> workers_CPU;
			workers_CPU.reserve(pars.meta.NUM_THREADS); // prevents multiple reallocations
			mutex fftw_plan_lock;
			setWorkStartStop(0, pars.numberBeams);
			//for (auto t = 0; t < pars.meta.NUM_THREADS; ++t) {
			for (auto t = 0; t < 1; ++t) {
				cout << "Launching thread #" << t << " to compute beams\n";
				workers_CPU.emplace_back([&pars, &fftw_plan_lock]() {
				// allocate array for psi just once per thread
				Array2D<complex<PRISM_FLOAT_PRECISION> > psi = zeros_ND<2, complex<PRISM_FLOAT_PRECISION> >(
						{{pars.imageSize[0], pars.imageSize[1]}});

				unique_lock<mutex> gatekeeper(fftw_plan_lock);
				PRISM_FFTW_PLAN plan_forward = PRISM_FFTW_PLAN_DFT_2D(psi.get_dimj(), psi.get_dimi(),
				                                                      reinterpret_cast<PRISM_FFTW_COMPLEX *>(&psi[0]),
				                                                      reinterpret_cast<PRISM_FFTW_COMPLEX *>(&psi[0]),
				                                                      FFTW_FORWARD, FFTW_ESTIMATE);
				PRISM_FFTW_PLAN plan_inverse = PRISM_FFTW_PLAN_DFT_2D(psi.get_dimj(), psi.get_dimi(),
				                                                      reinterpret_cast<PRISM_FFTW_COMPLEX *>(&psi[0]),
				                                                      reinterpret_cast<PRISM_FFTW_COMPLEX *>(&psi[0]),
				                                                      FFTW_BACKWARD, FFTW_ESTIMATE);
				gatekeeper.unlock(); // unlock it so we only block as long as necessary to deal with plans
				size_t currentBeam, stop, early_CPU_stop;
				stop = 0;
				early_CPU_stop = stop * (1-pars.meta.cpu_gpu_ratio);
				while (getWorkID(pars, currentBeam, stop)) { // synchronously get work assignment
					while (currentBeam != stop) {
						// re-zero psi each iteration
						memset((void *) &psi[0], 0, psi.size() * sizeof(complex<PRISM_FLOAT_PRECISION>));
					propagatePlaneWave_CPU(pars, currentBeam, psi, plan_forward, plan_inverse,
						                       fftw_plan_lock);
						++currentBeam;
					}
					if (currentBeam >= early_CPU_stop) break;
				}
				// clean up
				gatekeeper.lock();
				PRISM_FFTW_DESTROY_PLAN(plan_forward);
				PRISM_FFTW_DESTROY_PLAN(plan_inverse);
				gatekeeper.unlock();
			});
		}
		for (auto &t:workers_CPU)t.join();
		PRISM_FFTW_CLEANUP_THREADS();
	}

		for (auto &t:workers_GPU)t.join();
		for (auto g = 0; g < pars.meta.NUM_GPUS; ++g) {
			cudaErrchk(cudaSetDevice(g));
			cudaErrchk(cudaFree(trans_d[g]));
			cudaErrchk(cudaFree(prop_d[g]));
			cudaErrchk(cudaFree(qxInd_d[g]));
			cudaErrchk(cudaFree(qyInd_d[g]));
			cudaErrchk(cudaFree(beamsIndex_d[g]));
		}

		for (auto s = 0; s < total_num_streams; ++s) {
			cudaErrchk(cudaSetDevice(s % pars.meta.NUM_GPUS));
			cudaErrchk(cudaFree(psi_ds[s]));
			cudaErrchk(cudaFree(psi_small_ds[s]));
			cufftErrchk(cufftDestroy(cufft_plan[s]));
			cufftErrchk(cufftDestroy(cufft_plan_small[s]));
		}



//		 allocate memory on each GPU
//		for (auto g = 0; g < pars.meta.NUM_GPUS; ++g) {
//			cudaErrchk(cudaSetDevice(g));
//			cudaErrchk(cudaMalloc((void **) &trans_d[g],      trans.size()      * sizeof(trans[0])));
//			cudaErrchk(cudaMalloc((void **) &prop_d[g],       pars.prop.size()  * sizeof(pars.prop[0])));
//			cudaErrchk(cudaMalloc((void **) &qxInd_d[g],      pars.qxInd.size() * sizeof(pars.qxInd[0])));
//			cudaErrchk(cudaMalloc((void **) &qyInd_d[g],      pars.qyInd.size() * sizeof(pars.qyInd[0])));
//			cudaErrchk(cudaMalloc((void **) &beamsIndex_d[g], pars.beamsIndex.size() * sizeof(pars.beamsIndex[0])));
//		}


		// free pinned memory
		for (auto s = 0; s < total_num_streams; ++s) {
			cudaErrchk(cudaFreeHost(Scompact_slice_ph[s]));
		}
		cudaErrchk(cudaFreeHost(trans_ph));
		cudaErrchk(cudaFreeHost(prop_ph));
		cudaErrchk(cudaFreeHost(qxInd_ph));
		cudaErrchk(cudaFreeHost(qyInd_ph));
		cudaErrchk(cudaFreeHost(beamsIndex_ph));


		// destroy CUDA streams
		for (auto j = 0; j < total_num_streams; ++j){
			cudaSetDevice(j % pars.meta.NUM_GPUS);
			cudaErrchk(cudaStreamDestroy(streams[j]));
		}

		for (auto g = 0; g < pars.meta.NUM_GPUS; ++g){
			cudaErrchk(cudaSetDevice(g));
			cudaErrchk(cudaDeviceReset());
		}
	}


	void fill_Scompact_GPU_streaming(Parameters <PRISM_FLOAT_PRECISION> &pars) {
		// This version streams each slice of the transmission matrix, which is less efficient but can tolerate very large arrays
		for (auto g = 0; g < pars.meta.NUM_GPUS; ++g){
			cudaErrchk(cudaSetDevice(g));
			cudaErrchk(cudaSetDeviceFlags(cudaDeviceBlockingSync));
		}
		//initialize data
		const PRISM_FLOAT_PRECISION pi = acos(-1);
		const std::complex<PRISM_FLOAT_PRECISION> i(0, 1);
		pars.Scompact = zeros_ND<3, complex<PRISM_FLOAT_PRECISION> >(
				{{pars.numberBeams, pars.imageSize[0] / 2, pars.imageSize[1] / 2}});
		pars.transmission = zeros_ND<3, complex<PRISM_FLOAT_PRECISION> >(
				{{pars.pot.get_dimk(), pars.pot.get_dimj(), pars.pot.get_dimi()}});
		{
			auto p = pars.pot.begin();
			for (auto &j:pars.transmission)j = exp(i * pars.sigma * (*p++));
		}

		// create CUDA streams
		const int total_num_streams = pars.meta.NUM_GPUS * pars.meta.NUM_STREAMS_PER_GPU;
		cudaStream_t streams[total_num_streams];
		cufftHandle cufft_plan[total_num_streams];
		cufftHandle cufft_plan_small[total_num_streams];
		for (auto j = 0; j < total_num_streams; ++j) {
			cudaSetDevice(j % pars.meta.NUM_GPUS);
			cudaErrchk(cudaStreamCreate(&streams[j]));
			cufftErrchk(cufftPlan2d(&cufft_plan[j], pars.imageSize[0], pars.imageSize[1], PRISM_CUFFT_PLAN_TYPE));
			cufftErrchk(cufftPlan2d(&cufft_plan_small[j], pars.qyInd.size(), pars.qxInd.size(), PRISM_CUFFT_PLAN_TYPE));
			cufftErrchk(cufftSetStream(cufft_plan[j], streams[j]));
			cufftErrchk(cufftSetStream(cufft_plan_small[j], streams[j]));
		}

		// pointers to pinned host memory for async transfers
		std::complex<PRISM_FLOAT_PRECISION> *trans_ph;
		std::complex<PRISM_FLOAT_PRECISION> *prop_ph;
		std::complex<PRISM_FLOAT_PRECISION> *Scompact_slice_ph[total_num_streams];
		size_t *qxInd_ph;
		size_t *qyInd_ph;
		size_t *beamsIndex_ph;

		// allocate pinned memory
		for (auto s = 0; s < total_num_streams; ++s) {
			cudaErrchk(cudaMallocHost((void **) &Scompact_slice_ph[s],
			                          pars.Scompact.get_dimj() * pars.Scompact.get_dimi() *
			                          sizeof(std::complex<PRISM_FLOAT_PRECISION>)));
		}
		cudaErrchk(cudaMallocHost((void **) &trans_ph, pars.transmission.size() * sizeof(std::complex<PRISM_FLOAT_PRECISION>)));
		cudaErrchk(cudaMallocHost((void **) &prop_ph, pars.prop.size() * sizeof(std::complex<PRISM_FLOAT_PRECISION>)));
		cudaErrchk(cudaMallocHost((void **) &qxInd_ph, pars.qxInd.size() * sizeof(size_t)));
		cudaErrchk(cudaMallocHost((void **) &qyInd_ph, pars.qyInd.size() * sizeof(size_t)));
		cudaErrchk(cudaMallocHost((void **) &beamsIndex_ph, pars.beamsIndex.size() * sizeof(size_t)));

		// copy host memory to pinned
		for (auto s = 0; s < total_num_streams; ++s) {
			memset(Scompact_slice_ph[s], 0, pars.Scompact.get_dimj() * pars.Scompact.get_dimi() *
			                                sizeof(std::complex<PRISM_FLOAT_PRECISION>));
		}
		memcpy(trans_ph, &pars.transmission[0], pars.transmission.size() * sizeof(std::complex<PRISM_FLOAT_PRECISION>));
		memcpy(prop_ph, &pars.prop[0], pars.prop.size() * sizeof(std::complex<PRISM_FLOAT_PRECISION>));
		memcpy(qxInd_ph, &pars.qxInd[0], pars.qxInd.size() * sizeof(size_t));
		memcpy(qyInd_ph, &pars.qyInd[0], pars.qyInd.size() * sizeof(size_t));
		memcpy(beamsIndex_ph, &pars.beamsIndex[0], pars.beamsIndex.size() * sizeof(size_t));

		// pointers to read-only GPU memory (one copy per GPU)

		PRISM_CUDA_COMPLEX_FLOAT *prop_d[pars.meta.NUM_GPUS];
		size_t *qxInd_d[pars.meta.NUM_GPUS];
		size_t *qyInd_d[pars.meta.NUM_GPUS];
		size_t *beamsIndex_d[pars.meta.NUM_GPUS];

		// pointers to read/write GPU memory (one per stream)
		PRISM_CUDA_COMPLEX_FLOAT *trans_ds[total_num_streams];
		PRISM_CUDA_COMPLEX_FLOAT *psi_ds[total_num_streams];
		PRISM_CUDA_COMPLEX_FLOAT *psi_small_ds[total_num_streams];

		// allocate memory on each GPU
		for (auto g = 0; g < pars.meta.NUM_GPUS; ++g) {
			cudaErrchk(cudaSetDevice(g));

			cudaErrchk(cudaMalloc((void **) &prop_d[g], pars.prop.size() * sizeof(PRISM_CUDA_COMPLEX_FLOAT)));
			cudaErrchk(cudaMalloc((void **) &qxInd_d[g], pars.qxInd.size() * sizeof(size_t)));
			cudaErrchk(cudaMalloc((void **) &qyInd_d[g], pars.qyInd.size() * sizeof(size_t)));
			cudaErrchk(cudaMalloc((void **) &beamsIndex_d[g], pars.beamsIndex.size() * sizeof(size_t)));
		}

		// allocate memory per stream and 0 it
		for (auto s = 0; s < total_num_streams; ++s) {
			cudaErrchk(cudaSetDevice(s % pars.meta.NUM_GPUS));
			cudaErrchk(cudaMalloc((void **) &trans_ds[s],
			                      pars.imageSize[0] * pars.imageSize[1] * sizeof(PRISM_CUDA_COMPLEX_FLOAT)));
			cudaErrchk(cudaMalloc((void **) &psi_ds[s],
			                      pars.imageSize[0] * pars.imageSize[1] * sizeof(PRISM_CUDA_COMPLEX_FLOAT)));
			cudaErrchk(cudaMalloc((void **) &psi_small_ds[s],
			                      pars.qxInd.size() * pars.qyInd.size() * sizeof(PRISM_CUDA_COMPLEX_FLOAT)));
			cudaErrchk(cudaMemset(psi_ds[s], 0,
			                      pars.imageSize[0] * pars.imageSize[1] * sizeof(PRISM_CUDA_COMPLEX_FLOAT)));
			cudaErrchk(cudaMemset(psi_small_ds[s], 0,
			                      pars.qxInd.size() * pars.qyInd.size() * sizeof(PRISM_CUDA_COMPLEX_FLOAT)));
		}

		// Copy memory to each GPU asynchronously from the pinned host memory spaces.
		// The streams are laid out so that consecutive streams represent different GPUs. If we
		// have more than one stream per GPU, then we want to interleave as much as possible
		int stream_id = 0;
		for (auto g = 0; g < pars.meta.NUM_GPUS; ++g) {
			stream_id = g;
			cudaErrchk(cudaSetDevice(g));
//			cudaErrchk(cudaMemcpyAsync(trans_ds[g], &trans_ph[0],
//			                           pars.imageSize[0] * pars.imageSize[1] * sizeof(std::complex<PRISM_FLOAT_PRECISION>),
//			                           cudaMemcpyHostToDevice, streams[stream_id]));

			stream_id = (stream_id + pars.meta.NUM_GPUS) % total_num_streams;
			cout << "stream_id = " << stream_id << endl;
			cudaErrchk(cudaMemcpyAsync(prop_d[g], &prop_ph[0],
			                           pars.prop.size() * sizeof(std::complex<PRISM_FLOAT_PRECISION>),
			                           cudaMemcpyHostToDevice, streams[stream_id]));
			stream_id = (stream_id + pars.meta.NUM_GPUS) % total_num_streams;
			cout << "stream_id = " << stream_id << endl;
			cudaErrchk(cudaMemcpyAsync(qxInd_d[g], &qxInd_ph[0],
			                           pars.qxInd.size() * sizeof(size_t), cudaMemcpyHostToDevice, streams[stream_id]));
			stream_id = (stream_id + pars.meta.NUM_GPUS) % total_num_streams;
			cout << "stream_id = " << stream_id << endl;
			cudaErrchk(cudaMemcpyAsync(qyInd_d[g], &qyInd_ph[0],
			                           pars.qyInd.size() * sizeof(size_t), cudaMemcpyHostToDevice, streams[stream_id]));
			stream_id = (stream_id + pars.meta.NUM_GPUS) % total_num_streams;
			cout << "stream_id = " << stream_id << endl;
			cudaErrchk(cudaMemcpyAsync(beamsIndex_d[g], &beamsIndex_ph[0],
			                           pars.beamsIndex.size() * sizeof(size_t), cudaMemcpyHostToDevice,
			                           streams[stream_id]));
		}

		// make sure transfers are complete
		for (auto g = 0; g < pars.meta.NUM_GPUS; ++g) {
			cudaSetDevice(g);
			cudaDeviceSynchronize();
		}

		// launch GPU work
		vector<thread> workers_GPU;
		workers_GPU.reserve(total_num_streams); // prevents multiple reallocations
		int stream_count = 0;
		setWorkStartStop(0, pars.numberBeams);
		for (auto t = 0; t < total_num_streams; ++t) {

			int GPU_num = stream_count % pars.meta.NUM_GPUS; // determine which GPU handles this job
			cudaSetDevice(GPU_num);
			cudaStream_t &current_stream = streams[stream_count];
			cout << "Launching GPU worker on stream #" << stream_count << " of GPU #" << GPU_num << '\n';

			// get pointers to the pre-copied arrays, making sure to get those on the current GPU
			PRISM_CUDA_COMPLEX_FLOAT *current_prop_d = prop_d[GPU_num];
			size_t *current_qxInd_d = qxInd_d[GPU_num];
			size_t *current_qyInd_d = qyInd_d[GPU_num];
			size_t *current_beamsIndex = beamsIndex_d[GPU_num];

			// get pointers to per-stream arrays
			PRISM_CUDA_COMPLEX_FLOAT *current_trans_ds = trans_ds[stream_count];
			PRISM_CUDA_COMPLEX_FLOAT *current_psi_ds = psi_ds[stream_count];
			PRISM_CUDA_COMPLEX_FLOAT *current_psi_small_ds = psi_small_ds[stream_count];
			cufftHandle &current_cufft_plan = cufft_plan[stream_count];
			cufftHandle &current_cufft_plan_small = cufft_plan_small[stream_count];
			complex<PRISM_FLOAT_PRECISION> *current_S_slice_ph = Scompact_slice_ph[stream_count];

			workers_GPU.emplace_back(thread([&pars, current_trans_ds, trans_ph, current_prop_d, current_qxInd_d, current_qyInd_d,
					                                current_psi_ds, current_psi_small_ds, &current_cufft_plan, &current_cufft_plan_small,
					                                current_S_slice_ph, current_beamsIndex, GPU_num, stream_count, &current_stream]() {
				cudaErrchk(cudaSetDevice(GPU_num));

				size_t currentBeam, stop;
				while (getWorkID(pars, currentBeam, stop)) {
					while (currentBeam != stop) {
						propagatePlaneWave_GPU_streaming(pars,
						                                 current_trans_ds,
						                                 trans_ph,
						                                 current_psi_ds,
						                                 current_psi_small_ds,
						                                 current_S_slice_ph,
						                                 current_qyInd_d,
						                                 current_qxInd_d,
						                                 current_prop_d,
						                                 current_beamsIndex,
						                                 currentBeam,
						                                 current_cufft_plan,
						                                 current_cufft_plan_small,
						                                 current_stream);
						++currentBeam;
					}
				}
				cout << "GPU worker on stream #" << stream_count << " of GPU #" << GPU_num << "finished\n";
			}));
			++stream_count;
		}

		if (pars.meta.also_do_CPU_work){
			PRISM_FFTW_INIT_THREADS();
			PRISM_FFTW_PLAN_WITH_NTHREADS(pars.meta.NUM_THREADS);
			// launch CPU work
			vector<thread> workers_CPU;
			workers_CPU.reserve(pars.meta.NUM_THREADS); // prevents multiple reallocations
			mutex fftw_plan_lock;
			setWorkStartStop(0, pars.numberBeams);
			//for (auto t = 0; t < pars.meta.NUM_THREADS; ++t) {
			for (auto t = 0; t < 1; ++t) {
				cout << "Launching thread #" << t << " to compute beams\n";
				workers_CPU.emplace_back([&pars, &fftw_plan_lock]() {
				// allocate array for psi just once per thread
				Array2D<complex<PRISM_FLOAT_PRECISION> > psi = zeros_ND<2, complex<PRISM_FLOAT_PRECISION> >(
						{{pars.imageSize[0], pars.imageSize[1]}});

				unique_lock<mutex> gatekeeper(fftw_plan_lock);
				PRISM_FFTW_PLAN plan_forward = PRISM_FFTW_PLAN_DFT_2D(psi.get_dimj(), psi.get_dimi(),
				                                                      reinterpret_cast<PRISM_FFTW_COMPLEX *>(&psi[0]),
				                                                      reinterpret_cast<PRISM_FFTW_COMPLEX *>(&psi[0]),
				                                                      FFTW_FORWARD, FFTW_ESTIMATE);
				PRISM_FFTW_PLAN plan_inverse = PRISM_FFTW_PLAN_DFT_2D(psi.get_dimj(), psi.get_dimi(),
				                                                      reinterpret_cast<PRISM_FFTW_COMPLEX *>(&psi[0]),
				                                                      reinterpret_cast<PRISM_FFTW_COMPLEX *>(&psi[0]),
				                                                      FFTW_BACKWARD, FFTW_ESTIMATE);
				gatekeeper.unlock(); // unlock it so we only block as long as necessary to deal with plans
				size_t currentBeam, stop, early_CPU_stop;
				stop = 0;
				early_CPU_stop = stop * (1-pars.meta.cpu_gpu_ratio);
				while (getWorkID(pars, currentBeam, stop)) { // synchronously get work assignment
					while (currentBeam != stop) {
						// re-zero psi each iteration
						memset((void *) &psi[0], 0, psi.size() * sizeof(complex<PRISM_FLOAT_PRECISION>));
						propagatePlaneWave_CPU(pars,  currentBeam, psi, plan_forward, plan_inverse,
						                       fftw_plan_lock);
						++currentBeam;
					}
					if (currentBeam >= early_CPU_stop) break;
				}
				// clean up
				gatekeeper.lock();
				PRISM_FFTW_DESTROY_PLAN(plan_forward);
				PRISM_FFTW_DESTROY_PLAN(plan_inverse);
				gatekeeper.unlock();
			});
		}
		for (auto &t:workers_CPU)t.join();
		PRISM_FFTW_CLEANUP_THREADS();
	}

		for (auto &t:workers_GPU)t.join();
		for (auto g = 0; g < pars.meta.NUM_GPUS; ++g) {
			cudaErrchk(cudaSetDevice(g));
			cudaErrchk(cudaFree(prop_d[g]));
			cudaErrchk(cudaFree(qxInd_d[g]));
			cudaErrchk(cudaFree(qyInd_d[g]));
			cudaErrchk(cudaFree(beamsIndex_d[g]));
		}

		for (auto s = 0; s < total_num_streams; ++s) {
			cudaErrchk(cudaSetDevice(s % pars.meta.NUM_GPUS));
			cudaErrchk(cudaFree(trans_ds[s]));
			cudaErrchk(cudaFree(psi_ds[s]));
			cudaErrchk(cudaFree(psi_small_ds[s]));
			cufftErrchk(cufftDestroy(cufft_plan[s]));
			cufftErrchk(cufftDestroy(cufft_plan_small[s]));
		}



//		 allocate memory on each GPU
//		for (auto g = 0; g < pars.meta.NUM_GPUS; ++g) {
//			cudaErrchk(cudaSetDevice(g));
//			cudaErrchk(cudaMalloc((void **) &trans_d[g],      trans.size()      * sizeof(trans[0])));
//			cudaErrchk(cudaMalloc((void **) &prop_d[g],       pars.prop.size()  * sizeof(pars.prop[0])));
//			cudaErrchk(cudaMalloc((void **) &qxInd_d[g],      pars.qxInd.size() * sizeof(pars.qxInd[0])));
//			cudaErrchk(cudaMalloc((void **) &qyInd_d[g],      pars.qyInd.size() * sizeof(pars.qyInd[0])));
//			cudaErrchk(cudaMalloc((void **) &beamsIndex_d[g], pars.beamsIndex.size() * sizeof(pars.beamsIndex[0])));
//		}


		// free pinned memory
		for (auto s = 0; s < total_num_streams; ++s) {
			cudaErrchk(cudaFreeHost(Scompact_slice_ph[s]));
		}
		cudaErrchk(cudaFreeHost(trans_ph));
		cudaErrchk(cudaFreeHost(prop_ph));
		cudaErrchk(cudaFreeHost(qxInd_ph));
		cudaErrchk(cudaFreeHost(qyInd_ph));
		cudaErrchk(cudaFreeHost(beamsIndex_ph));


		// destroy CUDA streams
		for (auto j = 0; j < total_num_streams; ++j){
			cudaSetDevice(j % pars.meta.NUM_GPUS);
			cudaErrchk(cudaStreamDestroy(streams[j]));
		}

		for (auto g = 0; g < pars.meta.NUM_GPUS; ++g){
			cudaErrchk(cudaSetDevice(g));
			cudaErrchk(cudaDeviceReset());
		}
	}














}
