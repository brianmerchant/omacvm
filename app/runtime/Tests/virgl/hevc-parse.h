/* A small HEVC parser for test-video-decode.c: SPS, PPS and slice segment headers
 * (H.265 7.3), into the values the guest's VA-API driver passes the host
 * (struct virgl_h265_pps, scaling lists in coefficient order as Mesa sends them), and
 * a writer that gives a slice its SPS-picked reference set as a set predicted from
 * that SPS set. Single layer, no long-term pictures (VideoToolbox writes none). */
#ifndef HEVC_PARSE_H
#define HEVC_PARSE_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "virgl_video_hw.h"

struct br {                     /* bit reader over an RBSP */
   const uint8_t *d;
   size_t n, pos;               /* bytes, bits */
   int err;
};

static uint32_t br_u(struct br *b, unsigned k)
{
   uint32_t v = 0;
   while (k--) {
      if (b->pos >= b->n * 8) {
         b->err = 1;
         return 0;
      }
      v = v << 1 | ((b->d[b->pos >> 3] >> (7 - (b->pos & 7))) & 1);
      b->pos++;
   }
   return v;
}

static uint32_t br_ue(struct br *b)
{
   unsigned z = 0;
   while (!br_u(b, 1)) {
      if (b->err || ++z > 31) {
         b->err = 1;
         return 0;
      }
   }
   return (1u << z) - 1 + br_u(b, z);
}

static int32_t br_se(struct br *b)
{
   uint32_t v = br_ue(b);
   return v & 1 ? (int32_t)((v + 1) / 2) : -(int32_t)(v / 2);
}

struct bw {                     /* bit writer into a zeroed buffer */
   uint8_t *d;
   size_t pos;
};

static void bw_u(struct bw *w, unsigned k, uint32_t v)
{
   while (k--) {
      if ((v >> k) & 1)
         w->d[w->pos >> 3] |= 0x80 >> (w->pos & 7);
      w->pos++;
   }
}

static void bw_ue(struct bw *w, uint32_t v)
{
   unsigned len = 0;
   while (((uint64_t)v + 1) >> (len + 1))
      len++;
   bw_u(w, len, 0);
   bw_u(w, len + 1, v + 1);
}

static void bw_copy(struct bw *w, const uint8_t *d, size_t from, size_t to)
{
   for (size_t i = from; i < to; i++)
      bw_u(w, 1, (d[i >> 3] >> (7 - (i & 7))) & 1);
}

static size_t unescape(const uint8_t *nal, size_t n, uint8_t *out)
{
   size_t k = 0, zeros = 0;
   for (size_t i = 0; i < n; i++) {
      if (zeros >= 2 && nal[i] == 3) {
         zeros = 0;
         continue;
      }
      out[k++] = nal[i];
      zeros = nal[i] ? 0 : zeros + 1;
   }
   return k;
}

/* start code + NAL unit from an RBSP (with emulation prevention) */
static void put_rbsp(uint8_t **out, size_t *n, const uint8_t *r, size_t len)
{
   size_t zeros = 0;
   *out = realloc(*out, *n + 5 + len * 3 / 2);
   memcpy(*out + *n, "\0\0\0\1", 4);
   *n += 4;
   for (size_t i = 0; i < len; i++) {
      if (zeros >= 2 && r[i] <= 3) {
         (*out)[(*n)++] = 3;
         zeros = 0;
      }
      (*out)[(*n)++] = r[i];
      zeros = r[i] ? 0 : zeros + 1;
   }
   if (len && !r[len - 1])
      (*out)[(*n)++] = 3;
}

static unsigned bits_for(unsigned v)    /* Ceil(Log2(v)) */
{
   unsigned n = 0;
   while (n < 32 && (1u << n) < v)
      n++;
   return n;
}

struct rps {                    /* short-term reference picture set */
   unsigned neg, pos;           /* negatives first (closest first), then positives */
   int delta[32];
   uint8_t used[32];
};

