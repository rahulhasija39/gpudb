#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <string.h>
#include <cuda.h>
#include <time.h>
#include "../include/common.h"
#include "../include/hashJoin.h"
#include "../include/gpuCudaLib.h"
#include "scanImpl.cu"


__global__ static void count_hash_num(char *dim, long  inNum,int *num){
	int stride = blockDim.x * gridDim.x;
	int offset = blockIdx.x * blockDim.x + threadIdx.x;

	for(int i=offset;i<inNum;i+=stride){
		int joinKey = ((int *)dim)[i]; 
		int hKey = joinKey & (HSIZE-1);
		atomicAdd(&(num[hKey]),1);
	}
}

__global__ static void build_hash_table(char *dim, long inNum, int *psum, char * bucket){

	int stride = blockDim.x * gridDim.x;
	int offset = blockIdx.x * blockDim.x + threadIdx.x;

	for(int i=offset;i<inNum;i+=stride){
		int joinKey = ((int *) dim)[i]; 
		int hKey = joinKey & (HSIZE-1);
		int pos = atomicAdd(&psum[hKey],1) * 2;
		((int*)bucket)[pos] = joinKey;
		pos += 1;
		int dimId = i+1;
		((int*)bucket)[pos] = dimId;
	}

}

// if the foreign key is compressed using dict-encoding, call this method to generate dict filter first
__global__ static void count_join_result_dict(int *num, int* psum, char* bucket, char* fact, int dNum, int* dictFilter){

	int stride = blockDim.x * gridDim.x;
	int offset = blockIdx.x*blockDim.x + threadIdx.x;

	struct dictHeader *dheader;
	dheader = (struct dictHeader *) fact;
	
	for(int i=offset;i<dNum;i+=stride){
		int fkey = dheader->hash[i];
		int hkey = fkey &(HSIZE-1);
		int keyNum = num[hkey];

		for(int j=0;j<keyNum;j++){
			int pSum = psum[hkey];
			int dimKey = ((int *)(bucket))[2*j + 2*pSum];
			int dimId = ((int *)(bucket))[2*j + 2*pSum + 1];
			if( dimKey == fkey){
				dictFilter[i] = dimId;
				break;
			}
		}
	}

}

// transform the dictionary filter to the final filter than can be used to generate the result

__global__ static void transform_dict_filter(int * dictFilter, char *fact, long tupleNum, int dNum,  int * filter){

	int stride = blockDim.x * gridDim.x;
	int offset = blockIdx.x*blockDim.x + threadIdx.x;

	struct dictHeader *dheader;
	dheader = (struct dictHeader *) fact;

	int byteNum = dheader->bitNum/8;
	int numInt = (tupleNum * byteNum +sizeof(int) - 1) / sizeof(int)  ; 

	for(long i=offset; i<numInt; i += stride){
		int tmp = ((int *)(fact + sizeof(struct dictHeader)))[i];

		for(int j=0; j< sizeof(int)/byteNum; j++){
			int fkey = 0;
			memcpy(&fkey, ((char *)&tmp) + j*byteNum, byteNum);

			filter[i* sizeof(int)/byteNum + j] = dictFilter[fkey];
		}
	}
}


// count the number that is not zero in the filter
__global__ static void filter_count(long tupleNum, int * count, int * factFilter){

	int lcount = 0;
	int stride = blockDim.x * gridDim.x;
	long offset = blockIdx.x*blockDim.x + threadIdx.x;

	for(long i=offset; i<tupleNum; i+=stride){
		if(factFilter[i] !=0)
			lcount ++;
	}
	count[offset] = lcount;
}


