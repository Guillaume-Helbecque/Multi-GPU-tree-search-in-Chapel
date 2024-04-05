#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include "c_bound_simple_gpu_cuda.h"
#include "c_bound_johnson_gpu_cuda.h"


//__device__ lb2_bound_data* new_johnson_bd_data_gpu(const lb1_bound_data *const lb1_data /*, enum lb2_variant lb2_type*/)
/*{
  lb2_bound_data *b = malloc(sizeof(lb2_bound_data));

  b->nb_jobs = lb1_data->nb_jobs;
  b->nb_machines = lb1_data->nb_machines;

  enum lb2_variant lb2_type = LB2_FULL; //////////////////////////

  //depends on nb of machine pairs
  if (lb2_type == LB2_FULL)
    b->nb_machine_pairs = (b->nb_machines*(b->nb_machines-1))/2;
  if (lb2_type == LB2_NABESHIMA)
    b->nb_machine_pairs = b->nb_machines-1;
  if (lb2_type == LB2_LAGEWEG)
    b->nb_machine_pairs = b->nb_machines-1;
  if (lb2_type == LB2_LEARN)
    b->nb_machine_pairs = (b->nb_machines*(b->nb_machines-1))/2;

  b->lags = malloc(b->nb_machine_pairs*b->nb_jobs*sizeof(int));
  b->johnson_schedules = malloc(b->nb_machine_pairs*b->nb_jobs*sizeof(int));
  b->machine_pairs[0] = malloc(b->nb_machine_pairs*sizeof(int));
  b->machine_pairs[1] = malloc(b->nb_machine_pairs*sizeof(int));
  b->machine_pair_order = malloc(b->nb_machine_pairs*sizeof(int));

  return b;
}

__device__ void free_johnson_bd_data(lb2_bound_data* lb2_data)
{
  if (lb2_data) {
    free(lb2_data->lags);
    free(lb2_data->johnson_schedules);
    free(lb2_data->machine_pairs[0]);
    free(lb2_data->machine_pairs[1]);
    free(lb2_data->machine_pair_order);
    free(lb2_data);
  }
}
*/
__device__ void fill_machine_pairs_gpu(lb2_bound_data* lb2_data/*, enum lb2_variant lb2_type*/)
{
  // I do not know if I should take this out or not
  /*if (!lb2_data) {
    printf("allocate lb2_bound_data first\n");
    exit(-1);
    }*/

  enum lb2_variant lb2_type = LB2_FULL; //////////////////////////

  switch (lb2_type) {
    case LB2_FULL:
    case LB2_LEARN:
    {
      unsigned c = 0;
      for (int i = 0; i < lb2_data->nb_machines-1; i++) {
        for (int j = i+1; j < lb2_data->nb_machines; j++) {
          lb2_data->machine_pairs[0][c] = i;
          lb2_data->machine_pairs[1][c] = j;
          lb2_data->machine_pair_order[c] = c;
          c++;
        }
      }
      break;
    }
    case LB2_NABESHIMA:
    {
      for (int i = 0; i < lb2_data->nb_machines-1; i++) {
        lb2_data->machine_pairs[0][i] = i;
        lb2_data->machine_pairs[1][i] = i+1;
        lb2_data->machine_pair_order[i] = i;
      }
      break;
    }
    case LB2_LAGEWEG:
    {
      for (int i = 0; i < lb2_data->nb_machines-1; i++) {
        lb2_data->machine_pairs[0][i] = i;
        lb2_data->machine_pairs[1][i] = lb2_data->nb_machines-1;
        lb2_data->machine_pair_order[i] = i;
      }
      break;
    }
  }
}

// term q_iuv in [Lageweg'78]
__device__ void fill_lags_gpu(const int *const lb1_p_times, const lb2_bound_data *const lb2_data)
{
  const int N = lb2_data->nb_jobs;

  for (int i = 0; i < lb2_data->nb_machine_pairs; i++) {
    const int m1 = lb2_data->machine_pairs[0][i];
    const int m2 = lb2_data->machine_pairs[1][i];

    for (int j = 0; j < N; j++) {
      lb2_data->lags[i * N + j] = 0;
      for (int k = m1 + 1; k < m2; k++) {
        lb2_data->lags[i * N + j] += lb1_p_times[k * N + j];
      }
    }
  }
}

typedef struct johnson_job
{
  int job; //job-id
  int partition; //in partition 0 or 1
  int ptm1; //processing time on m1
  int ptm2; //processing time on m2
} johnson_job;

//(after partitioning) sorting jobs in ascending order with this comparator yield an optimal schedule for the associated 2-machine FSP [Johnson, S. M. (1954). Optimal two-and three-stage production schedules with setup times included.closed access Naval research logistics quarterly, 1(1), 61–68.]
__device__ int johnson_comp_gpu(const void * elem1, const void * elem2)
{
  johnson_job j1 = *((johnson_job*)elem1);
  johnson_job j2 = *((johnson_job*)elem2);

  //partition 0 before 1
  if (j1.partition == 0 && j2.partition == 1) return -1;
  if (j1.partition == 1 && j2.partition == 0) return 1;

  //in partition 0 increasing value of ptm1
  if (j1.partition == 0) {
    if (j2.partition == 1) return -1;
    return j1.ptm1 - j2.ptm1;
  }
  //in partition 1 decreasing value of ptm1
  if (j1.partition == 1) {
    if (j2.partition == 0) return 1;
    return j2.ptm2 - j1.ptm2;
  }
  return 0;
}

