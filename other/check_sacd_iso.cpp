#include <arpa/inet.h>
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <cmath>
#include <vector>

#include "sacd_bridge.h"
#include "scarletbook.h"

static void put_id(char *dest, const char *id)
{
    memcpy(dest, id, 8);
}

int main(int argc, char **argv)
{
    if (argc == 3 && strcmp(argv[1], "--inspect") == 0) {
        iina_sacd *sacd = iina_sacd_open(argv[2]);
        assert(sacd);
        int areas = iina_sacd_area_count(sacd);
        printf("areas=%d\n", areas);
        for (int area = 0; area < areas; area++) {
            iina_sacd_area_info info;
            assert(iina_sacd_get_area(sacd, area, &info));
            printf("area=%d channels=%d tracks=%d encoding=%s duration=%.3f\n",
                   area, info.channels, info.track_count,
                   info.dst_encoded ? "DST" : "DSD", info.duration);
            for (int track = 0; track < info.track_count; track++) {
                iina_sacd_track_info item;
                assert(iina_sacd_get_track(sacd, area, track, &item));
                printf("track=%d start=%.3f duration=%.3f title=%s artist=%s\n",
                       track + 1, item.start, item.duration,
                       item.title, item.artist);
            }
        }
        assert(iina_sacd_select_area(sacd, 0));
        uint8_t frame[64 * 1024];
        for (int i = 0; i < 3; i++) {
            size_t size = 0;
            int dst = 0;
            double pts = 0;
            assert(iina_sacd_read_frame(sacd, frame, sizeof(frame), &size,
                                        &dst, &pts) == 1);
            printf("frame=%d pts=%.6f bytes=%zu encoding=%s\n", i + 1, pts,
                   size, dst ? "DST" : "DSD");
        }
        if (areas > 0) {
            iina_sacd_track_info second;
            iina_sacd_area_info first;
            assert(iina_sacd_get_area(sacd, 0, &first));
            if (first.track_count > 1) {
                assert(iina_sacd_get_track(sacd, 0, 1, &second));
                assert(iina_sacd_seek(sacd, second.start));
                size_t size = 0;
                int dst = 0;
                double pts = 0;
                assert(iina_sacd_read_frame(sacd, frame, sizeof(frame), &size,
                                            &dst, &pts) == 1);
                assert(fabs(pts - second.start) < 0.001);
                printf("seek=%.6f bytes=%zu encoding=%s\n", pts, size,
                       dst ? "DST" : "DSD");
            }
        }
        iina_sacd_close(sacd);
        return 0;
    }

    std::vector<uint8_t> image(550 * SACD_LSN_SIZE);

    auto *master = reinterpret_cast<master_toc_t *>(
        image.data() + START_OF_MASTER_TOC * SACD_LSN_SIZE);
    put_id(master->id, "SACDMTOC");
    master->version.major = 1;
    master->version.minor = 20;
    master->area_1_toc_1_start = htonl(520);
    master->area_1_toc_size = htons(3);
    for (int i = 0; i < MAX_LANGUAGE_COUNT; i++)
        put_id(reinterpret_cast<char *>(master) + (i + 1) * SACD_LSN_SIZE,
               "SACDText");
    put_id(reinterpret_cast<char *>(master) + 9 * SACD_LSN_SIZE, "SACD_Man");

    auto *area = reinterpret_cast<area_toc_t *>(
        image.data() + 520 * SACD_LSN_SIZE);
    put_id(area->id, "TWOCHTOC");
    area->version.major = 1;
    area->version.minor = 20;
    area->size = htons(3);
    area->frame_format = FRAME_FORMAT_DSD_3_IN_16;
    area->channel_count = 2;
    area->track_count = 2;
    area->track_start = htonl(530);
    area->track_end = htonl(539);
    area->total_playtime.seconds = 3;

    auto *offsets = reinterpret_cast<area_tracklist_offset_t *>(
        image.data() + 521 * SACD_LSN_SIZE);
    put_id(offsets->id, "SACDTRL1");
    offsets->track_start_lsn[0] = htonl(530);
    offsets->track_start_lsn[1] = htonl(535);
    offsets->track_length_lsn[0] = htonl(5);
    offsets->track_length_lsn[1] = htonl(5);

    auto *times = reinterpret_cast<area_tracklist_time_t *>(
        image.data() + 522 * SACD_LSN_SIZE);
    put_id(times->id, "SACDTRL2");
    times->duration[0].seconds = 1;
    times->duration[1].seconds = 2;
    times->start[1].seconds = 1;

    char temporary[] = "/tmp/iina-sacd-XXXXXX";
    const char *path = argc > 1 ? argv[1] : temporary;
    int fd = argc > 1 ? open(path, O_CREAT | O_TRUNC | O_WRONLY, 0600)
                      : mkstemp(temporary);
    assert(fd >= 0);
    assert(write(fd, image.data(), image.size()) == (ssize_t)image.size());
    close(fd);

    iina_sacd *sacd = iina_sacd_open(path);
    assert(sacd);
    assert(iina_sacd_area_count(sacd) == 1);
    iina_sacd_area_info info;
    assert(iina_sacd_get_area(sacd, 0, &info));
    assert(info.channels == 2);
    assert(info.track_count == 2);
    assert(info.dst_encoded == 0);
    assert(info.duration == 3.0);
    iina_sacd_track_info track;
    assert(iina_sacd_get_track(sacd, 0, 0, &track));
    assert(track.start == 0.0 && track.duration == 1.0);
    assert(iina_sacd_get_track(sacd, 0, 1, &track));
    assert(track.start == 1.0 && track.duration == 2.0);
    iina_sacd_close(sacd);
    if (argc == 1)
        unlink(path);
    return 0;
}