/* A set predicted from set R (H.265 7.4.8, equations 7-61 and 7-62). */
static void rps_derive(const struct rps *r, int drps, const uint8_t *used,
                       const uint8_t *use_delta, struct rps *o)
{
   unsigned nd = r->neg + r->pos, i = 0;
   memset(o, 0, sizeof(*o));
   for (int j = (int)r->pos - 1; j >= 0; j--) {
      int d = r->delta[r->neg + j] + drps;
      if (d < 0 && use_delta[r->neg + j] && i < 16) {
         o->delta[i] = d;
         o->used[i++] = used[r->neg + j];
      }
   }
   if (drps < 0 && use_delta[nd] && i < 16) {
      o->delta[i] = drps;
      o->used[i++] = used[nd];
   }
   for (unsigned j = 0; j < r->neg; j++) {
      int d = r->delta[j] + drps;
      if (d < 0 && use_delta[j] && i < 16) {
         o->delta[i] = d;
         o->used[i++] = used[j];
      }
   }
   o->neg = i;
   for (int j = (int)r->neg - 1; j >= 0; j--) {
      int d = r->delta[j] + drps;
      if (d > 0 && use_delta[j] && i < o->neg + 16) {
         o->delta[i] = d;
         o->used[i++] = used[j];
      }
   }
   if (drps > 0 && use_delta[nd] && i < o->neg + 16) {
      o->delta[i] = drps;
      o->used[i++] = used[nd];
   }
   for (unsigned j = 0; j < r->pos; j++) {
      int d = r->delta[r->neg + j] + drps;
      if (d > 0 && use_delta[r->neg + j] && i < o->neg + 16) {
         o->delta[i] = d;
         o->used[i++] = used[r->neg + j];
      }
   }
   o->pos = i - o->neg;
}

/* st_ref_pic_set(idx); idx == num is a slice header's own set */
static int rps_parse(struct br *b, unsigned idx, unsigned num, const struct rps *sets,
                     struct rps *out)
{
   memset(out, 0, sizeof(*out));
   if (idx && br_u(b, 1)) {
      unsigned di = idx == num ? br_ue(b) + 1 : 1;
      int sign = br_u(b, 1);
      int drps = (int)(br_ue(b) + 1) * (sign ? -1 : 1);
      uint8_t used[33], use_delta[33];
      if (di > idx)
         return -1;
      const struct rps *r = &sets[idx - di];
      for (unsigned j = 0; j <= r->neg + r->pos; j++) {
         used[j] = (uint8_t)br_u(b, 1);
         use_delta[j] = used[j] ? 1 : (uint8_t)br_u(b, 1);
      }
      rps_derive(r, drps, used, use_delta, out);
   } else {
      unsigned nn = br_ue(b), np = br_ue(b);
      int poc = 0;
      if (nn > 16 || np > 16)
         return -1;
      for (unsigned i = 0; i < nn; i++) {
         poc -= (int)br_ue(b) + 1;
         out->delta[i] = poc;
         out->used[i] = (uint8_t)br_u(b, 1);
      }
      poc = 0;
      for (unsigned i = 0; i < np; i++) {
         poc += (int)br_ue(b) + 1;
         out->delta[nn + i] = poc;
         out->used[nn + i] = (uint8_t)br_u(b, 1);
      }
      out->neg = nn;
      out->pos = np;
   }
   return b->err ? -1 : 0;
}

