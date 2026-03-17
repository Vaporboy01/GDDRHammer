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
#include <chrono>
#include <random>
#include <algorithm>
#include <string>
#include <sstream>
#include <cmath>

std::string CLI_PREFIX = "(multi-bank-hammer): ";

int main(int argc, char *argv[])
{
  if (argc < 4) {
  std::cout << CLI_PREFIX << "Usage: " << argv[0] 
        << " <num_banks> <row_set_file1> <row_set_file2> ... <num_aggressors> <step> <iterations> "
        << "<min_rowid> <max_rowid> <row_step> <skip_step> <mem_size> <num_warp> <num_thread> "
        << "<delay1> <delay2> ... <run_time_seconds> <round> <count_iter> <num_rows> <vic_pat> <agg_pat> <output_file>" << std::endl;
    return -1;
  }

  const uint64_t num_banks = std::stoull(argv[1]);
  const uint64_t num_victim = std::stoull(argv[2 + num_banks]);
  const uint64_t step = std::stoull(argv[3 + num_banks]);
  const uint64_t it = std::stoull(argv[4 + num_banks]);
  const uint64_t min_rowId = std::stoull(argv[5 + num_banks]);
  const uint64_t max_rowId = std::stoull(argv[6 + num_banks]);
  const uint64_t row_step = std::stoull(argv[7 + num_banks]);
  const uint64_t skip_step = std::stoull(argv[8 + num_banks]);
  const uint64_t size = std::stoull(argv[9 + num_banks]);
  const uint64_t n = std::stoull(argv[10 + num_banks]);
  const uint64_t k = std::stoull(argv[11 + num_banks]);
  // New argument ordering: after per-bank delays we accept a runtime (seconds)
  const uint64_t period = std::stoull(argv[13 + num_banks + num_banks]);
  const uint64_t count_iter = std::stoull(argv[14 + num_banks + num_banks]);
  const uint64_t num_rows = std::stoull(argv[15 + num_banks + num_banks]);
  const uint64_t vic_pat = std::stoull(argv[16 + num_banks + num_banks], nullptr, 16);
  const uint64_t agg_pat = std::stoull(argv[17 + num_banks + num_banks], nullptr, 16);
  std::ofstream bitflip_file(argv[18 + num_banks + num_banks]);

  // runtime in seconds (inserted by caller). If zero, fall back to iterating min->max once.
  const uint64_t run_seconds = std::stoull(argv[12 + num_banks + num_banks]);

//   Read delays for each bank
  std::vector<uint64_t> delays;
  for (uint64_t i = 0; i < num_banks; i++) {
    delays.push_back(std::stoull(argv[12 + num_banks + i]));
    printf("delay: %ld\n", delays[i]);
  }

  fprintf(stderr, "num_banks: %ld\n", num_banks);
  fprintf(stderr, "num_victim: %ld\n", num_victim);
  fprintf(stderr, "step: %ld\n", step);
  fprintf(stderr, "it: %ld\n", it);
  fprintf(stderr, "min_rowId: %ld\n", min_rowId);
  fprintf(stderr, "max_rowId: %ld\n", max_rowId);
  fprintf(stderr, "row_step: %ld\n", row_step);
  fprintf(stderr, "skip_step: %ld\n", skip_step);
  fprintf(stderr, "size: %ld\n", size);
  fprintf(stderr, "n: %ld\n", n);
  fprintf(stderr, "k: %ld\n", k);
  fprintf(stderr, "period: %ld\n", period);
  fprintf(stderr, "count_iter: %ld\n", count_iter);
  

  /* Read the row sets for all banks */
  std::vector<RowList> all_rows;
  uint8_t *layout;
  cudaMalloc(&layout, size);
  
  for (uint64_t bank_idx = 0; bank_idx < num_banks; bank_idx++) {
    std::ifstream row_set_file(argv[2 + bank_idx]);
    if (!row_set_file.is_open()) {
      std::cout << CLI_PREFIX << "Error: Cannot open row set file " << argv[2 + bank_idx] << std::endl;
      return -1;
    }
    
    RowList rows = read_row_from_file(row_set_file, layout);
    row_set_file.close();
    all_rows.push_back(rows);
    
    if ((int64_t)(rows.size() - 2 * num_victim - 1) < 0) {
      std::cout << CLI_PREFIX << "Error: Bank " << bank_idx 
                << " - Not enough rows to generate the specified victims." << '\n';
      return -1;
    }
  }


  std::cout << CLI_PREFIX << "Layout address: " << static_cast<void*>(layout) << '\n';
  std::cout << std::hex;
  std::cout << CLI_PREFIX << "Victim pattern: " << vic_pat << '\n';
  std::cout << CLI_PREFIX << "Aggressor pattern: " << agg_pat << '\n';
  std::cout << std::dec;

  std::cout << std::endl;

  /* Treat all rows as victim rows for each bank */
  std::vector<std::vector<uint64_t>> all_vics;
  for (uint64_t bank_idx = 0; bank_idx < num_banks; bank_idx++) {
    std::vector<uint64_t> bank_vics(num_rows);
    std::iota(bank_vics.begin(), bank_vics.end(), 0);
    all_vics.push_back(bank_vics);

    // Set victim pattern for this bank
    set_rows(all_rows[bank_idx], bank_vics, vic_pat, step);
  }
  cudaDeviceSynchronize();

  /* Dummy hammer to keep timing consistent, due to device startup time */
  for (uint64_t bank_idx = 0; bank_idx < num_banks; bank_idx++) {
    start_simple_hammer(all_rows[bank_idx], all_vics[bank_idx], 1);
  }
  const uint64_t rng_seed_env = 0ULL;
  const uint64_t rng_seed = (rng_seed_env != 0ULL)
                              ? rng_seed_env
                              : static_cast<uint64_t>(std::chrono::high_resolution_clock::now().time_since_epoch().count());
  std::mt19937_64 rng(rng_seed);
  std::uniform_int_distribution<uint64_t> dist_row(0ULL, num_rows - 1);

  auto gen_far_aggs = [&](const std::vector<uint64_t>& exclude_list, uint64_t need_cnt) {
    std::vector<uint64_t> far;
    far.reserve(need_cnt);
    std::uniform_int_distribution<uint64_t> dist(min_rowId, max_rowId > 0 ? max_rowId - 1 : num_rows - 1);
    while (far.size() < need_cnt) {
        uint64_t r = dist(rng);

        bool skip = false;
        for (auto ex : exclude_list) {
            if (r == ex) { skip = true; break; }
            int64_t dr_a = static_cast<int64_t>(r) - static_cast<int64_t>(ex);
            if (std::llabs(dr_a) < 10000) { skip = true; break; }
        }
        if (skip) continue;
        if (std::find(far.begin(), far.end(), r) != far.end()) continue;
        far.push_back(r);
    }
    return far;
  };
  // For time-limited runs we track per-bank total flip counts
  std::vector<int> bitflip_count(num_banks, 0);

  /* Running multi-bank hammer */
  std::cout << CLI_PREFIX << "Starting multi-bank hammer..." << std::endl;
  
  auto run_start = std::chrono::high_resolution_clock::now();
  auto elapsed_seconds = [&run_start]() {
    return std::chrono::duration_cast<std::chrono::seconds>(std::chrono::high_resolution_clock::now() - run_start).count();
  };

  // outer loop: keep iterating over the row range until run_seconds expires (if run_seconds>0), otherwise iterate once
  uint64_t no_attacks = 0;
  for (;;) {
    for (uint64_t i = min_rowId; i < max_rowId; i += skip_step) {
      if (run_seconds > 0 && elapsed_seconds() >= static_cast<int64_t>(run_seconds)) break;

      std::vector<std::vector<uint64_t>> all_victims;
      std::vector<std::vector<uint64_t>> all_aggressors;

      // Generate victims and aggressors for each bank
      for (uint64_t bank_idx = 0; bank_idx < num_banks; bank_idx++) {
        std::vector<uint64_t> aggressors;

        // Pick first two aggressors as an adjacent random row pair
        uint64_t rand_base = 0;
        if (max_rowId > min_rowId + 1) {
          std::uniform_int_distribution<uint64_t> dist(min_rowId, max_rowId - 1);
          rand_base = dist(rng);
        } else {
          // fallback to using the current i
          rand_base = i;
        }

        aggressors.reserve(num_victim);
        if (num_victim >= 1) aggressors.push_back(rand_base);
        if (num_victim >= 2) aggressors.push_back(rand_base + 1);

        uint64_t need_more = (num_victim > 2 ? (num_victim - 2) : 0);
        if (need_more > 0) {
          std::vector<uint64_t> exclude = {rand_base, rand_base + 1};
          auto far = gen_far_aggs(exclude, need_more);
          aggressors.insert(aggressors.end(), far.begin(), far.end());
        }

        all_aggressors.push_back(aggressors);
      }
    
    // Print victims and aggressors for each bank
    for (uint64_t bank_idx = 0; bank_idx < num_banks; bank_idx++) {
      std::cout << CLI_PREFIX << "Bank " << bank_idx << " - Chosen Aggressors:" << vector_str(all_aggressors[bank_idx]) << std::endl;
    }
    std::cout << CLI_PREFIX << "==========================================================" << std::endl;

    
    
    for (int j = 0; j < count_iter; j++) {

      std::cout << CLI_PREFIX << "Aggressor Iteration: " << j << std::endl;
      auto start_loop = std::chrono::high_resolution_clock::now();


      /* Sets the row and evict cache to store it in the memory. */
      for (uint64_t bank_idx = 0; bank_idx < num_banks; bank_idx++) {
        set_rows(all_rows[bank_idx], all_vics[bank_idx], vic_pat, step);
        cudaDeviceSynchronize();
        set_rows(all_rows[bank_idx], all_aggressors[bank_idx], agg_pat, step);
        cudaDeviceSynchronize();
      }

      evict_L2cache(layout);
      cudaDeviceSynchronize();

      auto start_hammer = std::chrono::high_resolution_clock::now();

      /* Start the hammering and measure the time */

      uint64_t *time = start_multi_bank_hammer_seq(all_rows, all_aggressors, it, n, k, all_aggressors[0].size(), delays, period);
      
      // Ensure the hammer kernel is completely finished before proceeding
      cudaDeviceSynchronize();


      for (int bank_idx_inner = 0; bank_idx_inner < num_banks; bank_idx_inner++) {
        print_time(time[bank_idx_inner]);
        std::cout << CLI_PREFIX << "Bank " << bank_idx_inner << " time: " << toNS(time[bank_idx_inner]) / it << std::endl;
      }

      auto end_hammer = std::chrono::high_resolution_clock::now();

      /* Verify result */
      evict_L2cache(layout);
      cudaDeviceSynchronize();

      // Check for bitflips in all banks
      std::vector<bool> bitflip_results;
      for (uint64_t bank_idx = 0; bank_idx < num_banks; bank_idx++) {
        // Comment out the first line and uncomment the following line to check 
        // for bit-flips in the nearby neighborhood to reduce hammering time.
        bool res = verify_all_content(all_rows[bank_idx], all_vics[bank_idx], all_aggressors[bank_idx], step, vic_pat);

        bitflip_results.push_back(res);
        
        std::cout << CLI_PREFIX << "Bank " << bank_idx << " - Bit-flip in victim rows: " 
                                << (res ? "Observed Bit-Flip" : "No Bit-Flip") << std::endl;
        if (res) bitflip_count[bank_idx]++;
      }

      /* Clean up and prepare for next launch*/
      cudaDeviceSynchronize();
      auto end_loop = std::chrono::high_resolution_clock::now();

      std::chrono::duration<double, std::milli> duration_evict = start_hammer - start_loop;
      std::chrono::duration<double, std::milli> duration_hammer = end_hammer - start_hammer;
      std::chrono::duration<double, std::milli> duration_verify = end_loop - end_hammer;
      std::chrono::duration<double, std::milli> duration_total = end_loop - start_loop;
      std::cout << CLI_PREFIX << "Evict time: " << duration_evict.count() << " ms" << std::endl;
      std::cout << CLI_PREFIX << "Hammer time: " << duration_hammer.count() << " ms" << std::endl;
      std::cout << CLI_PREFIX << "Verify time: " << duration_verify.count() << " ms" << std::endl;
      std::cout << CLI_PREFIX << "Total time: " << duration_total.count() << " ms" << std::endl;

      std::cout << CLI_PREFIX << "==========================================================" << std::endl;
      no_attacks++;
    }


  }

  std::cout << CLI_PREFIX << "Multi-bank hammer completed." << std::endl;
  
  // Calculate total bitflips across all banks
  int total_bitflips = 0;
  for (uint64_t bank_idx = 0; bank_idx < num_banks; bank_idx++) {
    int bank_bitflips = bitflip_count[bank_idx];
    std::cout << CLI_PREFIX << "Bank " << bank_idx << " total bitflips: " << bank_bitflips << std::endl;
    total_bitflips += bank_bitflips;
  }
  std::cout << CLI_PREFIX << "Total bitflips detected across all banks: " << total_bitflips << std::endl;
  std::cout << CLI_PREFIX << "Total attacks attempted: " << no_attacks << std::endl;
  return 0;


}

}
