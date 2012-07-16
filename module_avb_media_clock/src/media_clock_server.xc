#include <xs1.h>
#include <xclib.h>
#include "print.h"

#include "avb_1722_def.h"
#include "media_clock_client.h"
#include "media_clock_server.h"
#include "media_clock_internal.h"
#include "media_output_fifo.h"
#include "simple_printf.h"
#include "avb_media_clock_def.h"
#include "gptp.h"
#include "avb_control_types.h"

#define DEBUG_MEDIA_CLOCK

#define STABLE_THRESHOLD 32
#define LOCK_COUNT_THRESHOLD 400
#define ACCEPTABLE_FILL_ADJUST 50000
#define LOST_LOCK_THRESHOLD 24
#define MIN_FILL_LEVEL 5
#define MAX_SAMPLES_PER_1722_PACKET 12

static media_clock_t media_clocks[AVB_NUM_MEDIA_CLOCKS];

typedef struct buf_info_t {
  int lock_count;
  int prev_diff;
  int stability_count;
  int instability_count;
  int media_clock;
  int fifo;
  int adjust;
} buf_info_t;


void update_stream_derived_clocks(int source_num,
                                  unsigned int local_ts,
                                  unsigned int ptp_outgoing_actual,
                                  unsigned int presentation_timestamp,
                                  int locked,
                                  int fill)
{
  for (int i=0;i<AVB_NUM_MEDIA_CLOCKS;i++) {
    if (media_clocks[i].active &&
        (media_clocks[i].clock_type == MEDIA_FIFO_DERIVED ||
         media_clocks[i].clock_type == FIFO_LENGTH)&&
        media_clocks[i].source == source_num) 
      {
        update_media_clock_stream_info(i, 
                                       local_ts,
                                       ptp_outgoing_actual,
                                       presentation_timestamp,
                                       locked,
                                       fill);
      }
  }
  return;
}


void inform_media_clocks_of_lock(int source_num) 
{
 for (int i=0;i<AVB_NUM_MEDIA_CLOCKS;i++) {
    if (media_clocks[i].active &&
        media_clocks[i].clock_type == MEDIA_FIFO_DERIVED &&
        media_clocks[i].source == source_num) 
      {
        inform_media_clock_of_lock(i);
      }
 }
}

#if (AVB_NUM_MEDIA_OUTPUTS != 0)
static buf_info_t buf_info[AVB_NUM_MEDIA_OUTPUTS];



static void init_buffers(void) 
{
  for (int i=0;i<AVB_NUM_MEDIA_OUTPUTS;i++) {
    buf_info[i].adjust = 0;
  }
}

int get_buf_info(int fifo)
{
  int stream_num = -1;
  for (int i=0;i<AVB_NUM_MEDIA_OUTPUTS;i++) 
    if (buf_info[i].fifo == fifo) 
      stream_num = i;
 
  return stream_num;
}

