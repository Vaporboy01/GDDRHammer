#include <stdint.h>
#include <rh_utils.cuh>

#ifndef GPU_ROWHAMMER_RH_IMPLS_CUH
#define GPU_ROWHAMMER_RH_IMPLS_CUH

uint64_t start_simple_hammer(RowList &rows, std::vector<uint64_t> &agg_vec,
                             uint64_t it);

uint64_t start_multi_warp_hammer_seq(RowList &rows, std::vector<uint64_t> &agg_vec,
                                  uint64_t it, uint64_t n, uint64_t k, uint64_t len, uint64_t delay, uint64_t period);
uint64_t *start_multi_bank_hammer_seq(std::vector<RowList> &rows, std::vector<std::vector<uint64_t>> &agg_vec, uint64_t it, uint64_t n, uint64_t k, uint64_t len, std::vector<uint64_t> delays, uint64_t period);

#endif /* GPU_ROWHAMMER_RH_IMPLS_CUH */