/* Scaling lists in coefficient (up-right diagonal) order: what Mesa gives the host. */
static const uint8_t sl_intra[64] = {
   16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 17, 16, 17, 16, 17, 18,
   17, 18, 18, 17, 18, 21, 19, 20, 21, 20, 19, 21, 24, 22, 22, 24,
   24, 22, 22, 24, 25, 25, 27, 30, 27, 25, 25, 29, 31, 35, 35, 31,
   29, 36, 41, 44, 41, 36, 47, 54, 54, 47, 65, 70, 65, 88, 88, 115,
};
static const uint8_t sl_inter[64] = {
   16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 17, 17, 17, 17, 17, 18,
   18, 18, 18, 18, 18, 20, 20, 20, 20, 20, 20, 20, 24, 24, 24, 24,
   24, 24, 24, 24, 25, 25, 25, 25, 25, 25, 25, 28, 28, 28, 28, 28,
   28, 33, 33, 33, 33, 33, 41, 41, 41, 41, 54, 54, 54, 71, 71, 91,
};
static uint8_t sl[4][6][64], sl_dc[4][6];

static void sl_default(unsigned size, unsigned m)
{
   for (unsigned i = 0; i < 64; i++)
      sl[size][m][i] = size == 0 ? 16 : m < 3 ? sl_intra[i] : sl_inter[i];
   sl_dc[size][m] = 16;
}

static void sl_parse(struct br *b)      /* scaling_list_data() */
{
   for (unsigned size = 0; size < 4; size++)
      for (unsigned m = 0; m < 6; m += size == 3 ? 3 : 1) {
         if (!br_u(b, 1)) {
            unsigned delta = br_ue(b) * (size == 3 ? 3 : 1);
            if (!delta || delta > m) {
               sl_default(size, m);
            } else {
               memcpy(sl[size][m], sl[size][m - delta], 64);
               sl_dc[size][m] = sl_dc[size][m - delta];
            }
         } else {
            int next = 8;
            if (size > 1) {
               next = br_se(b) + 8;
               sl_dc[size][m] = (uint8_t)next;
            }
            for (unsigned i = 0; i < (size ? 64u : 16u); i++) {
               next = (next + br_se(b) + 256) % 256;
               sl[size][m][i] = (uint8_t)next;
            }
         }
      }
}

static struct virgl_h265_pps hp;        /* the stream's SPS and PPS, as the guest sends them */
static struct rps sets[65];
static unsigned num_sets, lsb_bits;