// if the foreign key is compressed using rle, call this method to generate join filter
__global__ static void count_join_result_rle(int* num, int* psum, char* bucket, char* fact, long tupleNum, long tupleOffset,  int * factFilter){

	int stride = blockDim.x * gridDim.x;
	long offset = blockIdx.x*blockDim.x + threadIdx.x;

	struct rleHeader *rheader = (struct rleHeader *)fact;
	int dNum = rheader->dictNum;

	for(int i=offset; i<dNum; i += stride){
		int fkey = ((int *)(fact+sizeof(struct rleHeader)))[i];
		int fcount = ((int *)(fact+sizeof(struct rleHeader)))[i + dNum];
		int fpos = ((int *)(fact+sizeof(struct rleHeader)))[i + 2*dNum];

		if((fcount + fpos) < tupleOffset)
			continue;

		if(fpos >= (tupleOffset + tupleNum))
			break;

		int hkey = fkey &(HSIZE-1);
		int keyNum = num[hkey];

		for(int j=0;j<keyNum;j++){

			int pSum = psum[hkey];
			int dimKey = ((int *)(bucket))[2*j + 2*pSum];
			int dimId = ((int *)(bucket))[2*j + 2*pSum + 1];

			if( dimKey == fkey){

				if(fpos < tupleOffset){
					int tcount = fcount + fpos - tupleOffset;
					if(tcount > tupleNum)
						tcount = tupleNum;
					for(int k=0;k<tcount;k++)
						factFilter[k] = dimId;

				}else if((fpos + fcount) > (tupleOffset + tupleNum)){
					int tcount = tupleOffset + tupleNum - fpos ;
					for(int k=0;k<tcount;k++)
						factFilter[fpos+k-tupleOffset] = dimId;
				}else{
					for(int k=0;k<fcount;k++)
						factFilter[fpos+k-tupleOffset] = dimId;

				}

				break;
			}
		}
	}

}

// if the foreign key is not compressed at all, call this method to generate join filter
__global__ static void count_join_result(int* num, int* psum, char* bucket, char* fact, long inNum, int* count, int * factFilter){
	int lcount = 0;
	int stride = blockDim.x * gridDim.x;
	long offset = blockIdx.x*blockDim.x + threadIdx.x;

	for(int i=offset;i<inNum;i+=stride){
		int fkey = ((int *)(fact))[i];
		int hkey = fkey &(HSIZE-1);
		int keyNum = num[hkey];

		for(int j=0;j<keyNum;j++){
			int pSum = psum[hkey];
			int dimKey = ((int *)(bucket))[2*j + 2*pSum];
			int dimId = ((int *)(bucket))[2*j + 2*pSum + 1];
			if( dimKey == fkey){
				lcount ++;
				factFilter[i] = dimId;
				break;
			}
		}
	}

	__syncthreads();
	count[offset] = lcount;
}

// unpack the column that is compresses using Run Length Encoding

__global__ void static unpack_rle(char * fact, char * rle, long tupleNum, long tupleOffset, int dNum){

	int offset = blockIdx.x*blockDim.x + threadIdx.x;
	int stride = blockDim.x * gridDim.x;

	for(int i=offset; i<dNum; i+=stride){

		int fvalue = ((int *)(fact+sizeof(struct rleHeader)))[i];
		int fcount = ((int *)(fact+sizeof(struct rleHeader)))[i + dNum];
		int fpos = ((int *)(fact+sizeof(struct rleHeader)))[i + 2*dNum];

		if((fcount + fpos) < tupleOffset)
			continue;

		if(fpos >= (tupleOffset + tupleNum))
			break;

		if(fpos < tupleOffset){
			int tcount = fcount + fpos - tupleOffset;
			if(tcount > tupleNum)
				tcount = tupleNum;
			for(int k=0;k<tcount;k++){
				((int*)rle)[k] = fvalue; 
			}

		}else if ((fpos + fcount) > (tupleOffset + tupleNum)){
			int tcount = tupleNum  + tupleOffset - fpos;
			for(int k=0;k<tcount;k++){
				((int*)rle)[fpos-tupleOffset + k] = fvalue;
			}

		}else{
			for(int k=0;k<fcount;k++){
				((int*)rle)[fpos-tupleOffset + k] = fvalue;
			}
		}
	}
}

// generate psum for RLE compressed column based on filter
// current implementaton: scan through rle element and find the correponsding element in the filter

