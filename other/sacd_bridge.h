#ifndef IINA_SACD_BRIDGE_H
#define IINA_SACD_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct iina_sacd iina_sacd;

typedef struct {
    int channels;
    int track_count;
    int dst_encoded;
    double duration;
} iina_sacd_area_info;

typedef struct {
    const char *title;
    const char *artist;
    double start;
    double duration;
} iina_sacd_track_info;

iina_sacd *iina_sacd_open(const char *path);
void iina_sacd_close(iina_sacd *sacd);
int iina_sacd_area_count(iina_sacd *sacd);
int iina_sacd_get_area(iina_sacd *sacd, int area, iina_sacd_area_info *info);
int iina_sacd_get_track(iina_sacd *sacd, int area, int track,
                        iina_sacd_track_info *info);
int iina_sacd_select_area(iina_sacd *sacd, int area);
int iina_sacd_seek(iina_sacd *sacd, double seconds);
int iina_sacd_read_frame(iina_sacd *sacd, void *data, size_t capacity,
                         size_t *size, int *dst_encoded, double *pts);

#ifdef __cplusplus
}
#endif

#endif