static int sps_parse(struct br *b)
{
   struct virgl_h265_sps *q = &hp.sps;
   unsigned subs, prof[8] = { 0 }, lev[8] = { 0 };

   memset(q, 0, sizeof(*q));
   br_u(b, 4);
   subs = br_u(b, 3);
   br_u(b, 1);
   b->pos += 96;                        /* general profile, tier and level */
   for (unsigned i = 0; i < subs; i++) {
      prof[i] = br_u(b, 1);
      lev[i] = br_u(b, 1);
   }
   if (subs)
      b->pos += 2 * (8 - subs);
   for (unsigned i = 0; i < subs; i++)
      b->pos += (prof[i] ? 88 : 0) + (lev[i] ? 8 : 0);
   br_ue(b);
   q->chroma_format_idc = (uint8_t)br_ue(b);
   if (q->chroma_format_idc == 3)
      q->separate_colour_plane_flag = (uint8_t)br_u(b, 1);
   q->pic_width_in_luma_samples = br_ue(b);
   q->pic_height_in_luma_samples = br_ue(b);
   if (br_u(b, 1))
      for (int i = 0; i < 4; i++)
         br_ue(b);
   q->bit_depth_luma_minus8 = (uint8_t)br_ue(b);
   q->bit_depth_chroma_minus8 = (uint8_t)br_ue(b);
   q->log2_max_pic_order_cnt_lsb_minus4 = (uint8_t)br_ue(b);
   lsb_bits = q->log2_max_pic_order_cnt_lsb_minus4 + 4u;
   for (unsigned i = br_u(b, 1) ? 0 : subs; i <= subs; i++) {
      q->sps_max_dec_pic_buffering_minus1 = (uint8_t)br_ue(b);
      br_ue(b);
      br_ue(b);
   }
   q->log2_min_luma_coding_block_size_minus3 = (uint8_t)br_ue(b);
   q->log2_diff_max_min_luma_coding_block_size = (uint8_t)br_ue(b);
   q->log2_min_transform_block_size_minus2 = (uint8_t)br_ue(b);
   q->log2_diff_max_min_transform_block_size = (uint8_t)br_ue(b);
   q->max_transform_hierarchy_depth_inter = (uint8_t)br_ue(b);
   q->max_transform_hierarchy_depth_intra = (uint8_t)br_ue(b);
   for (unsigned size = 0; size < 4; size++)
      for (unsigned m = 0; m < 6; m++)
         sl_default(size, m);
   q->scaling_list_enabled_flag = (uint8_t)br_u(b, 1);
   if (q->scaling_list_enabled_flag && br_u(b, 1))
      sl_parse(b);
   q->amp_enabled_flag = (uint8_t)br_u(b, 1);
   q->sample_adaptive_offset_enabled_flag = (uint8_t)br_u(b, 1);
   q->pcm_enabled_flag = (uint8_t)br_u(b, 1);
   if (q->pcm_enabled_flag) {
      q->pcm_sample_bit_depth_luma_minus1 = (uint8_t)br_u(b, 4);
      q->pcm_sample_bit_depth_chroma_minus1 = (uint8_t)br_u(b, 4);
      q->log2_min_pcm_luma_coding_block_size_minus3 = (uint8_t)br_ue(b);
      q->log2_diff_max_min_pcm_luma_coding_block_size = (uint8_t)br_ue(b);
      q->pcm_loop_filter_disabled_flag = (uint8_t)br_u(b, 1);
   }
   num_sets = br_ue(b);
   if (num_sets > 64)
      return -1;
   q->num_short_term_ref_pic_sets = (uint8_t)num_sets;
   for (unsigned i = 0; i < num_sets; i++)
      if (rps_parse(b, i, num_sets, sets, &sets[i]))
         return -1;
   q->long_term_ref_pics_present_flag = (uint8_t)br_u(b, 1);
   if (q->long_term_ref_pics_present_flag) {
      q->num_long_term_ref_pics_sps = (uint8_t)br_ue(b);
      for (unsigned i = 0; i < q->num_long_term_ref_pics_sps && !b->err; i++)
         br_u(b, lsb_bits + 1);
   }
   q->sps_temporal_mvp_enabled_flag = (uint8_t)br_u(b, 1);
   q->strong_intra_smoothing_enabled_flag = (uint8_t)br_u(b, 1);
   return b->err ? -1 : 0;
}