__global__ void static rle_psum(int *count, char * fact,  long  tupleNum, long tupleOffset, int * filter){

	int offset = blockIdx.x*blockDim.x + threadIdx.x;
	int stride = blockDim.x * gridDim.x;

	struct rleHeader *rheader = (struct rleHeader *) fact;
	int dNum = rheader->dictNum;

	for(int i= offset; i<dNum; i+= stride){

		int fcount = ((int *)(fact+sizeof(struct rleHeader)))[i + dNum];
		int fpos = ((int *)(fact+sizeof(struct rleHeader)))[i + 2*dNum];
		int lcount= 0;

		if((fcount + fpos) < tupleOffset)
			continue;

		if(fpos >= (tupleOffset + tupleNum))
			break;

		if(fpos < tupleOffset){
			int tcount = fcount + fpos - tupleOffset;
			if(tcount > tupleNum)
				tcount = tupleNum;
			for(int k=0;k<tcount;k++){
				if(filter[k]!=0)
					lcount++;
			}
			count[i] = lcount;

		}else if ((fpos + fcount) > (tupleOffset + tupleNum)){
			int tcount = tupleNum  + tupleOffset - fpos;
			for(int k=0;k<tcount;k++){
				if(filter[fpos-tupleOffset + k]!=0)
					lcount++;
			}
			count[i] = lcount;

		}else{
			for(int k=0;k<fcount;k++){
				if(filter[fpos-tupleOffset + k]!=0)
					lcount++;
			}
			count[i] = lcount;
		}
	}

}

//filter the column that is compressed using Run Length Encoding
//current implementation:

__global__ void static joinFact_rle(int *resPsum, char * fact,  int attrSize, long  tupleNum, long tupleOffset, int * filter, char * result){

	int startIndex = blockIdx.x*blockDim.x + threadIdx.x;
	int stride = blockDim.x * gridDim.x;

	struct rleHeader *rheader = (struct rleHeader *) fact;
	int dNum = rheader->dictNum;

	for(int i = startIndex; i<dNum; i += stride){
		int fkey = ((int *)(fact+sizeof(struct rleHeader)))[i];
		int fcount = ((int *)(fact+sizeof(struct rleHeader)))[i + dNum];
		int fpos = ((int *)(fact+sizeof(struct rleHeader)))[i + 2*dNum];

		if((fcount + fpos) < tupleOffset)
			continue;

		if(fpos >= (tupleOffset + tupleNum))
			break;

		if(fpos < tupleOffset){
			int tcount = fcount + fpos - tupleOffset;
			int toffset = resPsum[i];
			for(int j=0;j<tcount;j++){
				if(filter[j] != 0){
					((int*)result)[toffset] = fkey ;
					toffset ++;
				}
			}

		}else if ((fpos + fcount) > (tupleOffset + tupleNum)){
			int tcount = tupleOffset + tupleNum - fpos;
			int toffset = resPsum[i];
			for(int j=0;j<tcount;j++){
				if(filter[fpos-tupleOffset+j] !=0){
					((int*)result)[toffset] = fkey ;
					toffset ++;
				}
			}

		}else{
			int toffset = resPsum[i];
			for(int j=0;j<fcount;j++){
				if(filter[fpos-tupleOffset+j] !=0){
					((int*)result)[toffset] = fkey ;
					toffset ++;
				}
			}
		}
	}

}

// filter the column in the fact table that is compressed using dictionary encoding
__global__ void static joinFact_dict_other(int *resPsum, char * fact,  char *dict, int byteNum,int attrSize, long  num, int * filter, char * result){

	int startIndex = blockIdx.x*blockDim.x + threadIdx.x;
	int stride = blockDim.x * gridDim.x;
	long localOffset = resPsum[startIndex] * attrSize;

	struct dictHeader *dheader = (struct dictHeader*)dict;

	for(long i=startIndex;i<num;i+=stride){
		if(filter[i] != 0){
			int key = 0;
			memcpy(&key, fact + i* byteNum, byteNum);
			memcpy(result + localOffset, &dheader->hash[key], attrSize);
			localOffset += attrSize;
		}
	}
}

__global__ void static joinFact_dict_int(int *resPsum, char * fact, char *dict, int byteNum, int attrSize, long  num, int * filter, char * result){

	int startIndex = blockIdx.x*blockDim.x + threadIdx.x;
	int stride = blockDim.x * gridDim.x;
	long localCount = resPsum[startIndex];

	struct dictHeader *dheader = (struct dictHeader*)dict;

	for(long i=startIndex;i<num;i+=stride){
		if(filter[i] != 0){
			int key = 0;
			memcpy(&key, fact + i* byteNum, byteNum);
			((int*)result)[localCount] = dheader->hash[key];
			localCount ++;
		}
	}
}

