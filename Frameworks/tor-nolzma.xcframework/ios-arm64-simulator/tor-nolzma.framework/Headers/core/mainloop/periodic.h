/* Copyright (c) 2015-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file periodic.h
 * @brief Header for periodic.c
 **/

#ifndef TOR_PERIODIC_H
#define TOR_PERIODIC_H

#define PERIODIC_EVENT_NO_UPDATE (-1)

/* Tor roles for which a periodic event item is for. An event can be for
 * multiple roles, they can be combined. */
#define PERIODIC_EVENT_ROLE_CLIENT      (1U << 0)
#define PERIODIC_EVENT_ROLE_RELAY       (1U << 1)
#define PERIODIC_EVENT_ROLE_BRIDGE      (1U << 2)
#define PERIODIC_EVENT_ROLE_DIRAUTH     (1U << 3)
#define PERIODIC_EVENT_ROLE_BRIDGEAUTH  (1U << 4)
#define PERIODIC_EVENT_ROLE_HS_SERVICE  (1U << 5)
#define PERIODIC_EVENT_ROLE_DIRSERVER   (1U << 6)
#define PERIODIC_EVENT_ROLE_CONTROLEV   (1U << 7)

#define PERIODIC_EVENT_ROLE_NET_PARTICIPANT (1U << 8)
#define PERIODIC_EVENT_ROLE_ALL         (1U << 9)

/* Helper macro to make it a bit less annoying to defined groups of roles that
 * are often used. */

/* Router that is a Bridge or Relay. */
#define PERIODIC_EVENT_ROLE_ROUTER \
  (PERIODIC_EVENT_ROLE_BRIDGE | PERIODIC_EVENT_ROLE_RELAY)
/* Authorities that is both bridge and directory. */
#define PERIODIC_EVENT_ROLE_AUTHORITIES \
  (PERIODIC_EVENT_ROLE_BRIDGEAUTH | PERIODIC_EVENT_ROLE_DIRAUTH)

/*
 * Event flags which can change the behavior of an event.
 */

/* Indicate that the event needs the network meaning that if we are in
 * DisableNetwork or hibernation mode, the event won't be enabled. This obey
 * the net_is_disabled() check. */
#define PERIODIC_EVENT_FLAG_NEED_NET  (1U << 0)

/* Indicate that if the event is enabled, it needs to be run once before
 * it becomes disabled.
 */
#define PERIODIC_EVENT_FLAG_RUN_ON_DISABLE  (1U << 1)

/** Callback function for a periodic event to take action.  The return value
* influences the next time the function will get called.  Return
* PERIODIC_EVENT_NO_UPDATE to not update <b>last_action_time</b> and be polled
* again in the next second. If a positive value is returned it will update the
* interval time. */
typedef int (*periodic_event_helper_t)(time_t now,
                                      const or_options_t *options);

struct mainloop_event_t;

/** A single item for the periodic-events-function table. */
typedef struct periodic_event_item_t {
  periodic_event_helper_t fn; /**< The function to run the event */
  time_t last_action_time; /**< The last time the function did something */
  struct mainloop_event_t *ev; /**< Libevent callback we're using to implement
                                * this */
  const char *name; /**< Name of the function -- for debug */

  /* Bitmask of roles define above for which this event applies. */
  uint32_t roles;
  /* Bitmask of flags which can change the behavior of the event. */
  uint32_t flags;
  /* Indicate that this event has been enabled that is scheduled. */
  unsigned int enabled : 1;
} periodic_event_item_t;

/** events will get their interval from first execution */
#ifndef COCCI
#define PERIODIC_EVENT(fn, r, f) { fn##_callback, 0, NULL, #fn, r, f, 0 }
#define END_OF_PERIODIC_EVENTS { NULL, 0, NULL, NULL, 0, 0, 0 }
#endif

/* Return true iff the given event was setup before thus is enabled to be
 * scheduled. */
static inline int
periodic_event_is_enabled(const periodic_event_item_t *item)
{
  return item->enabled;
}

void periodic_event_launch(periodic_event_item_t *event);
void periodic_event_connect(periodic_event_item_t *event);
//void periodic_event_disconnect(periodic_event_item_t *event);
void periodic_event_reschedule(periodic_event_item_t *event);
void periodic_event_enable(periodic_event_item_t *event);
void periodic_event_disable(periodic_event_item_t *event);
void periodic_event_schedule_and_disable(periodic_event_item_t *event);

void periodic_events_register(periodic_event_item_t *item);
void periodic_events_connect_all(void);
void periodic_events_reset_all(void);
periodic_event_item_t *periodic_events_find(const char *name);
void periodic_events_rescan_by_roles(int roles, bool net_disabled);
void periodic_events_disconnect_all(void);

int safe_timer_diff(time_t now, time_t next);

#endif /* !defined(TOR_PERIODIC_H) */