#pragma unsafe arrays
static void manage_buffer(buf_info_t &b,
                          chanend ?ptp_svr,
                          chanend buf_ctl,
                          int index,
                          timer tmr)
{
  unsigned outgoing_timestamp_local;
  unsigned presentation_timestamp;
  int locked;
  ptp_time_info_mod64 timeInfo;
  unsigned int ptp_outgoing_actual;
  int diff, sample_diff;
  unsigned int wordLength;
  int rdptr,wrptr,fill;
  int thiscore_now,othercore_now;
  unsigned server_core_id;

  if (b.media_clock == -1) {
      buf_ctl <: b.fifo;
      buf_ctl <: BUF_CTL_ACK;
      inct(buf_ctl);  
      return;
  }

  wordLength = media_clocks[b.media_clock].wordLength;

  buf_ctl <: b.fifo;
  buf_ctl <: BUF_CTL_REQUEST_INFO;
  master {
    buf_ctl <: 0;
    buf_ctl :> othercore_now;
    tmr :> thiscore_now;
    buf_ctl :> locked;
    buf_ctl :> presentation_timestamp;    
    buf_ctl :> outgoing_timestamp_local;
    buf_ctl :> rdptr;
    buf_ctl :> wrptr;
    buf_ctl :> server_core_id;
  }
  if (server_core_id != get_core_id())
  {
	  outgoing_timestamp_local = outgoing_timestamp_local - (othercore_now - thiscore_now);
  }
  outgoing_timestamp_local += b.adjust;

  fill = wrptr - rdptr;

  if (fill < 0)
    fill += MEDIA_OUTPUT_FIFO_WORD_SIZE;


  ptp_get_time_info_mod64(ptp_svr, timeInfo);

  ptp_outgoing_actual = local_timestamp_to_ptp_mod32(outgoing_timestamp_local,
                                                     timeInfo);
                                                            
  diff = (signed) ptp_outgoing_actual - (signed) presentation_timestamp;

  update_stream_derived_clocks(index,
                               outgoing_timestamp_local,
                               ptp_outgoing_actual,
                               presentation_timestamp,
                               locked,
                               fill);
 

  if (wordLength == 0) {
      // clock not locked yet
      buf_ctl <: b.fifo;
      buf_ctl <: BUF_CTL_ACK;
      inct(buf_ctl);  
      return;     
  }

  if (media_clocks[b.media_clock].clock_type == FIFO_LENGTH) {
	  if (b.lock_count == 0) {
	        buf_ctl <: b.fifo;
	        buf_ctl <: BUF_CTL_ADJUST_FILL;
	        buf_ctl <: 0;
	        inct(buf_ctl);
	        b.lock_count = 1;
	  } else {
	      buf_ctl <: b.fifo;
	      buf_ctl <: BUF_CTL_ACK;
	      inct(buf_ctl);
	  }
	  return;
  }

  sample_diff = diff / ((int) ((wordLength*10) >> WC_FRACTIONAL_BITS));

  if (locked && b.lock_count < LOCK_COUNT_THRESHOLD) {   
    b.lock_count++;
  }

  if (sample_diff < ACCEPTABLE_FILL_ADJUST &&
      sample_diff > -ACCEPTABLE_FILL_ADJUST &&
      (sample_diff - b.prev_diff <= 1 &&
       sample_diff - b.prev_diff >= -1)) {
    b.stability_count++;
  } else {
    b.stability_count = 0;
  }

  if (!locked && (b.stability_count > STABLE_THRESHOLD)) {
      if (fill - sample_diff > MEDIA_OUTPUT_FIFO_WORD_SIZE-MAX_SAMPLES_PER_1722_PACKET) {
#ifdef DEBUG_MEDIA_CLOCK
    	simple_printf("Media output %d compensation too large: %d samples\n", index, sample_diff);
#endif
        b.adjust = 0;
        buf_ctl <: b.fifo;
        buf_ctl <: BUF_CTL_RESET;
        inct(buf_ctl);
      } else {
#ifdef DEBUG_MEDIA_CLOCK
        simple_printf("Media output %d locked: %d samples shorter\n", index, sample_diff);
#endif
        inform_media_clocks_of_lock(index);
        b.lock_count = 0;
        buf_ctl <: b.fifo;
        buf_ctl <: BUF_CTL_ADJUST_FILL;
        buf_ctl <: sample_diff;
        inct(buf_ctl);
      }
  } else if (locked &&
           b.lock_count == LOCK_COUNT_THRESHOLD &&
           (sample_diff > LOST_LOCK_THRESHOLD ||
            sample_diff < -LOST_LOCK_THRESHOLD ||
            fill < MIN_FILL_LEVEL))
  {
#ifdef DEBUG_MEDIA_CLOCK
      simple_printf("Media output %d lost lock\n", index);
#endif
      b.adjust = 0;
      buf_ctl <: b.fifo;
      buf_ctl <: BUF_CTL_RESET;
      inct(buf_ctl);  
  } else {
      buf_ctl <: b.fifo;
      buf_ctl <: BUF_CTL_ACK;
      inct(buf_ctl);  
  }

  b.prev_diff = sample_diff;
}
 

#endif // (AVB_NUM_MEDIA_OUTPUTS != 0)

#define PLL_TO_WORD_MULTIPLIER 100
#define INITIAL_MEDIA_CLOCK_OUTPUT_DELAY 100000
#define EVENT_AFTER_PORT_OUTPUT_DELAY 100

#define INTERNAL_CLOCK_DIVIDE 25