__global__ void static joinFact_other(int *resPsum, char * fact,  int attrSize, long  num, int * filter, char * result){

	int startIndex = blockIdx.x*blockDim.x + threadIdx.x;
	int stride = blockDim.x * gridDim.x;
	long localOffset = resPsum[startIndex] * attrSize;

	for(long i=startIndex;i<num;i+=stride){
		if(filter[i] != 0){
			memcpy(result + localOffset, fact + i*attrSize, attrSize);
			localOffset += attrSize;
		}
	}
}

__global__ void static joinFact_other_soa(int *resPsum, char * fact,  int attrSize, long  tupleNum, long resultNum, int * filter, char * result){

	int startIndex = blockIdx.x*blockDim.x + threadIdx.x;
	int stride = blockDim.x * gridDim.x;
	long tNum = resPsum[startIndex];

	for(long i=startIndex;i<tupleNum;i+=stride){
		if(filter[i] != 0){
			for(int j=0;j<attrSize;j++){
				long inPos = j*tupleNum + i;
				long outPos = j*resultNum + tNum; 
				result[outPos] = fact[inPos];
			}
		}
	}
}

__global__ void static joinFact_int(int *resPsum, char * fact,  int attrSize, long  num, int * filter, char * result){

	int startIndex = blockIdx.x*blockDim.x + threadIdx.x;
	int stride = blockDim.x * gridDim.x;
	long localCount = resPsum[startIndex];

	for(long i=startIndex;i<num;i+=stride){
		if(filter[i] != 0){
			((int*)result)[localCount] = ((int *)fact)[i];
			localCount ++;
		}
	}
}

__global__ void static joinDim_rle(int *resPsum, char * dim, int attrSize, long tupleNum, long tupleOffset, int * filter, char * result){

	int startIndex = blockIdx.x*blockDim.x + threadIdx.x;
	int stride = blockDim.x * gridDim.x;
	long localCount = resPsum[startIndex];

	struct rleHeader *rheader = (struct rleHeader *) dim;
	int dNum = rheader->dictNum;

	for(int i = startIndex; i<tupleNum; i += stride){
		int dimId = filter[i];
		if(dimId != 0){
			for(int j=0;j<dNum;j++){
				int dkey = ((int *)(dim+sizeof(struct rleHeader)))[j];
				int dcount = ((int *)(dim+sizeof(struct rleHeader)))[j + dNum];
				int dpos = ((int *)(dim+sizeof(struct rleHeader)))[j + 2*dNum];

				if(dpos == dimId || ((dpos < dimId) && (dpos + dcount) > dimId)){
					((int*)result)[localCount] = dkey ;
					localCount ++;
					break;
				}

			}
		}
	}
}

__global__ void static joinDim_dict_other(int *resPsum, char * dim, char *dict, int byteNum, int attrSize, long num,int * filter, char * result){

	int startIndex = blockIdx.x*blockDim.x + threadIdx.x;
	int stride = blockDim.x * gridDim.x;
	long localOffset = resPsum[startIndex] * attrSize;

	struct dictHeader *dheader = (struct dictHeader*)dict;

	for(long i=startIndex;i<num;i+=stride){
		int dimId = filter[i];
		if( dimId != 0){
			int key = 0;
			memcpy(&key, dim + (dimId-1) * byteNum, byteNum);
			memcpy(result + localOffset, &dheader->hash[key], attrSize);
			localOffset += attrSize;
		}
	}
}

__global__ void static joinDim_dict_int(int *resPsum, char * dim, char *dict, int byteNum, int attrSize, long num,int * filter, char * result){

	int startIndex = blockIdx.x*blockDim.x + threadIdx.x;
	int stride = blockDim.x * gridDim.x;
	long localCount = resPsum[startIndex];

	struct dictHeader *dheader = (struct dictHeader*)dict;

	for(long i=startIndex;i<num;i+=stride){
		int dimId = filter[i];
		if( dimId != 0){
			int key = 0;
			memcpy(&key, dim + (dimId-1) * byteNum, byteNum);
			((int*)result)[localCount] = dheader->hash[key];
			localCount ++;
		}
	}
}

__global__ void static joinDim_int(int *resPsum, char * dim, int attrSize, long num,int * filter, char * result){

	int startIndex = blockIdx.x*blockDim.x + threadIdx.x;
	int stride = blockDim.x * gridDim.x;
	long localCount = resPsum[startIndex];

	for(long i=startIndex;i<num;i+=stride){
		int dimId = filter[i];
		if( dimId != 0){
			((int*)result)[localCount] = ((int*)dim)[dimId-1];
			localCount ++;
		}
	}
}

