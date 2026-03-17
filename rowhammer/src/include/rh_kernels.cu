#include <rh_kernels.cuh>

__device__ __forceinline__ void nops(unsigned long long cycles) {
    unsigned long long t0 = clock64();
    while (clock64() - t0 < cycles) { asm volatile(""); }
}

/**
 * @brief Sets the address byte identified by the thread offset to value.
 *
 * @param addr_arr array of GPU addresses
 * @param value 8-bit byte value
 * @param b_len maximum offset
 */
__global__ void set_address_kernel(uint8_t *addr_arr, uint64_t value,
                                   uint64_t b_len)
{
  int offset = threadIdx.x + blockIdx.x * blockDim.x;
  if (offset < b_len)
  {
    asm volatile("{\n\t"
                 "st.u8.global.wt [%0], %1;\n\t"
                 "}" ::"l"(addr_arr + offset),
                 "l"(value));
  }
}

/**
 * @brief Discard the given address addr for the step size, e.g.
 * if step=256, we will call discard on addr and addr + 128
 *
 * @param addr GPU address value
 * @param step step size
 */
__global__ void clear_address_kernel(uint8_t *addr, uint64_t step)
{
  for (uint64_t i = 0; i < step; i += 128)
    asm volatile("{\n\t"
                 "discard.global.L2 [%0], 128;\n\t"
                 "}" ::"l"(addr));
}

/**
 * @brief Verify that a particular byte is the expected target value.
 *
 * @param addr_arr array of GPU addresses
 * @param target expected value of the byte
 * @param b_len number of bytes in total, used for indexing
 * @return @param has_diff return value for host to know whether a difference occured
 */
__global__ void verify_result_kernel(uint8_t **addr_arr, uint64_t target,
  uint64_t b_len, bool *has_diff, int *row_ids)
{
  uint64_t value;

  int addr_id = (threadIdx.x + blockIdx.x * blockDim.x) / b_len;
  int byte_id = (threadIdx.x + blockIdx.x * blockDim.x) % b_len;


  asm volatile("{\n\t"
                "discard.global.L2 [%0], 128;\n\t"
                "}"
                : "=l"(value)
                : "l"(*(addr_arr + addr_id) + byte_id));

  asm volatile("{\n\t"
                "ld.u8.global.volatile %0, [%1];\n\t"
                "}"
                : "=l"(value)
                : "l"(*(addr_arr + addr_id) + byte_id));
  

  // __syncthreads();

  int diff = target ^ value; // XOR


  // printf("addr: %p Addr ID %d, Byte ID %d: Read Value = 0x%02lx, Target Value = 0x%02lx\n", *(addr_arr + addr_id) + byte_id, addr_id, byte_id, value, target);

  if (diff != 0)
  {
    if (has_diff) *has_diff = true;
    int diff_count = __popcll(diff);
    int bit_pos = __ffsll(diff) - 1;
    int from_bit = (target >> bit_pos) & 1;
    int to_bit   = (value  >> bit_pos) & 1;
    
    printf("\nBit-flip detected!\n");
    printf("Observed %d bit-flip(s) in Row %d, Byte %d, Address %p\n",
           diff_count, row_ids[addr_id], byte_id, 
           *(addr_arr + addr_id) + byte_id);
    printf("The %dth bit flipped from %d to %d (Data Pattern: 0x%02lx -> 0x%02lx)\n\n", bit_pos, from_bit, to_bit, target, value);

  }
}

/**
 * @brief Evict the L2 Cache by iterating through a large portion of the memory space
 *
 * @param addr start address of the GPU memory space
 * @param size size of the memory space to iterate
 */
__global__ void evict_kernel(uint8_t *addr, uint64_t size)
{ 
  uint64_t temp, ret = 0;
  uint64_t offset = threadIdx.x * size;

  for (int i = 0 ; i < size; i += 128) {
    asm volatile("{\n\t"
               "ld.u8.global.volatile %0, [%1];\n\t"
               "}"
               : "=l"(temp)
               : "l"(addr + offset + i));
    ret += temp;
  }
  if (threadIdx.x == 0) printf("%ld\n", ret);
}

/**
 * @brief Naive implementation of Rowhammer. Every thread accesses a unique address
 * in addr_arr for count amount of times.
 *
 * @param addr_arr array of GPU addresses to hammer.
 * @param count number of times to iterate.
 * @return @param time spent for the entire hammering.
 */
