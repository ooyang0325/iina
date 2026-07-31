#include <assert.h>
#include <stdint.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>

int main(void)
{
    const AVCodec *codec = avcodec_find_decoder_by_name("dst");
    assert(codec);
    AVCodecContext *context = avcodec_alloc_context3(codec);
    assert(context);
    context->sample_rate = 352800;
    context->ch_layout = (AVChannelLayout)AV_CHANNEL_LAYOUT_STEREO;
    assert(av_opt_set_int(context, "raw_dsd", 1, AV_OPT_SEARCH_CHILDREN) == 0);
    assert(avcodec_open2(context, codec, NULL) == 0);

    const int bytes = 352800 / 75 * 2;
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    assert(packet && frame && av_new_packet(packet, bytes + 1) == 0);
    packet->data[0] = 0;
    for (int i = 0; i < bytes; i++)
        packet->data[i + 1] = i;

    assert(avcodec_send_packet(context, packet) == 0);
    assert(avcodec_receive_frame(context, frame) == 0);
    assert(frame->format == AV_SAMPLE_FMT_U8);
    assert(frame->nb_samples == bytes / 2);
    assert(memcmp(frame->data[0], packet->data + 1, bytes) == 0);

    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&context);
    return 0;
}