static int pps_parse(struct br *b)
{
   struct virgl_h265_pps *p = &hp;

   br_ue(b);
   br_ue(b);
   p->dependent_slice_segments_enabled_flag = (uint8_t)br_u(b, 1);
   p->output_flag_present_flag = (uint8_t)br_u(b, 1);
   p->num_extra_slice_header_bits = (uint8_t)br_u(b, 3);
   p->sign_data_hiding_enabled_flag = (uint8_t)br_u(b, 1);
   p->cabac_init_present_flag = (uint8_t)br_u(b, 1);
   p->num_ref_idx_l0_default_active_minus1 = (uint8_t)br_ue(b);
   p->num_ref_idx_l1_default_active_minus1 = (uint8_t)br_ue(b);
   p->init_qp_minus26 = (int8_t)br_se(b);
   p->constrained_intra_pred_flag = (uint8_t)br_u(b, 1);
   p->transform_skip_enabled_flag = (uint8_t)br_u(b, 1);
   p->cu_qp_delta_enabled_flag = (uint8_t)br_u(b, 1);
   if (p->cu_qp_delta_enabled_flag)
      p->diff_cu_qp_delta_depth = (uint8_t)br_ue(b);
   p->pps_cb_qp_offset = (int8_t)br_se(b);
   p->pps_cr_qp_offset = (int8_t)br_se(b);
   p->pps_slice_chroma_qp_offsets_present_flag = (uint8_t)br_u(b, 1);
   p->weighted_pred_flag = (uint8_t)br_u(b, 1);
   p->weighted_bipred_flag = (uint8_t)br_u(b, 1);
   p->transquant_bypass_enabled_flag = (uint8_t)br_u(b, 1);
   p->tiles_enabled_flag = (uint8_t)br_u(b, 1);
   p->entropy_coding_sync_enabled_flag = (uint8_t)br_u(b, 1);
   if (p->tiles_enabled_flag) {
      p->num_tile_columns_minus1 = (uint8_t)br_ue(b);
      p->num_tile_rows_minus1 = (uint8_t)br_ue(b);
      if (p->num_tile_columns_minus1 >= 20 || p->num_tile_rows_minus1 >= 22)
         return -1;
      p->uniform_spacing_flag = (uint8_t)br_u(b, 1);
      if (!p->uniform_spacing_flag) {
         for (unsigned i = 0; i < p->num_tile_columns_minus1; i++)
            p->column_width_minus1[i] = (uint16_t)br_ue(b);
         for (unsigned i = 0; i < p->num_tile_rows_minus1; i++)
            p->row_height_minus1[i] = (uint16_t)br_ue(b);
      }
      p->loop_filter_across_tiles_enabled_flag = (uint8_t)br_u(b, 1);
   }
   p->pps_loop_filter_across_slices_enabled_flag = (uint8_t)br_u(b, 1);
   p->deblocking_filter_control_present_flag = (uint8_t)br_u(b, 1);
   if (p->deblocking_filter_control_present_flag) {
      p->deblocking_filter_override_enabled_flag = (uint8_t)br_u(b, 1);
      p->pps_deblocking_filter_disabled_flag = (uint8_t)br_u(b, 1);
      if (!p->pps_deblocking_filter_disabled_flag) {
         p->pps_beta_offset_div2 = (int8_t)br_se(b);
         p->pps_tc_offset_div2 = (int8_t)br_se(b);
      }
   }
   if (br_u(b, 1))                      /* pps_scaling_list_data_present_flag */
      sl_parse(b);
   p->lists_modification_present_flag = (uint8_t)br_u(b, 1);
   p->log2_parallel_merge_level_minus2 = (uint8_t)br_ue(b);
   p->slice_segment_header_extension_present_flag = (uint8_t)br_u(b, 1);
   return b->err ? -1 : 0;
}

struct hslice {
   unsigned type, slice_type, poc_lsb, k;       /* k: the SPS set it picks */
   int first, idr, sps_flag, list_mod;          /* list_mod: list modification syntax */
   size_t sps_flag_pos, rps_end, end, data;     /* bits; data: byte where slice data starts */
   unsigned st_rps_bits;
   struct rps rps;
};

