/* Copyright (c) 2026 The Ycash developers
 * Distributed under the MIT software license, see the accompanying
 * file COPYING or https://www.opensource.org/licenses/mit-license.php .
 *
 * cl-probe: what a GPU miner's OpenCL start-up does, step by step, with every error printed.
 *
 * In plain words: `clinfo -l` only lists the OpenCL devices. A miner does more before it uses one:
 * it creates a context and a queue, compiles a kernel from source (lolMiner's own health check is
 * the empty kernel below), creates it, runs it and waits. On Nvidia the compile step loads the
 * driver's compiler libraries, which the container runtime has to mount from the host. GPU burst 2
 * (2026-11-13) saw clinfo list the RTX 3060 while lolMiner counted 0 OpenCL GPUs; this probe shows
 * which step fails and with which error, so the next log is decisive.
 *
 * Exit 0 when at least one GPU passes every step, 1 when none does, 2 with no OpenCL platform.
 */
#define CL_TARGET_OPENCL_VERSION 120
#include <CL/cl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CL_DEVICE_COMPUTE_CAPABILITY_MAJOR_NV 0x4000
#define CL_DEVICE_COMPUTE_CAPABILITY_MINOR_NV 0x4001
#define CL_DEVICE_PCI_BUS_ID_NV 0x4008

static const char *SRC = "__kernel void healthCheck() { }";

static void str(cl_device_id d, cl_device_info what, char *buf, size_t n) {
  buf[0] = 0;
  if (clGetDeviceInfo(d, what, n, buf, NULL) != CL_SUCCESS) snprintf(buf, n, "?");
}

static int probe(cl_device_id d) {
  char name[256], ver[256], drv[256], cver[256], ext[8192];
  cl_int err;
  cl_ulong mem = 0;
  cl_uint ccmaj = 0, ccmin = 0, bus = 0;
  str(d, CL_DEVICE_NAME, name, sizeof name);
  str(d, CL_DEVICE_VERSION, ver, sizeof ver);
  str(d, CL_DRIVER_VERSION, drv, sizeof drv);
  str(d, CL_DEVICE_OPENCL_C_VERSION, cver, sizeof cver);
  str(d, CL_DEVICE_EXTENSIONS, ext, sizeof ext);
  clGetDeviceInfo(d, CL_DEVICE_GLOBAL_MEM_SIZE, sizeof mem, &mem, NULL);
  printf("    device: %s | %s | driver %s | %s | %llu MByte\n", name, ver, drv, cver,
         (unsigned long long)(mem >> 20));
  if (strstr(ext, "cl_nv_device_attribute_query")) {
    clGetDeviceInfo(d, CL_DEVICE_COMPUTE_CAPABILITY_MAJOR_NV, sizeof ccmaj, &ccmaj, NULL);
    clGetDeviceInfo(d, CL_DEVICE_COMPUTE_CAPABILITY_MINOR_NV, sizeof ccmin, &ccmin, NULL);
    err = clGetDeviceInfo(d, CL_DEVICE_PCI_BUS_ID_NV, sizeof bus, &bus, NULL);
    printf("    nv: compute capability %u.%u, PCI bus %s%x\n", ccmaj, ccmin, err == CL_SUCCESS ? "" : "? err ",
           err == CL_SUCCESS ? bus : (unsigned)err);
  } else {
    printf("    nv: no cl_nv_device_attribute_query extension\n");
  }
  cl_context ctx = clCreateContext(NULL, 1, &d, NULL, NULL, &err);
  if (err != CL_SUCCESS) { printf("    FAIL clCreateContext: %d\n", err); return 0; }
  printf("    ok   clCreateContext\n");
  cl_command_queue q = clCreateCommandQueue(ctx, d, 0, &err);
  if (err != CL_SUCCESS) { printf("    FAIL clCreateCommandQueue: %d\n", err); clReleaseContext(ctx); return 0; }
  printf("    ok   clCreateCommandQueue\n");
  int good = 0;
  cl_program p = clCreateProgramWithSource(ctx, 1, &SRC, NULL, &err);
  if (err != CL_SUCCESS) { printf("    FAIL clCreateProgramWithSource: %d\n", err); goto out; }
  err = clBuildProgram(p, 1, &d, "", NULL, NULL);
  if (err != CL_SUCCESS) {
    char log[4096] = "";
    clGetProgramBuildInfo(p, d, CL_PROGRAM_BUILD_LOG, sizeof log - 1, log, NULL);
    printf("    FAIL clBuildProgram: %d (build log: %s)\n", err, log[0] ? log : "empty");
    clReleaseProgram(p);
    goto out;
  }
  printf("    ok   clBuildProgram (the driver's OpenCL compiler works)\n");
  cl_kernel k = clCreateKernel(p, "healthCheck", &err);
  if (err != CL_SUCCESS) { printf("    FAIL clCreateKernel: %d\n", err); clReleaseProgram(p); goto out; }
  size_t g = 1;
  err = clEnqueueNDRangeKernel(q, k, 1, NULL, &g, NULL, 0, NULL, NULL);
  if (err == CL_SUCCESS) err = clFinish(q);
  if (err != CL_SUCCESS) printf("    FAIL run the kernel: %d\n", err);
  else { printf("    ok   kernel ran\n"); good = 1; }
  clReleaseKernel(k);
  clReleaseProgram(p);
out:
  clReleaseCommandQueue(q);
  clReleaseContext(ctx);
  return good;
}

int main(void) {
  cl_platform_id plats[16];
  cl_uint np = 0;
  cl_int err = clGetPlatformIDs(16, plats, &np);
  if (err != CL_SUCCESS || np == 0) {
    printf("no OpenCL platform (clGetPlatformIDs: %d)\n", err);
    return 2;
  }
  int good = 0;
  for (cl_uint i = 0; i < np; i++) {
    char pname[256] = "", pver[256] = "";
    clGetPlatformInfo(plats[i], CL_PLATFORM_NAME, sizeof pname, pname, NULL);
    clGetPlatformInfo(plats[i], CL_PLATFORM_VERSION, sizeof pver, pver, NULL);
    printf("platform %u: %s | %s\n", i, pname, pver);
    cl_device_id devs[16];
    cl_uint nd = 0;
    err = clGetDeviceIDs(plats[i], CL_DEVICE_TYPE_GPU, 16, devs, &nd);
    if (err != CL_SUCCESS) { printf("    no GPU device (clGetDeviceIDs: %d)\n", err); continue; }
    for (cl_uint j = 0; j < nd; j++) good += probe(devs[j]);
  }
  printf("GPUs that pass every step: %d\n", good);
  return good ? 0 : 1;
}