static void update_media_clock_divide(media_clock_t &clk)
{
  clk.divWordLength = clk.wordLength * INTERNAL_CLOCK_DIVIDE;
  clk.baseLength = clk.divWordLength >> (WC_FRACTIONAL_BITS+1);
}

static void init_media_clock(media_clock_t &clk,
                             timer tmr,
                             out port p) {
  int ptime, time;
  clk.active = 0;
  clk.count = 0;
  clk.wordLength = 0x8235556;
  update_media_clock_divide(clk);
  clk.lowBits = 0;
  clk.prevLowBits = 0;
  clk.bit = 0;
  p <: 0 @ ptime;
  tmr :> time;
  clk.wordTime = ptime + INITIAL_MEDIA_CLOCK_OUTPUT_DELAY;
  clk.next_event =
    time +
    INITIAL_MEDIA_CLOCK_OUTPUT_DELAY +
    EVENT_AFTER_PORT_OUTPUT_DELAY;
}


static void do_media_clock_output(media_clock_t &clk,
                                  out port p)
{
  const unsigned int bitMask = (1 << WC_FRACTIONAL_BITS) - 1;
  const unsigned mult = PLL_TO_WORD_MULTIPLIER/(2*INTERNAL_CLOCK_DIVIDE);

  clk.count++;
  if (clk.count==mult) {
    clk.bit = ~clk.bit;
    clk.count = 0;
  }

  clk.wordTime += clk.baseLength;
  clk.next_event += clk.baseLength;

  if (clk.bit) {
    clk.lowBits = (clk.lowBits + clk.divWordLength) & bitMask;
    if (clk.lowBits <  clk.prevLowBits) {
      clk.wordTime += 1;
      clk.next_event += 1;
    }
    clk.prevLowBits = clk.lowBits;
  }

  p @ clk.wordTime <: clk.bit;

}

static void update_media_clocks(chanend ptp_svr, int clk_time)
{
  for (int i=0;i<AVB_NUM_MEDIA_CLOCKS;i++) {
    if (media_clocks[i].active) {
      media_clocks[i].wordLength =
        update_media_clock(ptp_svr,
                           i,
                           media_clocks[i],
                           clk_time,
                           CLOCK_RECOVERY_PERIOD);

      update_media_clock_divide(media_clocks[i]);
    }
  }
}


int mcount=0;