/* slice_segment_header() of an RBSP that starts with the NAL unit header */
static int slice_parse(const uint8_t *r, size_t n, struct hslice *s)
{
   const struct virgl_h265_pps *p = &hp;
   const struct virgl_h265_sps *q = &hp.sps;
   struct br b = { r, n, 16, 0 };
   unsigned chroma = q->separate_colour_plane_flag ? 0 : q->chroma_format_idc;
   unsigned ctb = q->log2_min_luma_coding_block_size_minus3 + 3u +
                  q->log2_diff_max_min_luma_coding_block_size;
   int dependent = 0, sao_l = 0, sao_c = 0, tmvp = 0;
   int deblock_off = p->pps_deblocking_filter_disabled_flag;

   memset(s, 0, sizeof(*s));
   s->type = (r[0] >> 1) & 63;
   s->idr = s->type == 19 || s->type == 20;
   s->first = (int)br_u(&b, 1);
   if (s->type >= 16 && s->type <= 23)
      br_u(&b, 1);
   br_ue(&b);
   if (!s->first) {
      if (p->dependent_slice_segments_enabled_flag)
         dependent = (int)br_u(&b, 1);
      br_u(&b, bits_for(((q->pic_width_in_luma_samples + (1u << ctb) - 1) >> ctb) *
                        ((q->pic_height_in_luma_samples + (1u << ctb) - 1) >> ctb)));
   }
   if (!dependent) {
      br_u(&b, p->num_extra_slice_header_bits);
      s->slice_type = br_ue(&b);
      if (p->output_flag_present_flag)
         br_u(&b, 1);
      if (q->separate_colour_plane_flag)
         br_u(&b, 2);
      if (!s->idr) {
         s->poc_lsb = br_u(&b, lsb_bits);
         s->sps_flag_pos = b.pos;
         s->sps_flag = (int)br_u(&b, 1);
         if (!s->sps_flag) {
            size_t start = b.pos;
            if (rps_parse(&b, num_sets, num_sets, sets, &s->rps))
               return -1;
            s->st_rps_bits = (unsigned)(b.pos - start);
         } else {
            s->k = num_sets > 1 ? br_u(&b, bits_for(num_sets)) : 0;
            if (s->k >= num_sets)
               return -1;
            s->rps = sets[s->k];
         }
         s->rps_end = b.pos;
         if (q->long_term_ref_pics_present_flag)
            return -1;                  /* not written by VideoToolbox; not handled here */
         if (q->sps_temporal_mvp_enabled_flag)
            tmvp = (int)br_u(&b, 1);
      }
      if (q->sample_adaptive_offset_enabled_flag) {
         sao_l = (int)br_u(&b, 1);
         if (chroma)
            sao_c = (int)br_u(&b, 1);
      }
      if (s->slice_type < 2) {          /* B or P */
         unsigned l0 = p->num_ref_idx_l0_default_active_minus1;
         unsigned l1 = p->num_ref_idx_l1_default_active_minus1, total = 0;
         int b_slice = s->slice_type == 0, col_l0 = 1;
         for (unsigned i = 0; i < s->rps.neg + s->rps.pos; i++)
            total += s->rps.used[i];
         if (br_u(&b, 1)) {
            l0 = br_ue(&b);
            if (b_slice)
               l1 = br_ue(&b);
         }
         if (l0 > 14 || l1 > 14)
            return -1;
         if (p->lists_modification_present_flag && total > 1) {
            s->list_mod = 1;
            if (br_u(&b, 1))
               for (unsigned i = 0; i <= l0; i++)
                  br_u(&b, bits_for(total));
            if (b_slice && br_u(&b, 1))
               for (unsigned i = 0; i <= l1; i++)
                  br_u(&b, bits_for(total));
         }
         if (b_slice)
            br_u(&b, 1);
         if (p->cabac_init_present_flag)
            br_u(&b, 1);
         if (tmvp) {
            if (b_slice)
               col_l0 = (int)br_u(&b, 1);
            if ((col_l0 && l0) || (!col_l0 && l1))
               br_ue(&b);
         }
         if ((p->weighted_pred_flag && !b_slice) || (p->weighted_bipred_flag && b_slice)) {
            br_ue(&b);
            if (chroma)
               br_se(&b);
            for (unsigned list = 0; list < (b_slice ? 2u : 1u); list++) {
               unsigned cnt = (list ? l1 : l0) + 1;
               uint8_t lf[16], cf[16];
               for (unsigned i = 0; i < cnt; i++)
                  lf[i] = (uint8_t)br_u(&b, 1);
               for (unsigned i = 0; i < cnt; i++)
                  cf[i] = chroma ? (uint8_t)br_u(&b, 1) : 0;
               for (unsigned i = 0; i < cnt; i++) {
                  if (lf[i]) {
                     br_se(&b);
                     br_se(&b);
                  }
                  for (int j = 0; cf[i] && j < 4; j++)
                     br_se(&b);
               }
            }
         }
         br_ue(&b);                     /* five_minus_max_num_merge_cand */
      }
      br_se(&b);                        /* slice_qp_delta */
      if (p->pps_slice_chroma_qp_offsets_present_flag) {
         br_se(&b);
         br_se(&b);
      }
      if (p->deblocking_filter_override_enabled_flag && br_u(&b, 1)) {
         deblock_off = (int)br_u(&b, 1);
         if (!deblock_off) {
            br_se(&b);
            br_se(&b);
         }
      }
      if (p->pps_loop_filter_across_slices_enabled_flag && (sao_l || sao_c || !deblock_off))
         br_u(&b, 1);
   }
   if (p->tiles_enabled_flag || p->entropy_coding_sync_enabled_flag) {
      unsigned cnt = br_ue(&b);
      if (cnt) {
         unsigned len = br_ue(&b) + 1;
         for (unsigned i = 0; i < cnt && !b.err; i++)
            br_u(&b, len);
      }
   }
   if (p->slice_segment_header_extension_present_flag) {
      unsigned cnt = br_ue(&b);
      for (unsigned i = 0; i < cnt && !b.err; i++)
         br_u(&b, 8);
   }
   s->end = b.pos;
   if (br_u(&b, 1) != 1)
      return -1;
   while (b.pos & 7)
      if (br_u(&b, 1))
         return -1;
   s->data = b.pos / 8;
   return b.err ? -1 : 0;
}

