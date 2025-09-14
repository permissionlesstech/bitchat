/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file pubsub_macros.h
 * \brief Macros to help with the publish/subscribe dispatch API.
 *
 * The dispatch API allows different subsystems of Tor to communicate with
 * another asynchronously via a shared "message" system.  Some subsystems
 * declare that they publish a given message, and others declare that they
 * subscribe to it.  Both subsystems depend on the message, but not upon one
 * another.
 *
 * To declare a message, use DECLARE_MESSAGE() (for messages that take their
 * data as a pointer) or DECLARE_MESSAGE_INT() (for messages that take their
 * data as an integer.  For example, you might say
 *
 *     DECLARE_MESSAGE(new_circuit, circ, circuit_handle_t *);
 * or
 *     DECLARE_MESSAGE_INT(shutdown_requested, boolean, bool);
 *
 * Every message has a unique name, a "type name" that the dispatch system
 * uses to manage associated data, and a C type name.  You'll want to put
 * these declarations in a header, to be included by all publishers and all
 * subscribers.
 *
 * When a subsystem wants to publish a message, it uses DECLARE_PUBLISH() at
 * file scope to create necessary static functions.  Then, in its subsystem
 * initialization (in the "bind to dispatcher" callback) (TODO: name this
 * properly!), it calls DISPATCH_ADD_PUB() to tell the dispatcher about its
 * intent to publish.  When it actually wants to publish, it uses the
 * PUBLISH() macro.  For example:
 *
 *     // At file scope
 *     DECLARE_PUBLISH(shutdown_requested);
 *
 *     static void bind_to_dispatcher(pubsub_connector_t *con)
 *     {
 *         DISPATCH_ADD_PUB(con, mainchannel, shutdown_requested);
 *     }
 *
 *     // somewhere in a function
 *        {
 *            PUBLISH(shutdown_requested, true);
 *        }
 *
 * When a subsystem wants to subscribe to a message, it uses
 * DECLARE_SUBSCRIBE() at file scope to declare static functions.  It must
 * declare a hook function that receives the message type.  Then, in its "bind
 * to dispatcher" function, it calls DISPATCHER_ADD_SUB() to tell the
 * dispatcher about its intent to subscribe.  When another module publishes
 * the message, the dispatcher will call the provided hook function.
 *
 *     // At file scope.  The first argument is the message that you're
 *     // subscribing to; the second argument is the hook function to declare.
 *     DECLARE_SUBSCRIBE(shutdown_requested, on_shutdown_req_cb);
 *
 *     // You need to declare this function.
 *     static void on_shutdown_req_cb(const msg_t *msg,
 *                                    bool value)
 *     {
 *         // (do something here.)
 *     }
 *
 *     static void bind_to_dispatcher(pubsub_connector_t *con)
 *     {
 *         DISPATCH_ADD_SUB(con, mainchannel, shutdown_requested);
 *     }
 *
 * Where did these types come from?  Somewhere in the code, you need to call
 * DISPATCH_REGISTER_TYPE() to make sure that the dispatcher can manage the
 * message auxiliary data.  It associates a vtbl-like structure with the
 * type name, so that the dispatcher knows how to manipulate the type you're
 * giving it.
 *
 * For example, the "boolean" type we're using above could be defined as:
 *
 *    static char *boolean_fmt(msg_aux_data_t d)
 *    {
 *        // This is used for debugging and dumping messages.
 *        if (d.u64)
 *            return tor_strdup("true");
 *        else
 *            return tor_strdup("false");
 *    }
 *
 *    static void boolean_free(msg_aux_data_t d)
 *    {
 *        // We don't actually need to do anything to free a boolean.
 *        // We could use "NULL" instead of this function, but I'm including
 *        // it as an example.
 *    }
 *
 *    static void bind_to_dispatcher(pubsub_connector_t *con)
 *    {
 *        dispatch_typefns_t boolean_fns = {
 *            .fmt_fn = boolean_fmt,
 *            .free_fn = boolean_free,
 *        };
 *        DISPATCH_REGISTER_TYPE(con, boolean, &boolean_fns);
 *    }
 *
 *
 *
 * So, how does this all work?  (You can stop reading here, unless you're
 * debugging something.)
 *
 * When you declare a message in a header with DECLARE_MESSAGE() or
 * DECLARE_MESSAGE_INT(), it creates five things:
 *
 *    * two typedefs for the message argument (constant and non-constant
 *      variants).
 *    * a constant string to hold the declared message type name
 *    * two inline functions, to coerce the message argument type to and from
 *      a "msg_aux_data_t" union.
 *
 * All of these declarations have names based on the message name.
 *
 * Later, when you say DECLARE_PUBLISH() or DECLARE_SUBSCRIBE(), we use the
 * elements defined by DECLARE_MESSAGE() to make sure that the publish
 * function takes the correct argument type, and that the subscription hook is
 * declared with the right argument type.
 **/

#ifndef TOR_DISPATCH_MSG_H
#define TOR_DISPATCH_MSG_H

#include "lib/cc/compat_compiler.h"
#include "lib/dispatch/dispatch_naming.h"
#include "lib/pubsub/pub_binding_st.h"
#include "lib/pubsub/pubsub_connect.h"
#include "lib/pubsub/pubsub_flags.h"
#include "lib/pubsub/pubsub_publish.h"

/* Implementation notes:
 *
 * For a messagename "foo", the DECLARE_MESSAGE*() macros must declare:
 *
 * msg_arg_type__foo -- a typedef for the argument type of the foo message.
 * msg_arg_consttype__foo -- a typedef for the const argument type of the
 *     foo message.
 * msg_arg_name__foo[] -- a static string constant holding the unique
 *      identifier for the type of the foo message.
 * msg_arg_get__foo() -- an inline function taking a msg_aux_data_t and
 *      returning the C data type.
 * msg_arg_set__foo() -- an inline function taking a msg_aux_data_t and
 *      the C type, setting the msg_aux_data_t to hold the C type.
 *
 * For a messagename "foo", the DECLARE_PUBLISH() macro must declare:
 *
 * pub_binding__foo -- A static pub_binding_t object used to send messages
 *      from this module.
 * publish_fn__foo -- A function taking an argument of the appropriate
 *      C type, to be invoked by PUBLISH().
 *
 * For a messagename "foo", the DECLARE_SUBSCRIBE() macro must declare:
 *
 * hookfn -- A user-provided function name, with the correct signature.
 * recv_fn__foo -- A wrapper callback that takes a msg_t *, and calls
 *      hookfn with the appropriate arguments.
 */

/** Macro to declare common elements shared by DECLARE_MESSAGE and
 * DECLARE_MESSAGE_INT.  Don't call this directly.
 *
 * Note that the "msg_arg_name" string constant is defined in each
 * translation unit.  This might be undesirable; we can tweak it in the
 * future if need be.
 */
#define DECLARE_MESSAGE_COMMON__(messagename, typename, c_type)         \
  typedef c_type msg_arg_type__ ##messagename;                          \
  typedef const c_type msg_arg_consttype__ ##messagename;               \
  ATTR_UNUSED static const char msg_arg_name__ ##messagename[] = # typename;

/**
 * Use this macro in a header to declare the existence of a given message,
 * taking a pointer as auxiliary data.
 *
 * "messagename" is a unique identifier for the message; it must be a valid
 * C identifier.
 *
 * "typename" is a unique identifier for the type of the auxiliary data.
 * It needs to be defined somewhere in Tor, using
 * "DISPATCH_REGISTER_TYPE."
 *
 * "c_ptr_type" is a C pointer type (like "char *" or "struct foo *").
 * The "*" needs to be included.
 */
#define DECLARE_MESSAGE(messagename, typename, c_ptr_type)              \
  DECLARE_MESSAGE_COMMON__(messagename, typename, c_ptr_type)           \
  ATTR_UNUSED static inline c_ptr_type                                  \
  msg_arg_get__ ##messagename(msg_aux_data_t m)                         \
  {                                                                     \
    return m.ptr;                                                       \
  }                                                                     \
  ATTR_UNUSED static inline void                                        \
  msg_arg_set__ ##messagename(msg_aux_data_t *m, c_ptr_type v)          \
  {                                                                     \
    m->ptr = v;                                                         \
  }                                                                     \
  EAT_SEMICOLON

/**
 * Use this macro in a header to declare the existence of a given message,
 * taking an integer as auxiliary data.
 *
 * "messagename" is a unique identifier for the message; it must be a valid
 * C identifier.
 *
 * "typename" is a unique identifier for the type of the auxiliary data.  It
 * needs to be defined somewhere in Tor, using "DISPATCH_REGISTER_TYPE."
 *
 * "c_type" is a C integer type, like "int" or "bool".  It needs to fit inside
 * a uint64_t.
 */
#define DECLARE_MESSAGE_INT(messagename, typename, c_type)              \
  DECLARE_MESSAGE_COMMON__(messagename, typename, c_type)               \
  ATTR_UNUSED static inline c_type                                      \
  msg_arg_get__ ##messagename(msg_aux_data_t m)                         \
  {                                                                     \
    return (c_type)m.u64;                                               \
  }                                                                     \
  ATTR_UNUSED static inline void                                        \
  msg_arg_set__ ##messagename(msg_aux_data_t *m, c_type v)              \
  {                                                                     \
    m->u64 = (uint64_t)v;                                               \
  }                                                                     \
  EAT_SEMICOLON

/**
 * Use this macro inside a C module declare that we'll be publishing a given
 * message type from within this module.
 *
 * It creates necessary functions and wrappers to publish a message whose
 * unique identifier is "messagename".
 *
 * Before you use this, you need to include the header where DECLARE_MESSAGE*()
 * was used for this message.
 *
 * You can only use this once per message in each subsystem.
 */
#define DECLARE_PUBLISH(messagename)                                    \
  static pub_binding_t pub_binding__ ##messagename;                     \
  static void                                                           \
  publish_fn__ ##messagename(msg_arg_type__ ##messagename arg)          \
  {                                                                     \
    msg_aux_data_t data;                                                \
    msg_arg_set__ ##messagename(&data, arg);                            \
    pubsub_pub_(&pub_binding__ ##messagename, data);                    \
  }                                                                     \
  EAT_SEMICOLON

/**
 * Use this macro inside a C file to declare that we're subscribing to a
 * given message and associating it with a given "hook function".  It
 * declares the hook function static, and helps with strong typing.
 *
 * Before you use this, you need to include the header where
 * DECLARE_MESSAGE*() was used for the message whose unique identifier is
 * "messagename".
 *
 * You will need to define a function with the name that you provide for
 * "hookfn".  The type of this function will be:
 *     static void hookfn(const msg_t *, const c_type)
 * where c_type is the c type that you declared in the header.
 *
 * You can only use this once per message in each subsystem.
 */
#define DECLARE_SUBSCRIBE(messagename, hookfn) \
  static void hookfn(const msg_t *,                             \
                     const msg_arg_consttype__ ##messagename);  \
  static void recv_fn__ ## messagename(const msg_t *m)          \
  {                                                             \
    msg_arg_type__ ## messagename arg;                          \
    arg = msg_arg_get__ ##messagename(m->aux_data__);           \
    hookfn(m, arg);                                             \
  }                                                             \
  EAT_SEMICOLON

/**
 * Add a fake use of the publish function for 'messagename', so that
 * the compiler does not call it unused.
 */
#define DISPATCH__FAKE_USE_OF_PUBFN_(messagename)                       \
  ( 0 ? (publish_fn__ ##messagename((msg_arg_type__##messagename)0), 1) \
    : 1)

/**
 * This macro is for internal use.  It backs DISPATCH_ADD_PUB*()
 */
#define DISPATCH_ADD_PUB_(connector, channel, messagename, flags)       \
  (                                                                     \
    DISPATCH__FAKE_USE_OF_PUBFN_(messagename),                          \
    pubsub_add_pub_((connector),                                        \
                      &pub_binding__ ##messagename,                     \
                      get_channel_id(# channel),                        \
                    get_message_id(# messagename),                      \
                      get_msg_type_id(msg_arg_name__ ## messagename),   \
                      (flags),                                          \
                      __FILE__,                                         \
                      __LINE__)                                         \
    )

/**
 * Use a given connector and channel name to declare that this subsystem will
 * publish a given message type.
 *
 * Call this macro from within the add_subscriptions() function of a module.
 */
#define DISPATCH_ADD_PUB(connector, channel, messagename)       \
    DISPATCH_ADD_PUB_(connector, channel, messagename, 0)

/**
 * Use a given connector and channel name to declare that this subsystem will
 * publish a given message type, and that no other subsystem is allowed to.
 *
 * Call this macro from within the add_subscriptions() function of a module.
 */
#define DISPATCH_ADD_PUB_EXCL(connector, channel, messagename)  \
    DISPATCH_ADD_PUB_(connector, channel, messagename, DISP_FLAG_EXCL)

/**
 * This macro is for internal use. It backs DISPATCH_ADD_SUB*()
 */
#define DISPATCH_ADD_SUB_(connector, channel, messagename, flags)       \
  pubsub_add_sub_((connector),                                          \
                    recv_fn__ ##messagename,                            \
                    get_channel_id(#channel),                           \
                    get_message_id(# messagename),                      \
                    get_msg_type_id(msg_arg_name__ ##messagename),      \
                    (flags),                                            \
                    __FILE__,                                           \
                    __LINE__)
/**
 * Use a given connector and channel name to declare that this subsystem will
 * receive a given message type.
 *
 * Call this macro from within the add_subscriptions() function of a module.
 */
#define DISPATCH_ADD_SUB(connector, channel, messagename)       \
    DISPATCH_ADD_SUB_(connector, channel, messagename, 0)
/**
 * Use a given connector and channel name to declare that this subsystem will
 * receive a given message type, and that no other subsystem is allowed to do
 * so.
 *
 * Call this macro from within the add_subscriptions() function of a module.
 */
#define DISPATCH_ADD_SUB_EXCL(connector, channel, messagename)  \
    DISPATCH_ADD_SUB_(connector, channel, messagename, DISP_FLAG_EXCL)

/**
 * Publish a given message with a given argument.  (Takes ownership of the
 * argument if it is a pointer.)
 */
#define PUBLISH(messagename, arg)               \
  publish_fn__ ##messagename(arg)

/**
 * Use a given connector to declare that the functions to be used to manipuate
 * a certain C type.
 **/
#define DISPATCH_REGISTER_TYPE(con, type, fns)                  \
  pubsub_connector_register_type_((con),                        \
                                  get_msg_type_id(#type),       \
                                  (fns),                        \
                                  __FILE__,                     \
                                  __LINE__)

#endif /* !defined(TOR_DISPATCH_MSG_H) */