__global__ void static joinDim_other(int *resPsum, char * dim, int attrSize, long num,int * filter, char * result){

	int startIndex = blockIdx.x*blockDim.x + threadIdx.x;
	int stride = blockDim.x * gridDim.x;
	long localOffset = resPsum[startIndex] * attrSize;

	for(long i=startIndex;i<num;i+=stride){
		int dimId = filter[i];
		if( dimId != 0){
			memcpy(result + localOffset, dim + (dimId-1)* attrSize, attrSize);
			localOffset += attrSize;
		}
	}
}


__global__ void static joinDim_other_soa(int *resPsum, char * dim, int attrSize, long tupleNum, long resultNum,int * filter, char * result){

	int startIndex = blockIdx.x*blockDim.x + threadIdx.x;
	int stride = blockDim.x * gridDim.x;
	long tNum = resPsum[startIndex];

	for(long i=startIndex;i<tupleNum;i+=stride){
		int dimId = filter[i];
		if( dimId != 0){
			for(int j=0;j<attrSize;j++){
				long inPos = j*tupleNum + (dimId-1);
				long outPos = j*resultNum + tNum;
				result[outPos] = dim[inPos]; 
			}
		}
	}
}

/*
 * hashJoin implements the foreign key join between a fact table and dimension table.
 *
 * Prerequisites:
 *	1. the data to be joined can be fit into GPU device memory.
 *	2. dimension table is not compressed
 *	
 * Input:
 *	jNode: contains information about the two joined tables.
 *	pp: records statistics such as kernel execution time
 *
 * Output:
 * 	A new table node
 */

struct tableNode * hashJoin(struct joinNode *jNode, struct statistic *pp){
	struct tableNode * res = NULL;

	int *cpu_count, *resPsum;
	int count = 0;
	int i;

	int * gpu_hashNum;
	char * gpu_result;
	char  *gpu_bucket, *gpu_fact, * gpu_dim;
	int * gpu_count,  *gpu_psum, *gpu_resPsum;

	int defaultBlock = 2048;

	dim3 grid(defaultBlock);
	dim3 block(256);
	int blockNum;
	int threadNum;

	blockNum = jNode->leftTable->tupleNum / block.x + 1;
	if(blockNum < defaultBlock)
		grid = blockNum;
	else
		grid = defaultBlock;

	threadNum = grid.x * block.x;

	res = (struct tableNode*) malloc(sizeof(struct tableNode));
	res->totalAttr = jNode->totalAttr;
	res->tupleSize = jNode->tupleSize;
	res->attrType = (int *) malloc(res->totalAttr * sizeof(int));
	res->attrSize = (int *) malloc(res->totalAttr * sizeof(int));
	res->attrIndex = (int *) malloc(res->totalAttr * sizeof(int));
	res->attrTotalSize = (int *) malloc(res->totalAttr * sizeof(int));
	res->dataPos = (int *) malloc(res->totalAttr * sizeof(int));
	res->dataFormat = (int *) malloc(res->totalAttr * sizeof(int));
	res->content = (char **) malloc(res->totalAttr * sizeof(char *));

	for(i=0;i<jNode->leftOutputAttrNum;i++){
		int pos = jNode->leftPos[i];
		res->attrType[pos] = jNode->leftOutputAttrType[i];
		int index = jNode->leftOutputIndex[i];
		res->attrSize[pos] = jNode->leftTable->attrSize[index];
		res->dataFormat[pos] = UNCOMPRESSED;
	}

	for(i=0;i<jNode->rightOutputAttrNum;i++){
		int pos = jNode->rightPos[i];
		res->attrType[pos] = jNode->rightOutputAttrType[i];
		int index = jNode->rightOutputIndex[i];
		res->attrSize[pos] = jNode->rightTable->attrSize[index];
		res->dataFormat[pos] = UNCOMPRESSED;
	}

	long primaryKeySize = sizeof(int) * jNode->rightTable->tupleNum;

/*
 * 	build hash table on GPU
 */

	int *gpu_psum1;


	CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&gpu_hashNum,sizeof(int)*HSIZE));
	CUDA_SAFE_CALL_NO_SYNC(cudaMemset(gpu_hashNum,0,sizeof(int)*HSIZE));

	CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&gpu_count,sizeof(int)*threadNum));
	CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&gpu_resPsum,sizeof(int)*threadNum));

	CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&gpu_psum,HSIZE*sizeof(int)));
	CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gpu_bucket, 2*primaryKeySize));
	CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&gpu_psum1,HSIZE*sizeof(int)));

	int dataPos = jNode->rightTable->dataPos[jNode->rightKeyIndex];

	if(dataPos == MEM || dataPos == PINNED){
		CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&gpu_dim,primaryKeySize));
		CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpu_dim,jNode->rightTable->content[jNode->rightKeyIndex], primaryKeySize,cudaMemcpyHostToDevice));

	}else if (dataPos == GPU || dataPos == UVA){
		gpu_dim = jNode->rightTable->content[jNode->rightKeyIndex];
	}

	count_hash_num<<<grid,block>>>(gpu_dim,jNode->rightTable->tupleNum,gpu_hashNum);

	scanImpl(gpu_hashNum,HSIZE,gpu_psum, pp);

	CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpu_psum1,gpu_psum,sizeof(int)*HSIZE,cudaMemcpyDeviceToDevice));

	build_hash_table<<<grid,block>>>(gpu_dim,jNode->rightTable->tupleNum,gpu_psum1,gpu_bucket);

	if (dataPos == MEM || dataPos == PINNED)
		CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpu_dim));

	CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpu_psum1));


