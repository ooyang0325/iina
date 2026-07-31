#include "sacd_bridge.h"

#include <algorithm>
#include <cmath>
#include <new>
#include <string>

#include "sacd_disc.h"

struct iina_sacd {
    sacd_media_t media;
    sacd_disc_t disc;
    area_id_e active_area = AREA_BOTH;
    int active_track = 0;
    int frame = 0;
    double track_start = 0;
    std::string title;
    std::string artist;
};

static area_id_e area_id(iina_sacd *sacd, int index)
{
    if (sacd->disc.get_track_count(AREA_TWOCH)) {
        if (index-- == 0)
            return AREA_TWOCH;
    }
    if (sacd->disc.get_track_count(AREA_MULCH) && index == 0)
        return AREA_MULCH;
    return AREA_BOTH;
}

static double track_duration(scarletbook_area_t *area, int track)
{
    if (!area || track < 0 || track >= area->area_toc->track_count)
        return 0;
    if (area->area_tracklist_time) {
        const auto time = area->area_tracklist_time->duration[track];
        return time.minutes * 60.0 + time.seconds + time.frames / 75.0;
    }
    const auto total = area->area_toc->total_playtime;
    return (total.minutes * 60.0 + total.seconds + total.frames / 75.0) /
           area->area_toc->track_count;
}

static double track_start(iina_sacd *sacd, area_id_e id, int track)
{
    auto *area = sacd->disc.get_area(id);
    double start = 0;
    for (int i = 0; i < track; i++)
        start += track_duration(area, i);
    return start;
}

static int track_frames(scarletbook_area_t *area, int track)
{
    return std::lround(track_duration(area, track) * 75);
}

static uint32_t track_sector_offset(scarletbook_area_t *area, int track,
                                    double seconds)
{
    if (!area || !area->area_tracklist_offset)
        return 0;
    double duration = track_duration(area, track);
    return duration > 0
        ? area->area_tracklist_offset->track_length_lsn[track] *
          std::clamp(seconds / duration, 0.0, 1.0)
        : 0;
}

static void select_track(iina_sacd *sacd, int track, uint32_t offset)
{
    auto *area = sacd->disc.get_area(sacd->active_area);
    uint32_t lead_in = 0;
    if (track == 0 && area->area_tracklist_offset) {
        uint32_t logical_start =
            area->area_tracklist_offset->track_start_lsn[0];
        if (logical_start > area->area_toc->track_start)
            lead_in = logical_start - area->area_toc->track_start;
    }
    sacd->disc.set_track(track, sacd->active_area, lead_in + offset);
}

extern "C" iina_sacd *iina_sacd_open(const char *path)
{
    if (!path)
        return nullptr;
    auto *sacd = new (std::nothrow) iina_sacd;
    if (!sacd)
        return nullptr;
    if (!sacd->media.open(path)) {
        delete sacd;
        return nullptr;
    }
    if (!sacd->disc.open(&sacd->media)) {
        sacd->disc.close();
        sacd->media.close();
        delete sacd;
        return nullptr;
    }
    return sacd;
}

extern "C" void iina_sacd_close(iina_sacd *sacd)
{
    if (!sacd)
        return;
    sacd->disc.close();
    sacd->media.close();
    delete sacd;
}

extern "C" int iina_sacd_area_count(iina_sacd *sacd)
{
    return sacd ? !!sacd->disc.get_track_count(AREA_TWOCH) +
                  !!sacd->disc.get_track_count(AREA_MULCH) : 0;
}

extern "C" int iina_sacd_get_area(iina_sacd *sacd, int index,
                                    iina_sacd_area_info *info)
{
    if (!sacd || !info)
        return 0;
    area_id_e id = area_id(sacd, index);
    auto *area = sacd->disc.get_area(id);
    if (!area)
        return 0;
    double duration = 0;
    for (int i = 0; i < area->area_toc->track_count; i++)
        duration += track_duration(area, i);
    *info = {
        area->area_toc->channel_count,
        area->area_toc->track_count,
        area->area_toc->frame_format == FRAME_FORMAT_DST,
        duration,
    };
    return 1;
}

extern "C" int iina_sacd_get_track(iina_sacd *sacd, int index, int track,
                                     iina_sacd_track_info *info)
{
    if (!sacd || !info)
        return 0;
    area_id_e id = area_id(sacd, index);
    auto *area = sacd->disc.get_area(id);
    if (!area || track < 0 || track >= area->area_toc->track_count)
        return 0;
    TrackDetails details;
    sacd->disc.getTrackDetails(track, id, &details);
    sacd->title = details.strTitle;
    sacd->artist = details.strArtist == "Unknown Artist" ? "" : details.strArtist;
    *info = {
        sacd->title.c_str(),
        sacd->artist.c_str(),
        track_start(sacd, id, track),
        track_duration(area, track),
    };
    return 1;
}

extern "C" int iina_sacd_select_area(iina_sacd *sacd, int index)
{
    if (!sacd)
        return 0;
    area_id_e id = area_id(sacd, index);
    if (id == AREA_BOTH || !sacd->disc.get_track_count(id))
        return 0;
    sacd->active_area = id;
    sacd->active_track = 0;
    sacd->frame = 0;
    sacd->track_start = 0;
    select_track(sacd, 0, 0);
    return 1;
}

extern "C" int iina_sacd_seek(iina_sacd *sacd, double seconds)
{
    if (!sacd || sacd->active_area == AREA_BOTH || !std::isfinite(seconds))
        return 0;
    auto *area = sacd->disc.get_area(sacd->active_area);
    double start = 0;
    for (int track = 0; track < area->area_toc->track_count; track++) {
        double duration = track_duration(area, track);
        if (seconds < start + duration || track + 1 == area->area_toc->track_count) {
            double within = std::clamp(seconds - start, 0.0, duration);
            uint32_t offset = track_sector_offset(area, track, within);
            sacd->active_track = track;
            sacd->track_start = start;
            sacd->frame = std::floor(within * 75);
            select_track(sacd, track, offset);
            return 1;
        }
        start += duration;
    }
    return 0;
}

extern "C" int iina_sacd_read_frame(iina_sacd *sacd, void *data,
                                      size_t capacity, size_t *size,
                                      int *dst_encoded, double *pts)
{
    if (!sacd || !data || !size || !dst_encoded || !pts ||
        sacd->active_area == AREA_BOTH)
        return -1;
    auto *area = sacd->disc.get_area(sacd->active_area);
    for (;;) {
        if (sacd->frame >= track_frames(area, sacd->active_track)) {
            if (++sacd->active_track >= area->area_toc->track_count)
                return 0;
            sacd->track_start = track_start(sacd, sacd->active_area,
                                            sacd->active_track);
            sacd->frame = 0;
            select_track(sacd, sacd->active_track, 0);
        }
        size_t frame_size = capacity;
        frame_type_e type = FRAME_INVALID;
        if (sacd->disc.read_frame(static_cast<uint8_t *>(data), &frame_size, &type)) {
            if (type == FRAME_INVALID)
                return -1;
            if (type == FRAME_DSD &&
                frame_size != area->area_toc->channel_count * FRAME_SIZE_64)
                continue;
            *size = frame_size;
            *dst_encoded = type == FRAME_DST;
            *pts = sacd->track_start + sacd->frame++ / 75.0;
            return 1;
        }
        if (++sacd->active_track >= area->area_toc->track_count)
            return 0;
        sacd->track_start = track_start(sacd, sacd->active_area,
                                        sacd->active_track);
        sacd->frame = 0;
        select_track(sacd, sacd->active_track, 0);
    }
}
