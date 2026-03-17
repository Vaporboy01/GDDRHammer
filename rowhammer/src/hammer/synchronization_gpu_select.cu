#include <rh_utils.cuh>
#include <rh_impls.cuh>

#include <atomic>
#include <chrono>
#include <fstream>
#include <iostream>
#include <pthread.h>
#include <stdint.h>
#include <vector>
#include <numeric>
#include <random>
#include <algorithm>

std::string CLI_PREFIX = "(synchronization): ";
int main(int argc, char *argv[])
{
  if (argc < 15) {
    std::cout << CLI_PREFIX << "Usage: " << argv[0] 
              << " <gpu_id> <rowset_file> <num_victim> <step> <iterations> <rowId> <size> "
              << "<time_file> <num_warp> <num_thread> <round> <min_delay> <max_delay> <num_rows>" << std::endl;
    return -1;
  }

  // First argument is GPU ID
  const int gpu_id = std::stoi(argv[1]);
  
  // Set the GPU device
  cudaError_t err = cudaSetDevice(gpu_id);
  if (err != cudaSuccess) {
    std::cerr << CLI_PREFIX << "Error: Failed to set GPU " << gpu_id 
              << " - " << cudaGetErrorString(err) << std::endl;
    return -1;
  }
  std::cout << CLI_PREFIX << "Using GPU " << gpu_id << std::endl;
  
  // Adjust argv indices by 1 since first arg is now gpu_id
  const uint64_t num_victim = std::stoull(argv[3]);
  const uint64_t step       = std::stoull(argv[4]);
  const uint64_t it         = std::stoull(argv[5]);
  const uint64_t rowId      = std::stoull(argv[6]);
  const uint64_t size       = std::stoull(argv[7]);
  std::ofstream time_file(argv[8]);
  const uint64_t n          = std::stoull(argv[9]);
  const uint64_t k          = std::stoull(argv[10]);
  const uint64_t period     = std::stoull(argv[11]);
  const uint64_t min_delay  = std::stoull(argv[12]);
  const uint64_t max_delay  = std::stoull(argv[13]);
  const uint64_t num_rows   = std::stoull(argv[14]);


  const uint64_t rng_seed = static_cast<uint64_t>(std::chrono::high_resolution_clock::now().time_since_epoch().count());
  std::mt19937_64 rng(rng_seed);
  std::uniform_int_distribution<uint64_t> dist_row(0ULL, num_rows - 1);

  /* Read the row set */
  uint8_t *layout;
  cudaMalloc(&layout, size);
  std::ifstream row_set_file(argv[2]);
  RowList rows = read_row_from_file(row_set_file, layout);
  row_set_file.close();

  if ((int64_t)(rows.size() - 2 * num_victim - 1) < 0)
  {
    std::cout << CLI_PREFIX << "Error: "
              << "Not enough rows to generate the specified victims." << '\n';
    exit(-1);
  }

        auto gen_far_aggs = [&](uint64_t victim_row, uint64_t near_agg, uint64_t need_cnt) {
            std::vector<uint64_t> far;
            far.reserve(need_cnt);
            while (far.size() < need_cnt) {
                uint64_t r = dist_row(rng);
                if (r == victim_row || r == near_agg) continue;
                int64_t dr_v = static_cast<int64_t>(r) - static_cast<int64_t>(victim_row);
                int64_t dr_a = static_cast<int64_t>(r) - static_cast<int64_t>(near_agg);
                if (std::llabs(dr_v) < 10000 || std::llabs(dr_a) < 10000) continue;
                if (std::find(far.begin(), far.end(), r) != far.end()) continue;
                far.push_back(r);
            }
            return far;
        };

  /* Treat all rows as victim rows */
  std::vector<uint64_t> all_vics(num_rows);
  std::iota(all_vics.begin(), all_vics.end(), 0);
  set_rows(rows, all_vics, MEM_PAT::VICTIM_PAT, step);

  /* Dummy hammer to keep timing consistent, due to device startup time */
  start_simple_hammer(rows, all_vics, 1);

  /* Running */

  /* Testing delay amounts */
  int i = rowId;
  for (int delay_inc = 0; delay_inc < max_delay; delay_inc++) {

    /* Initialize indexes of victims and aggressors */
    std::vector<uint64_t> victims = get_sequential_victims(rows, i, num_victim + 2, 4);
    std::vector<uint64_t> aggressors = get_aggressors(rows, i, num_victim + 1, 4);


    std::cout << CLI_PREFIX << "Chosen Victims:" << vector_str(victims) << '\n';
    std::cout << CLI_PREFIX << "Chosen Aggressors:" << vector_str(aggressors)
              << '\n';

    /* Sets the row and evict cache to store it in the memory. */
    set_rows(rows, victims, MEM_PAT::VICTIM_PAT, step);
    set_rows(rows, aggressors, MEM_PAT::AGGRES_PAT, step);
    evict_L2cache(layout);
    clear_L2cache_rows(rows, victims, step);
    
    /* Dummy hammer to keep timing consistent, due to device startup time */
    start_simple_hammer(rows, victims, 1);

    /* Start the hammering and measure the time */
    uint64_t time = start_multi_warp_hammer_seq(rows, aggressors, it, n, k, aggressors.size(), min_delay + delay_inc, period);
    time_file << time << '\n';
    time_file.flush();
    print_time(time);
    std::cout << CLI_PREFIX << "Average time per round:" << time / it << '\n';
  }

  time_file.close();

  return 0;
}