/*
 *	join on GPU
 */

	int *gpuFactFilter;
	int maxAttrSize;

	dataPos = jNode->leftTable->dataPos[jNode->leftKeyIndex];
	int format = jNode->leftTable->dataFormat[jNode->leftKeyIndex];

	long foreignKeySize = jNode->leftTable->attrTotalSize[jNode->leftKeyIndex];
	long filterSize = jNode->leftTable->attrSize[jNode->leftKeyIndex] * jNode->leftTable->tupleNum;

	if(dataPos == MEM || dataPos == PINNED){
		CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&gpu_fact, foreignKeySize));
		CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpu_fact,jNode->leftTable->content[jNode->leftKeyIndex], foreignKeySize,cudaMemcpyHostToDevice));

	}else if (dataPos == GPU || dataPos == UVA){
		gpu_fact = jNode->leftTable->content[jNode->leftKeyIndex];
	}

	CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gpuFactFilter,filterSize));
	CUDA_SAFE_CALL_NO_SYNC(cudaMemset(gpuFactFilter,0,filterSize));

	if(format == UNCOMPRESSED)
		count_join_result<<<grid,block>>>(gpu_hashNum, gpu_psum, gpu_bucket, gpu_fact, jNode->leftTable->tupleNum, gpu_count,gpuFactFilter);

	else if(format == DICT){
		int dNum;
		struct dictHeader * dheader;

		if(dataPos == MEM || dataPos == UVA || dataPos == PINNED){
			dheader = (struct dictHeader *) jNode->leftTable->content[jNode->leftKeyIndex];
			dNum = dheader->dictNum;

		}else if (dataPos == GPU){
			dheader = (struct dictHeader *) malloc(sizeof(struct dictHeader));
			memset(dheader,0,sizeof(struct dictHeader));
			CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(dheader,gpu_fact,sizeof(struct dictHeader), cudaMemcpyDeviceToHost));
			dNum = dheader->dictNum;
		}
		free(dheader);

		int * gpuDictFilter;
		CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gpuDictFilter, dNum * sizeof(int)));
		CUDA_SAFE_CALL_NO_SYNC(cudaMemset(gpuDictFilter, 0 ,dNum * sizeof(int)));


		count_join_result_dict<<<grid,block>>>(gpu_hashNum, gpu_psum, gpu_bucket, gpu_fact, dNum, gpuDictFilter);

		transform_dict_filter<<<grid,block>>>(gpuDictFilter, gpu_fact, jNode->leftTable->tupleNum, dNum, gpuFactFilter);

		CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpuDictFilter));

		filter_count<<<grid,block>>>(jNode->leftTable->tupleNum, gpu_count, gpuFactFilter);

	}else if (format == RLE){

		count_join_result_rle<<<512,64>>>(gpu_hashNum, gpu_psum, gpu_bucket, gpu_fact, jNode->leftTable->tupleNum, 0,gpuFactFilter);

		filter_count<<<grid, block>>>(jNode->leftTable->tupleNum, gpu_count, gpuFactFilter);
	}


	cpu_count = (int *) malloc(sizeof(int)*threadNum);
	memset(cpu_count,0,sizeof(int)*threadNum);
	CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(cpu_count,gpu_count,sizeof(int)*threadNum,cudaMemcpyDeviceToHost));
	resPsum = (int *) malloc(sizeof(int)*threadNum);
	memset(resPsum,0,sizeof(int)*threadNum);
	scanImpl(gpu_count,threadNum,gpu_resPsum, pp);

	CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(resPsum,gpu_resPsum,sizeof(int)*threadNum,cudaMemcpyDeviceToHost));

	count = resPsum[threadNum-1] + cpu_count[threadNum-1];
	res->tupleNum = count;
	printf("joinNum %d\n",count);

	if(dataPos == MEM || dataPos == PINNED){
		CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpu_fact));
	}

	CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpu_bucket));
		
	free(resPsum);
	free(cpu_count);

	for(i=0; i<res->totalAttr; i++){
		int index, pos;
		long colSize = 0, resSize = 0;
		int leftRight = 0;

		int attrSize, attrType;
		char * table;
		int found = 0 , dataPos, format;

		if (jNode->keepInGpu[i] == 1)
			res->dataPos[i] = GPU;
		else
			res->dataPos[i] = MEM;

		for(int k=0;k<jNode->leftOutputAttrNum;k++){
			if (jNode->leftPos[k] == i){
				found = 1;
				leftRight = 0;
				pos = k;
				break;
			}
		}
		if(!found){
			for(int k=0;k<jNode->rightOutputAttrNum;k++){
				if(jNode->rightPos[k] == i){
					found = 1;
					leftRight = 1;
					pos = k;
					break;
				}
			}
		}

		if(leftRight == 0){
			index = jNode->leftOutputIndex[pos];
			dataPos = jNode->leftTable->dataPos[index];
			format = jNode->leftTable->dataFormat[index];

			table = jNode->leftTable->content[index];
			attrSize  = jNode->leftTable->attrSize[index];
			attrType  = jNode->leftTable->attrType[index];
			colSize = jNode->leftTable->attrTotalSize[index];

			resSize = res->tupleNum * attrSize;
		}else{
			index = jNode->rightOutputIndex[pos];
			dataPos = jNode->rightTable->dataPos[index];
			format = jNode->rightTable->dataFormat[index];

			table = jNode->rightTable->content[index];
			attrSize = jNode->rightTable->attrSize[index];
			attrType = jNode->rightTable->attrType[index];
			colSize = jNode->rightTable->attrTotalSize[index];

			resSize = attrSize * res->tupleNum;
			leftRight = 1;
		}


		CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&gpu_result,resSize));

		if(leftRight == 0){
			if(format == UNCOMPRESSED){

				if(dataPos == MEM || dataPos == PINNED){
					CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gpu_fact, colSize));
					CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpu_fact, table, colSize,cudaMemcpyHostToDevice));
				}else{
					gpu_fact = table;
				}

				if(attrSize == sizeof(int))
					joinFact_int<<<grid,block>>>(gpu_resPsum,gpu_fact, attrSize, jNode->leftTable->tupleNum,gpuFactFilter,gpu_result);
				else
					joinFact_other<<<grid,block>>>(gpu_resPsum,gpu_fact, attrSize, jNode->leftTable->tupleNum,gpuFactFilter,gpu_result);

			}else if (format == DICT){
				struct dictHeader * dheader;
				int byteNum;
				char * gpuDictHeader;

				assert(dataPos == MEM || dataPos == PINNED);

				dheader = (struct dictHeader *)table;
				byteNum = dheader->bitNum/8;
				CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&gpuDictHeader,sizeof(struct dictHeader)));
				CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpuDictHeader,dheader,sizeof(struct dictHeader),cudaMemcpyHostToDevice));

				if(dataPos == MEM || dataPos == PINNED){
					CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gpu_fact, colSize));
					CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpu_fact, table + sizeof(struct dictHeader), colSize-sizeof(struct dictHeader),cudaMemcpyHostToDevice));
				}else{
					gpu_fact = table + sizeof(struct dictHeader);
				}

				if (attrSize == sizeof(int))
					joinFact_dict_int<<<grid,block>>>(gpu_resPsum,gpu_fact, gpuDictHeader,byteNum,attrSize, jNode->leftTable->tupleNum,gpuFactFilter,gpu_result);
				else
					joinFact_dict_other<<<grid,block>>>(gpu_resPsum,gpu_fact, gpuDictHeader,byteNum,attrSize, jNode->leftTable->tupleNum,gpuFactFilter,gpu_result);

				CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpuDictHeader));

			}else if (format == RLE){

				if(dataPos == MEM || dataPos == PINNED){
					CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gpu_fact, colSize));
					CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpu_fact, table, colSize,cudaMemcpyHostToDevice));
				}else{
					gpu_fact = table;
				}

				int dNum = (colSize - sizeof(struct rleHeader))/(3*sizeof(int));

				char * gpuRle;
				CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gpuRle, jNode->leftTable->tupleNum * sizeof(int)));

				unpack_rle<<<grid,block>>>(gpu_fact, gpuRle,jNode->leftTable->tupleNum, 0, dNum);


				joinFact_int<<<grid,block>>>(gpu_resPsum,gpuRle, attrSize, jNode->leftTable->tupleNum,gpuFactFilter,gpu_result);

				CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpuRle));

			}

		}else{
			if(format == UNCOMPRESSED){

				if(dataPos == MEM || dataPos == PINNED){
					CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gpu_fact, colSize));
					CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpu_fact, table, colSize,cudaMemcpyHostToDevice));
				}else{
					gpu_fact = table;
				}

				if(attrType == sizeof(int))
					joinDim_int<<<grid,block>>>(gpu_resPsum,gpu_fact, attrSize, jNode->leftTable->tupleNum, gpuFactFilter,gpu_result);
				else
					joinDim_other<<<grid,block>>>(gpu_resPsum,gpu_fact, attrSize, jNode->leftTable->tupleNum, gpuFactFilter,gpu_result);

			}else if (format == DICT){
				struct dictHeader * dheader;
				int byteNum;
				char * gpuDictHeader;
				assert(dataPos == MEM || dataPos == PINNED);

				dheader = (struct dictHeader *)table;
				byteNum = dheader->bitNum/8;
				CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&gpuDictHeader,sizeof(struct dictHeader)));
				CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpuDictHeader,dheader,sizeof(struct dictHeader),cudaMemcpyHostToDevice));
				if(dataPos == MEM || dataPos == PINNED){
					CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gpu_fact, colSize));
					CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpu_fact, table + sizeof(struct dictHeader), colSize-sizeof(struct dictHeader),cudaMemcpyHostToDevice));
				}else{
					gpu_fact = table + sizeof(struct dictHeader);
				}

				if(attrType == sizeof(int))
					joinDim_dict_int<<<grid,block>>>(gpu_resPsum,gpu_fact, gpuDictHeader,byteNum,attrSize, jNode->leftTable->tupleNum, gpuFactFilter,gpu_result);
				else
					joinDim_dict_other<<<grid,block>>>(gpu_resPsum,gpu_fact, gpuDictHeader, byteNum, attrSize, jNode->leftTable->tupleNum, gpuFactFilter,gpu_result);
				CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpuDictHeader));

			}else if (format == RLE){

				if(dataPos == MEM || dataPos == PINNED){
					CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gpu_fact, colSize));
					CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpu_fact, table, colSize,cudaMemcpyHostToDevice));
				}else{
					gpu_fact = table;
				}

				joinDim_rle<<<grid,block>>>(gpu_resPsum,gpu_fact, attrSize, jNode->leftTable->tupleNum, 0,gpuFactFilter,gpu_result);
			}
		}
		
		res->attrTotalSize[i] = resSize;
		res->dataFormat[i] = UNCOMPRESSED;
		if(res->dataPos[i] == MEM){
			res->content[i] = (char *) malloc(resSize);
			memset(res->content[i],0,resSize);
			CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(res->content[i],gpu_result,resSize,cudaMemcpyDeviceToHost));
			CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpu_result));

		}else if(res->dataPos[i] == GPU){
			res->content[i] = gpu_result;
		}
		if(dataPos == MEM || dataPos == PINNED)
			CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpu_fact));

	}

	CUDA_SAFE_CALL(cudaFree(gpuFactFilter));

	CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpu_count));
	CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpu_hashNum));
	CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpu_psum));

	return res;

}