void media_clock_server(chanend media_clock_ctl,
                        chanend ?ptp_svr,
                        chanend ?buf_ctl[],
                        int num_buf_ctl,
                        out port p_fs[])
{
  unsigned int clk_time;
  int num_clks = AVB_NUM_MEDIA_CLOCKS;
  int registered[MAX_CLK_CTL_CLIENTS];
#if (AVB_NUM_MEDIA_OUTPUTS != 0)
  unsigned char buf_ctl_cmd;
#endif
  timer clk_timers[AVB_NUM_MEDIA_CLOCKS];


#if (AVB_NUM_MEDIA_OUTPUTS != 0)
  init_buffers();

  for (int i=0;i<AVB_NUM_MEDIA_OUTPUTS;i++) {
    media_clock_ctl :> buf_info[i].fifo;
  }
#endif

  for (int i=0;i<MAX_CLK_CTL_CLIENTS;i++) 
    registered[i] = -1;

  clk_timers[0] :> clk_time;

  clk_time += CLOCK_RECOVERY_PERIOD;

  for (int i=0;i<AVB_NUM_MEDIA_CLOCKS;i++)
    init_media_clock(media_clocks[i], clk_timers[0], p_fs[i]);

  while (1) {
    #pragma ordered
    select 
      {
      case (int i=0;i<num_clks;i++)
        clk_timers[i] when timerafter(media_clocks[i].next_event) :> int now:
        if ((now - (signed) media_clocks[i].next_event) > media_clocks[i].baseLength) {
          printintln(now - (signed) media_clocks[i].next_event);
          printstrln("-------");
          asm("ecallf %0"::"r"(0));
        }
        mcount++;
        do_media_clock_output(media_clocks[i], p_fs[i]);

        if (timeafter(clk_time, now))
          {
            update_media_clocks(ptp_svr, clk_time);
            clk_time += CLOCK_RECOVERY_PERIOD;
          }
        break;

#if (AVB_NUM_MEDIA_OUTPUTS != 0)
      case (int i=0;i<num_buf_ctl;i++) inuchar_byref(buf_ctl[i], buf_ctl_cmd): 
        {
          int fifo, buf_index;
          unsigned x;
          x = inuchar(buf_ctl[i]);
          fifo = x<<8;
          x = inuchar(buf_ctl[i]);
          fifo = fifo + x;
          fifo |= 0x10000;
          (void) inct(buf_ctl[i]);

          buf_index = get_buf_info(fifo);
          switch (buf_ctl_cmd)
            {
            case BUF_CTL_GOT_INFO:
              manage_buffer(buf_info[buf_index], ptp_svr, buf_ctl[i],
                            buf_index, clk_timers[0]);
              break;
            case BUF_CTL_NEW_STREAM:
              buf_ctl[i] <: buf_info[buf_index].fifo;
              buf_ctl[i] <: BUF_CTL_REQUEST_NEW_STREAM_INFO;
              master {
                buf_ctl[i] :> buf_info[buf_index].media_clock;
              }
              (void) inct(buf_ctl[i]);
              break;
            default:
              break;
            }

          break;
        }
#endif
      case media_clock_ctl :> int cmd:         
        switch (cmd) 
          {
          case MEDIA_CLOCK_REGISTER:
            { int i;
              int clock_num;
              slave {
                media_clock_ctl :> i;              
                media_clock_ctl :> clock_num;
              }
              registered[i] = clock_num;
            }
            break;
          case MEDIA_CLOCK_SET_STATE:
            { int state;
              int clock_num;
              slave {
                media_clock_ctl :> clock_num;
                media_clock_ctl :> state;              
              }
              if (state == DEVICE_MEDIA_CLOCK_STATE_ENABLED) {
                init_media_clock_recovery(ptp_svr, 
                                          clock_num, 
                                          clk_time - CLOCK_RECOVERY_PERIOD,
                                          media_clocks[clock_num].rate);
                media_clocks[clock_num].active = 1;
              }
              else {
                media_clocks[clock_num].active = 0;
              }
            }
            break;
          case MEDIA_CLOCK_GET_STATE:
            { int media_clock_num;
              slave {
                media_clock_ctl :> media_clock_num;              
                if (media_clocks[media_clock_num].active)
                  media_clock_ctl <: DEVICE_MEDIA_CLOCK_STATE_ENABLED;
                else
                  media_clock_ctl <: DEVICE_MEDIA_CLOCK_STATE_DISABLED;
              }
            }
            break;

          case MEDIA_CLOCK_SET_RATE:
            { int media_clock_num;
              int rate;
              slave {
              media_clock_ctl :> media_clock_num;
              media_clock_ctl :> rate;
              }            
            media_clocks[media_clock_num].rate = rate;
            }
            break;
          case MEDIA_CLOCK_GET_RATE:
            { int media_clock_num;
              slave {
                media_clock_ctl :> media_clock_num;              
                media_clock_ctl <: media_clocks[media_clock_num].rate;
              }
            }
            break;
          case MEDIA_CLOCK_SET_TYPE:
            { int media_clock_num;
              int type;
              slave {
                media_clock_ctl :> media_clock_num;
              media_clock_ctl :> type;
              }
              media_clocks[media_clock_num].clock_type = type;
            }
            break;
          case MEDIA_CLOCK_GET_TYPE:
            { int media_clock_num;
              slave {
                media_clock_ctl :> media_clock_num;              
                media_clock_ctl <: media_clocks[media_clock_num].clock_type;
              }
            }
            break;
          case MEDIA_CLOCK_SET_SOURCE:
            { int media_clock_num;
              int x;
              slave {
                media_clock_ctl :> media_clock_num;
                media_clock_ctl :> x;
              }
              media_clocks[media_clock_num].source = x;
            }

            break;
          case MEDIA_CLOCK_GET_SOURCE:
            { int media_clock_num;
              slave {
                media_clock_ctl :> media_clock_num;              
                media_clock_ctl <: media_clocks[media_clock_num].source;
              }
            }
            break;
          default:
            break;            
          }
        break;

      }
  }
}
