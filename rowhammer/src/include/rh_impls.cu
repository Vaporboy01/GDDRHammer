#include <rh_kernels.cuh>
#include <rh_impls.cuh>
#include <rh_utils.cuh>
#include <memory>
#include <algorithm>

static uint8_t **get_aggressor_device_addr(RowList &rows,
                                           std::vector<uint64_t> &agg_vec);

uint64_t start_simple_hammer(RowList &rows, std::vector<uint64_t> &agg_vec,
                             uint64_t it)
{
  /* GPU memory to store aggressors */
  uint8_t **agg_device_arr = get_aggressor_device_addr(rows, agg_vec);

  /* Start hammering */
  auto dim = get_dim_from_size(agg_vec.size());
  int numBlock = std::get<0>(dim);
  int numThreads = std::get<1>(dim);

  /* Setup time measures */
  uint64_t *timeSpentDevice;
  uint64_t timeSpentHost;
  cudaMalloc(&timeSpentDevice, sizeof(uint64_t *));

  std::cout << CLI_PREFIX << "Iterating: " << it << " times\n";

  simple_hammer_kernel<<<numBlock, numThreads>>>(agg_device_arr, it,
                                                 timeSpentDevice);
  cudaDeviceSynchronize();
  cudaMemcpy(&timeSpentHost, timeSpentDevice, sizeof(uint64_t *),
             cudaMemcpyDeviceToHost);

  cudaFree(agg_device_arr);
  return toNS(timeSpentHost);
}

uint64_t start_multi_warp_hammer_seq(RowList &rows, std::vector<uint64_t> &agg_vec,
                                  uint64_t it, uint64_t n, uint64_t k, uint64_t len, uint64_t delay, uint64_t period)
{
  /* GPU memory to store aggressors */
  uint8_t **agg_device_arr = get_aggressor_device_addr(rows, agg_vec);

  uint64_t *timeSpentDevice;
  uint64_t timeSpentHost;
  cudaMalloc(&timeSpentDevice, sizeof(uint64_t *));



  std::cout << CLI_PREFIX << "warp_simple_hammer_kernel_seq_24agg Iterating: " << it << " times\n";
  std::cout << CLI_PREFIX << "Delay: " << delay << "\n";

  warp_simple_hammer_kernel_seq<<<1, 1024>>>(agg_device_arr, it, n, k, len, delay, period, timeSpentDevice);

  cudaDeviceSynchronize();

  cudaMemcpy(&timeSpentHost, timeSpentDevice, sizeof(uint64_t *),
             cudaMemcpyDeviceToHost);


  cudaFree(agg_device_arr);
  cudaFree(timeSpentDevice);
  return toNS(timeSpentHost);
}


uint64_t *start_multi_bank_hammer_seq(std::vector<RowList> &rows, std::vector<std::vector<uint64_t>> &agg_vec, uint64_t it, uint64_t n, uint64_t k, uint64_t len, std::vector<uint64_t> delays, uint64_t period)
{
  size_t num_banks = rows.size();
  
  /* GPU memory to store aggressors */
  uint8_t **agg_device_arr;
  cudaMalloc(&agg_device_arr, sizeof(uint8_t *) * len * num_banks);

  /* Host array to prepare aggressor addresses */
  auto agg_host_arr = std::make_unique<uint8_t *[]>(len * num_banks);

  /* Interleave aggressor addresses: row0-bank0, row0-bank1, row1-bank0, row1-bank1, ... */
  for(int row_idx = 0; row_idx < len; row_idx++) {
    for(int bank_idx = 0; bank_idx < num_banks; bank_idx++) {
      int global_idx = row_idx * num_banks + bank_idx;
      *(agg_host_arr.get() + global_idx) = rows[bank_idx][agg_vec[bank_idx][row_idx]][0];
    }
  }

  /* Copy aggressors to GPU Memory */
  cudaMemcpy(agg_device_arr, agg_host_arr.get(),
             sizeof(uint8_t *) * len * num_banks, cudaMemcpyHostToDevice);

  uint64_t *timeSpentDevice;
  uint64_t *timeSpentHost = new uint64_t[num_banks];
  cudaMalloc(&timeSpentDevice, sizeof(uint64_t) * num_banks);

  uint64_t *delays_device;
  cudaMalloc(&delays_device, sizeof(uint64_t) * num_banks);
  cudaMemcpy(delays_device, delays.data(), sizeof(uint64_t) * num_banks, cudaMemcpyHostToDevice);


  // TODO: Call the appropriate kernel for multi-bank hammering
  multi_bank_hammer_kernel<<<num_banks, 1024>>>(agg_device_arr, it, n, k, len, delays_device, period, timeSpentDevice);



  gpuErrchk(cudaDeviceSynchronize());

  cudaMemcpy(timeSpentHost, timeSpentDevice, sizeof(uint64_t) * num_banks,
             cudaMemcpyDeviceToHost);
  cudaFree(agg_device_arr);
  cudaFree(timeSpentDevice);
  cudaFree(delays_device);
  return timeSpentHost;
}


uint8_t **get_aggressor_device_addr(RowList &rows,
                                    std::vector<uint64_t> &agg_vec)
{
  uint8_t **agg_device_arr;
  cudaMalloc(&agg_device_arr, sizeof(uint8_t *) * agg_vec.size());

  /* Copy aggressors to GPU Memory */
  auto agg_host_arr = std::make_unique<uint8_t *[]>(agg_vec.size());
  for (auto i = 0; i < agg_vec.size(); i++){
    if(agg_vec[i] < rows.size() ){
      *(agg_host_arr.get() + i) = rows[agg_vec[i]][0];
    }
    else *(agg_host_arr.get() + i) = nullptr;
  }

  cudaMemcpy(agg_device_arr, agg_host_arr.get(),
             sizeof(uint8_t *) * agg_vec.size(), cudaMemcpyHostToDevice);

  return agg_device_arr;
}