/*
void insertion_sort(float tab[], int size)
{
  int i,j;
  for (i=0; i<size; i++)
    for (j=size-1; j>i; j--)
      if (tab[j]<tab[j-1])
        swap(tab,j,j-1);
}

void quicksort(float t[], int left, int right)
{
  int i,sep=left+1;
  if (left<right)
    {
      for (i=left; i<=right; i++)
        if (t[i]<t[left])
          {
            if (i!=sep)
              swap(t,i,sep);
            sep++;
          }
      if ((sep-1)!=left)
        swap(t,left,sep-1);
      quicksort(t,left,sep-1);
      quicksort(t,sep,right);
    }
}
*/
//for each machine-pair (m1,m2), solve 2-machine FSP with processing times
//  p_1i = PTM[m1][i] + lags[s][i]
//  p_2i = PTM[m2][i] + lags[s][i]
//using Johnson's algorithm [Johnson, S. M. (1954). Optimal two-and three-stage production schedules with setup times included.closed access Naval research logistics quarterly, 1(1), 61–68.]
__device__ void fill_johnson_schedules_gpu(const int *const lb1_p_times, const lb2_bound_data *const lb2_data)
{
  const int N = lb2_data->nb_jobs;
  const int* const lags = lb2_data->lags;

  johnson_job *tmp = (johnson_job*)malloc(N * sizeof(johnson_job)); // Dynamically allocate memory for tmp

  // Check if memory allocation succeeded
  if(tmp == NULL) {
    // Handle memory allocation failure
    return; // Return an error code indicating failure
  }

  //for all machine-pairs
  for (int k = 0; k < lb2_data->nb_machine_pairs; k++) {
    int m1 = lb2_data->machine_pairs[0][k];
    int m2 = lb2_data->machine_pairs[1][k];

    //partition N jobs into 2 sets {j|p_1j < p_2j} and {j|p_1j >= p_2j}
    for (int i = 0; i < N; i++) {
      tmp[i].job = i;
      tmp[i].ptm1 = lb1_p_times[m1*N + i] + lags[k*N + i];
      tmp[i].ptm2 = lb1_p_times[m2*N + i] + lags[k*N + i];

      if (tmp[i].ptm1 < tmp[i].ptm2) {
        tmp[i].partition = 0;
      } else {
        tmp[i].partition = 1;
      }
    }
    //sort according to johnson's criterion
    qsort(tmp, sizeof(tmp)/sizeof(*tmp), sizeof(*tmp), johnson_comp_gpu);
    //save optimal schedule for 2-machine problem
    for (int i = 0; i < N; i++) {
      lb2_data->johnson_schedules[k*N + i] = tmp[i].job;
    }
  }
}

__device__ void set_flags_gpu(const int *const permutation, const int limit1, const int limit2, const int N, int* flags)
{
  for (int i = 0; i < N; i++)
    flags[i] = 0;
  for (int j = 0; j <= limit1; j++)
    flags[permutation[j]] = 1;
  for (int j = limit2; j < N; j++)
    flags[permutation[j]] = 1;
}

__device__ inline int compute_cmax_johnson_gpu(const int* const lb1_p_times, const lb2_bound_data* const lb2_data, const int* const flag, int *tmp0, int *tmp1, int ma0, int ma1, int ind)
{
  int nb_jobs = lb2_data->nb_jobs;

  for (int j = 0; j < nb_jobs; j++) {
    int job = lb2_data->johnson_schedules[ind*nb_jobs + j];
    // j-loop is on unscheduled jobs... (==0 if jobCour is unscheduled)
    if (flag[job] == 0) {
      int ptm0 = lb1_p_times[ma0*nb_jobs + job];
      int ptm1 = lb1_p_times[ma1*nb_jobs + job];
      int lag = lb2_data->lags[ind*nb_jobs + job];
      // add job on ma0 and ma1
      *tmp0 += ptm0;
      *tmp1 = MAX(*tmp1,*tmp0 + lag);
      *tmp1 += ptm1;
    }
  }

  return *tmp1;
}

__device__ int lb_makespan_gpu(const int* const lb1_p_times, const lb2_bound_data* const lb2_data, const int* const flag, const int* const front, const int* const back, const int minCmax)
{
  int lb = 0;

  // for all machine-pairs : O(m^2) m*(m-1)/2
  for (int l = 0; l < lb2_data->nb_machine_pairs; l++) {
    int i = lb2_data->machine_pair_order[l];

    int ma0 = lb2_data->machine_pairs[0][i];
    int ma1 = lb2_data->machine_pairs[1][i];

    int tmp0 = front[ma0];
    int tmp1 = front[ma1];

    compute_cmax_johnson_gpu(lb1_p_times, lb2_data, flag, &tmp0, &tmp1, ma0, ma1, i);

    tmp1 = MAX(tmp1 + back[ma1], tmp0 + back[ma0]);

    lb = MAX(lb, tmp1);

    if (lb > minCmax) {
      break;
    }
  }

  return lb;
}

