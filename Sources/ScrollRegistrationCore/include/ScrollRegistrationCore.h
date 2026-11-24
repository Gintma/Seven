#ifndef SEVEN_SCROLL_REGISTRATION_H
#define SEVEN_SCROLL_REGISTRATION_H
#include <stdint.h>
typedef struct {
    int width, candidates, survivors, best_offset;
    float best_score, cutoff_score;
} SevenScrollStage;
typedef struct {
    int status; /* 0 small change, 1 matched, 2 rejected, 3 allocation failure */
    int offset, roi_x, roi_y, roi_width, roi_height;
    int candidates, stages, valid_pixels, bad_pixels;
    float score;
    SevenScrollStage history[10]; /* <=7 stages for a <=512-wide ROI */
} SevenScrollMatch;
/* Match grayscale frames and report the vertical offset and match quality. */
SevenScrollMatch seven_scroll_match(const uint8_t *old_gray, const uint8_t *new_gray, int width, int height);
/* Bounded grayscale reference snapshots; same area reduction as the matcher. */
void seven_scroll_reduce(const uint8_t *source, uint8_t *destination, int width, int target_width, int height);
#endif
