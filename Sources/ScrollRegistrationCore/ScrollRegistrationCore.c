#include "ScrollRegistrationCore.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <float.h>

typedef struct { int offset, valid, bad; float score; } Candidate;
static int compare(const void *a, const void *b) {
    const Candidate *x=a,*y=b;
    if(x->score!=y->score) return x->score<y->score?-1:1;
    /* Original tie order is unknown. Prefer smaller absolute motion deterministically. */
    if(abs(x->offset)!=abs(y->offset))return abs(x->offset)<abs(y->offset)?-1:1;
    return (x->offset>y->offset)-(x->offset<y->offset);
}
/* Horizontal INTER_AREA equivalent: vertical dimension is deliberately unchanged. */
static void area(const uint8_t *src,uint8_t *dst,int sw,int dw,int h) {
    if(sw==dw){memcpy(dst,src,(size_t)sw*h);return;}
    double scale=(double)sw/dw;
    for(int y=0;y<h;y++)for(int x=0;x<dw;x++){
        double left=x*scale,right=(x+1)*scale,sum=0;
        for(int sx=(int)left;sx<(int)ceil(right);sx++){
            double weight=fmin(right,sx+1)-fmax(left,sx);
            if(sx<sw&&weight>0)sum+=src[(size_t)y*sw+sx]*weight;
        }
        dst[(size_t)y*dw+x]=(uint8_t)lrint(sum/scale);
    }
}
/* INTER_LINEAR on the ROI. Same coordinate centres as OpenCV; 8-bit rounding can differ by 1. */
static void linear(const uint8_t *src,uint8_t *dst,int sw,int dw,int h,int mask) {
    for(int y=0;y<h;y++)for(int x=0;x<dw;x++){
        double sx=((double)x+0.5)*sw/dw-0.5;
        if(sx<0)sx=0;if(sx>sw-1)sx=sw-1;
        int lo=(int)sx,hi=lo+1<sw?lo+1:lo;
        double fraction=sx-lo;
        int value=(int)lrint(src[(size_t)y*sw+lo]*(1-fraction)+src[(size_t)y*sw+hi]*fraction);
        dst[(size_t)y*dw+x]=mask?(value>10?255:0):(uint8_t)value;
    }
}
SevenScrollMatch seven_scroll_match(const uint8_t *old,const uint8_t *next,int width,int height){
    SevenScrollMatch result={.status=3,.score=FLT_MAX};
    if(!old||!next||width<1||height<2)return result;
    const int w=width>512?512:width;
    size_t count=(size_t)w*height;
    uint8_t *a=malloc(count),*b=malloc(count),*mask=calloc(count,1);
    uint8_t *ra=NULL,*rb=NULL,*rm=NULL,*sa=NULL,*sb=NULL,*sm=NULL;
    Candidate *candidates=NULL;
    if(!a||!b||!mask)goto cleanup;
    area(old,a,width,w,height);area(next,b,width,w,height);
    int x0=w,y0=height,x1=-1,y1=-1;
    for(int y=0;y<height;y++)for(int x=0;x<w;x++){
        size_t i=(size_t)y*w+x;
        if(abs((int)a[i]-(int)b[i])>10){mask[i]=255;if(x<x0)x0=x;if(x>x1)x1=x;if(y<y0)y0=y;if(y>y1)y1=y;}
    }
    int rw=x1>=x0?x1-x0+1:0,rh=y1>=y0?y1-y0+1:0;
    result.roi_x=x0;result.roi_y=y0;result.roi_width=rw;result.roi_height=rh;
    if((double)rw*rh<(double)w*height*0.3){result.status=0;result.score=0;result.offset=0;goto cleanup;}
    if(rh<2){result.status=2;goto cleanup;}
    size_t roi=(size_t)rw*rh;
    ra=malloc(roi);rb=malloc(roi);rm=malloc(roi);sa=malloc(roi);sb=malloc(roi);sm=malloc(roi);
    candidates=malloc((size_t)(rh+1)*sizeof(Candidate));
    if(!ra||!rb||!rm||!sa||!sb||!sm||!candidates)goto cleanup;
    for(int y=0;y<rh;y++){
        memcpy(ra+(size_t)y*rw,a+(size_t)(y+y0)*w+x0,rw);
        memcpy(rb+(size_t)y*rw,b+(size_t)(y+y0)*w+x0,rw);
        memcpy(rm+(size_t)y*rw,mask+(size_t)(y+y0)*w+x0,rw);
    }
    int n=0;
    for(int d=-(rh/2);d<=rh/2;d++)if(d)candidates[n++]=(Candidate){.offset=d,.score=FLT_MAX};
    result.candidates=n;
    int stage=rw/32;if(stage<1)stage=1;
    for(;;){
        linear(ra,sa,rw,stage,rh,0);linear(rb,sb,rw,stage,rh,0);linear(rm,sm,rw,stage,rh,1);
        for(int i=0;i<n;i++){
            int d=candidates[i].offset,start=d<0?-d:0,rows=rh-abs(d),valid=0,bad=0;
            for(int y=0;y<rows;y++){
                size_t ia=(size_t)(start+y)*stage,ib=(size_t)(start+y+d)*stage;
                for(int x=0;x<stage;x++)if(sm[ia+x]|sm[ib+x]){
                    valid++;if(abs((int)sa[ia+x]-(int)sb[ib+x])>10)bad++;
                }
            }
            candidates[i].valid=valid;candidates[i].bad=bad;
            candidates[i].score=valid?(float)bad/(float)valid:FLT_MAX;
        }
        qsort(candidates,n,sizeof(Candidate),compare);
        int survivors=n/2;if(survivors<1)survivors=1;
        result.history[result.stages]=(SevenScrollStage){stage,n,survivors,candidates[0].offset,candidates[0].score,candidates[survivors-1].score};
        result.stages++;result.offset=candidates[0].offset;result.score=candidates[0].score;
        result.valid_pixels=candidates[0].valid;result.bad_pixels=candidates[0].bad;
        n=survivors;
        if(stage==rw)break;
        stage=stage*2<rw?stage*2:rw;
    }
    result.status=result.score<0.3f?1:2;
cleanup:
    free(a);free(b);free(mask);free(ra);free(rb);free(rm);free(sa);free(sb);free(sm);free(candidates);
    return result;
}

void seven_scroll_reduce(const uint8_t *source,uint8_t *destination,int width,int target_width,int height) {
    if(source && destination && width>0 && target_width>0 && target_width<=width && height>0)
        area(source,destination,width,target_width,height);
}