//allows variable nb of machine pairs and get machine pair the realized best lb
__device__ int lb_makespan_learn_gpu(const int* const lb1_p_times, const lb2_bound_data* const lb2_data, const int* const flag, const int* const front, const int* const back, const int minCmax, const int nb_pairs, int *best_index)
{
  int lb = 0;

  for (int l = 0; l < nb_pairs; l++) {
    int i = lb2_data->machine_pair_order[l];

    int ma0 = lb2_data->machine_pairs[0][i];
    int ma1 = lb2_data->machine_pairs[1][i];

    int tmp0 = front[ma0];
    int tmp1 = front[ma1];

    compute_cmax_johnson_gpu(lb1_p_times, lb2_data, flag, &tmp0, &tmp1, ma0, ma1, i);

    tmp1 = MAX(tmp1 + back[ma1], tmp0 + back[ma0]);

    if (tmp1 > lb) {
      *best_index = i;
      lb = tmp1;
    }
    // lb=MAX(lb,tmp1);

    if (lb > minCmax) {
      break;
    }
  }

  return lb;
}

__device__ int lb2_bound_gpu(const lb1_bound_data* const lb1_data, const lb2_bound_data* const lb2_data, const int* const permutation, const int limit1, const int limit2,const int best_cmax)
{
  const int N = lb1_data->nb_jobs;
  const int M = lb1_data->nb_machines;

  int *front = (int*)malloc(M * sizeof(int)); // Dynamically allocate memory for tmp
  int *back = (int*)malloc(M * sizeof(int)); // Dynamically allocate memory for back
  
  // Check if memory allocation succeeded
  if(front == NULL || back == NULL) {
    // Handle memory allocation failure
    return -1; // Return an error code indicating failure
  }

  schedule_front_gpu(lb1_data, permutation, limit1, front);
  schedule_back_gpu(lb1_data, permutation, limit2, back);

  int *flags = (int*)malloc(N * sizeof(int)); // Dynamically allocate memory for flags

  // Check if memory allocation succeeded
  if(flags == NULL) {
    // Handle memory allocation failure
    return -1; // Return an error code indicating failure
  }
  
  set_flags_gpu(permutation, limit1, limit2, N, flags);

  return lb_makespan_gpu(lb1_data->p_times, lb2_data, flags, front, back, best_cmax);
}

__device__ inline void swap(int *a, int *b)
{
  int tmp = *a;
  *a = *b;
  *b = tmp;
}

__device__ void lb2_children_bounds_gpu(const lb1_bound_data* const lb1_data, const lb2_bound_data* const lb2_data, const int* const permutation, const int limit1, const int limit2, int* const lb_begin, int* const lb_end, const int best_cmax, const int direction)
{
  const int N = lb1_data->nb_jobs;
  
  int *tmp_perm = (int*)malloc(N * sizeof(int)); // Dynamically allocate memory for tmp_perm
  
  // Check if memory allocation succeeded
  if(tmp_perm == NULL) {
    // Handle memory allocation failure
    return; // Return an error code indicating failure
  }

  memcpy(tmp_perm, permutation, N*sizeof(int));

  switch (direction) {
    case -1:
     {
      for (int i = limit1 + 1; i < limit2; i++) {
        int job = tmp_perm[i];

        swap(&tmp_perm[i], &tmp_perm[limit1 + 1]);
        lb_begin[job] = lb2_bound_gpu(lb1_data, lb2_data, tmp_perm, limit1+1, limit2, best_cmax);
        swap(&tmp_perm[i], &tmp_perm[limit1 + 1]);
      }
      break;
    }
    case 0:
    {
      for (int i = limit1 + 1; i < limit2; i++) {
        int job = tmp_perm[i];

        swap(&tmp_perm[i], &tmp_perm[limit1 + 1]);
        lb_begin[job] = lb2_bound_gpu(lb1_data, lb2_data, tmp_perm, limit1+1, limit2, best_cmax);
        swap(&tmp_perm[i], &tmp_perm[limit1 + 1]);

        swap(&tmp_perm[i], &tmp_perm[limit2 - 1]);
        lb_end[job] = lb2_bound_gpu(lb1_data, lb2_data, tmp_perm, limit1, limit2-1, best_cmax);
        swap(&tmp_perm[i], &tmp_perm[limit2 - 1]);
      }
      break;
    }
    case 1:
    {
      for (int i = limit1 + 1; i < limit2; i++) {
        int job = tmp_perm[i];

        swap(&tmp_perm[i], &tmp_perm[limit2 - 1]);
        lb_end[job] = lb2_bound_gpu(lb1_data, lb2_data, tmp_perm, limit1, limit2-1, best_cmax);
        swap(&tmp_perm[i], &tmp_perm[limit2 - 1]);
      }
      break;
    }
  }
}
