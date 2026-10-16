#ifndef CAMERA_CORE_H
#define CAMERA_CORE_H
#include <stdint.h>
#include <stdlib.h>
int64_t CameraCreate(const char *root, const char *guid);
char *CameraRequest(int64_t engine, const char *json);
void *CameraCopyFrame(int64_t engine, int64_t *length);
void CameraAbort(int64_t engine);
void CameraDestroy(int64_t engine);
void CameraFree(void *memory);
#endif