/* The slice with its SPS-picked set written as a set predicted from that SPS set
 * (delta -1), *st_bits its size. 0 when the slice picks no set or it can't be. */
static int slice_inter_rps(const uint8_t *r, size_t n, const struct hslice *s,
                           uint8_t **out, size_t *out_size, unsigned *st_bits)
{
   const struct rps *t;
   uint8_t used[33] = { 0 }, use_delta[33] = { 0 };
   struct rps got;
   unsigned nd;

   if (s->idr || !s->sps_flag || !num_sets)
      return 0;
   t = &sets[s->k];
   nd = t->neg + t->pos;
   for (unsigned j = 0; j <= nd; j++) {
      int d = (j < nd ? t->delta[j] : 0) - 1;
      for (unsigned i = 0; i < nd; i++)
         if (t->delta[i] == d) {
            used[j] = t->used[i];
            use_delta[j] = 1;
         }
   }
   rps_derive(t, -1, used, use_delta, &got);
   if (got.neg != t->neg || got.pos != t->pos ||
       memcmp(got.delta, t->delta, nd * sizeof(int)) || memcmp(got.used, t->used, nd))
      return 0;

   struct bw w = { calloc(1, n + 64), 0 };
   bw_copy(&w, r, 0, s->sps_flag_pos);
   bw_u(&w, 1, 0);                      /* short_term_ref_pic_set_sps_flag */
   size_t start = w.pos;
   bw_u(&w, 1, 1);                      /* inter_ref_pic_set_prediction_flag */
   bw_ue(&w, num_sets - 1 - s->k);      /* delta_idx_minus1 */
   bw_u(&w, 1, 1);                      /* delta_rps_sign */
   bw_ue(&w, 0);                        /* abs_delta_rps_minus1 */
   for (unsigned j = 0; j <= nd; j++) {
      bw_u(&w, 1, used[j]);
      if (!used[j])
         bw_u(&w, 1, use_delta[j]);
   }
   *st_bits = (unsigned)(w.pos - start);
   bw_copy(&w, r, s->rps_end, s->end);
   bw_u(&w, 1, 1);
   while (w.pos & 7)
      bw_u(&w, 1, 0);
   memcpy(w.d + w.pos / 8, r + s->data, n - s->data);
   put_rbsp(out, out_size, w.d, w.pos / 8 + n - s->data);
   free(w.d);
   return 1;
}

#endif