__global__ void simple_hammer_kernel(uint8_t **addr_arr, uint64_t count,
                                     uint64_t *time)
{
  uint64_t temp __attribute__((unused));
  uint64_t ce, cs;
  uint8_t *addr = *(addr_arr + threadIdx.x);

  cs = clock64();
  for (; count--;)
  {
    asm volatile("{\n\t"
                 "discard.global.L2 [%0], 128;\n\t"
                 "}" ::"l"(addr));

    asm volatile("{\n\t"
                 "ld.u8.global.volatile %0, [%1];\n\t"
                 "}"
                 : "=l"(temp)
                 : "l"(addr));
  }
  ce = clock64();
  *time = ce - cs;
}

// -delay 1280 
__global__ void warp_simple_hammer_kernel_seq(uint8_t **addr_arr, uint64_t count, 
                                          uint64_t n, uint64_t k, uint64_t len, 
                                          uint64_t delay, uint64_t period, 
                                          uint64_t* time)
{
  /* n: warp, k: threads */
  uint64_t ret = 0, temp, cs, ce;
  uint64_t warpId = threadIdx.x / 32;
  uint64_t threadId_in_warp = threadIdx.x % 32;


  if (warpId < n && threadId_in_warp < k && threadId_in_warp + warpId * k < len)
  {
    uint64_t local_delay = (warpId == 0) ? (delay - 100) : delay; 

    // if(warpId == 0 && threadId_in_warp > 1) return;

    uint8_t *addr = *(addr_arr + threadId_in_warp + warpId * k);
    // printf("Warp %ld, Thread %ld, Address %p\n", warpId, threadId_in_warp, addr);
    asm volatile("{\n\t"
               "discard.global.L2 [%0], 128;\n\t"
               "}" ::"l"(addr));

    // Use warp 0 thread 0 as the timer to avoid extra delays
    if (threadIdx.x == 0)
      cs = clock64();

    __syncthreads();
    // for (;count--;)
    for (uint64_t iter = 0; iter < count; iter++) 
    {
      for (uint64_t i = period; i--;){
        if(warpId == 0) nops(100);
        asm volatile("{\n\t"
                    "discard.global.L2 [%1], 128;\n\t"
                    "ld.u8.global.volatile %0, [%1];\n\t"
                    "}"
                    : "=l"(temp)
                    : "l"(addr));
        __threadfence_block();
      }
      nops(local_delay);
      // for( uint64_t i = 0; i < delay; i++){
      //   ret += temp;
      // }
    }

    __syncthreads();
    if (threadIdx.x == 0)
      ce = clock64();
    __syncthreads();
    if (threadIdx.x == 0){
      printf("%u, %ld, %ld, %ld\n", threadIdx.x, warpId, temp, ret);
             * time = ce - cs;
    }
  }
}


__global__ void multi_bank_hammer_kernel(uint8_t **addr_arr, uint64_t count, uint64_t n, uint64_t k, uint64_t len, uint64_t *delays, uint64_t period, uint64_t* time){
  	/* n: warp, k: threads */
	uint64_t ret = 0, temp, cs, ce;
	uint64_t localWarpId = threadIdx.x / 32;
	uint64_t localThreadId = threadIdx.x % 32;  
	uint64_t blockId = blockIdx.x; 

  uint64_t delay = delays[blockId];
  // printf("Block ID: %ld, Delay: %ld, period: %ld, n: %ld, k: %ld\n", blockId, delay, period, n, k);



	if (blockId < gridDim.x && localWarpId < n && localThreadId < k)
	{
		uint64_t local_delay = (localWarpId == 0) ? (delay - 100) : delay;
		uint8_t *addr = *(addr_arr + (localThreadId + localWarpId * k) * gridDim.x + blockId);


		asm volatile("{\n\t"
			"discard.global.L2 [%0], 128;\n\t"
			"}" ::"l"(addr));

		// Use warp 0 thread 0 as the timer to avoid extra delays
		if ( threadIdx.x == 0)
			cs = clock64();

		__syncthreads();
		// for (;count--;)
    for (uint64_t iter = 0; iter < count; iter++) 
		{
			for (uint64_t i = period; i--;){
        if(localWarpId == 0) nops(100);

				asm volatile("{\n\t"
				"discard.global.L2 [%1], 128;\n\t"
				"ld.u8.global.volatile %0, [%1];\n\t"
				"}"
				: "=l"(temp)
				: "l"(addr));
				__threadfence_block();
			}
      nops(local_delay);
		}

		__syncthreads();
		if (threadIdx.x == 0)
			ce = clock64();
		__syncthreads();
		if (threadIdx.x == 0){
			printf("%u, %ld, %ld, %ld\n", threadIdx.x, localWarpId, temp, ret);
			time[blockId] = ce - cs;
		}
		
	}
}