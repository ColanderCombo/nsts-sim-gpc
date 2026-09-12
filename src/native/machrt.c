//
// Mach thread scheduling policies for simulator processes.
//
// THREAD_TIME_CONSTRAINT_POLICY enters the realtime band.  Extended and
// precedence policies provide fixed-priority timesharing.  Latency policies
// select timer-coalescing tiers.  Non-Mach entry points return -1.
//

#include <node_api.h>
#include <string.h>

#ifdef __APPLE__
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <mach/thread_act.h>
#include <mach/task.h>
#include <mach/task_policy.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <libproc.h>
#include <unistd.h>
#include <sys/proc_info.h>

static mach_timebase_info_data_t tb;

static uint32_t us_to_abs(double us) {
  if (tb.denom == 0) mach_timebase_info(&tb);
  double ns = us * 1000.0;
  return (uint32_t)(ns * (double)tb.denom / (double)tb.numer);
}

static double abs_to_us(uint32_t a) {
  if (tb.denom == 0) mach_timebase_info(&tb);
  return (double)a * (double)tb.numer / (double)tb.denom / 1000.0;
}
#endif

#define DECLARE(name) \
  static napi_value name(napi_env env, napi_callback_info info)

// Setters return kern_return_t; zero is success.
static napi_value kr_result(napi_env env, int kr) {
  napi_value v;
  napi_create_int32(env, kr, &v);
  return v;
}

static double arg_number(napi_env env, napi_value v, double dflt) {
  double d;
  if (napi_get_value_double(env, v, &d) != napi_ok) return dflt;
  return d;
}

static double opt_number(napi_env env, napi_value obj, const char *key, double dflt) {
  napi_value v;
  bool has = false;
  if (napi_has_named_property(env, obj, key, &has) != napi_ok || !has) return dflt;
  if (napi_get_named_property(env, obj, key, &v) != napi_ok) return dflt;
  return arg_number(env, v, dflt);
}

static int opt_bool(napi_env env, napi_value obj, const char *key, int dflt) {
  napi_value v;
  bool has = false, b = false;
  if (napi_has_named_property(env, obj, key, &has) != napi_ok || !has) return dflt;
  if (napi_get_named_property(env, obj, key, &v) != napi_ok) return dflt;
  if (napi_get_value_bool(env, v, &b) != napi_ok) return dflt;
  return b ? 1 : 0;
}

static void set_num(napi_env env, napi_value obj, const char *key, double val) {
  napi_value v;
  napi_create_double(env, val, &v);
  napi_set_named_property(env, obj, key, v);
}

static void set_bool(napi_env env, napi_value obj, const char *key, int val) {
  napi_value v;
  napi_get_boolean(env, val ? true : false, &v);
  napi_set_named_property(env, obj, key, v);
}

// setRealtime({periodUs, computationUs, constraintUs, preemptible})
// The kernel failsafe demotes a thread that exceeds `computation`.
DECLARE(SetRealtime) {
#ifdef __APPLE__
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);

  double period = 1000.0, computation = 500.0, constraint = 1000.0;
  int preemptible = 1;
  if (argc >= 1) {
    napi_valuetype t;
    napi_typeof(env, argv[0], &t);
    if (t == napi_object) {
      period      = opt_number(env, argv[0], "periodUs", period);
      computation = opt_number(env, argv[0], "computationUs", computation);
      constraint  = opt_number(env, argv[0], "constraintUs", constraint);
      preemptible = opt_bool(env, argv[0], "preemptible", preemptible);
    }
  }

  thread_time_constraint_policy_data_t p;
  p.period      = us_to_abs(period);
  p.computation = us_to_abs(computation);
  p.constraint  = us_to_abs(constraint);
  p.preemptible = preemptible;

  mach_port_t th = mach_thread_self();
  kern_return_t kr = thread_policy_set(th, THREAD_TIME_CONSTRAINT_POLICY,
                                       (thread_policy_t)&p,
                                       THREAD_TIME_CONSTRAINT_POLICY_COUNT);
  mach_port_deallocate(mach_task_self(), th);
  return kr_result(env, kr);
#else
  (void)info;
  return kr_result(env, -1);
#endif
}

// setTimeshare(false) fixes the thread's priority; true restores decay.
DECLARE(SetTimeshare) {
#ifdef __APPLE__
  size_t argc = 1;
  napi_value argv[1];
  bool on = true;
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  if (argc >= 1) napi_get_value_bool(env, argv[0], &on);

  thread_extended_policy_data_t p;
  p.timeshare = on ? TRUE : FALSE;
  mach_port_t th = mach_thread_self();
  kern_return_t kr = thread_policy_set(th, THREAD_EXTENDED_POLICY,
                                       (thread_policy_t)&p,
                                       THREAD_EXTENDED_POLICY_COUNT);
  mach_port_deallocate(mach_task_self(), th);
  return kr_result(env, kr);
#else
  (void)info;
  return kr_result(env, -1);
#endif
}

// setPrecedence(importance): the thread's offset above its base priority.
DECLARE(SetPrecedence) {
#ifdef __APPLE__
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);

  thread_precedence_policy_data_t p;
  p.importance = (integer_t)(argc >= 1 ? arg_number(env, argv[0], 0) : 0);
  mach_port_t th = mach_thread_self();
  kern_return_t kr = thread_policy_set(th, THREAD_PRECEDENCE_POLICY,
                                       (thread_policy_t)&p,
                                       THREAD_PRECEDENCE_POLICY_COUNT);
  mach_port_deallocate(mach_task_self(), th);
  return kr_result(env, kr);
#else
  (void)info;
  return kr_result(env, -1);
#endif
}

// mach/task_policy.h encodes tiers above zero with tagged high words.
#ifdef __APPLE__
static integer_t latency_tier(double n) {
  int t = (int)n;
  return t <= 0 ? LATENCY_QOS_TIER_UNSPECIFIED : (integer_t)((0xFF << 16) | (t + 1));
}

static integer_t throughput_tier(double n) {
  int t = (int)n;
  return t <= 0 ? THROUGHPUT_QOS_TIER_UNSPECIFIED : (integer_t)((0xFE << 16) | (t + 1));
}
#endif

// Tier 1 is 1 ms, tier 2 is 5 ms, tier 3 is 20 ms, tier 4 is 75 ms, tier 5
// is 10 s; tier 0 uses the priority-band default.
DECLARE(SetLatencyQos) {
#ifdef __APPLE__
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);

  thread_latency_qos_policy_data_t p;
  p.thread_latency_qos_tier = latency_tier(argc >= 1 ? arg_number(env, argv[0], 0) : 0);
  mach_port_t th = mach_thread_self();
  kern_return_t kr = thread_policy_set(th, THREAD_LATENCY_QOS_POLICY,
                                       (thread_policy_t)&p,
                                       THREAD_LATENCY_QOS_POLICY_COUNT);
  mach_port_deallocate(mach_task_self(), th);
  return kr_result(env, kr);
#else
  (void)info;
  return kr_result(env, -1);
#endif
}

DECLARE(SetThroughputQos) {
#ifdef __APPLE__
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);

  thread_throughput_qos_policy_data_t p;
  p.thread_throughput_qos_tier = throughput_tier(argc >= 1 ? arg_number(env, argv[0], 0) : 0);
  mach_port_t th = mach_thread_self();
  kern_return_t kr = thread_policy_set(th, THREAD_THROUGHPUT_QOS_POLICY,
                                       (thread_policy_t)&p,
                                       THREAD_THROUGHPUT_QOS_POLICY_COUNT);
  mach_port_deallocate(mach_task_self(), th);
  return kr_result(env, kr);
#else
  (void)info;
  return kr_result(env, -1);
#endif
}

// Task-wide counterparts to the thread latency and throughput policies.
DECLARE(SetTaskLatencyQos) {
#ifdef __APPLE__
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);

  struct task_qos_policy p;
  p.task_latency_qos_tier = latency_tier(argc >= 1 ? arg_number(env, argv[0], 0) : 0);
  p.task_throughput_qos_tier = THROUGHPUT_QOS_TIER_UNSPECIFIED;
  kern_return_t kr = task_policy_set(mach_task_self(), TASK_BASE_LATENCY_QOS_POLICY,
                                     (task_policy_t)&p, TASK_QOS_POLICY_COUNT);
  return kr_result(env, kr);
#else
  (void)info;
  return kr_result(env, -1);
#endif
}

DECLARE(SetTaskThroughputQos) {
#ifdef __APPLE__
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);

  struct task_qos_policy p;
  p.task_latency_qos_tier = LATENCY_QOS_TIER_UNSPECIFIED;
  p.task_throughput_qos_tier = throughput_tier(argc >= 1 ? arg_number(env, argv[0], 0) : 0);
  kern_return_t kr = task_policy_set(mach_task_self(), TASK_BASE_THROUGHPUT_QOS_POLICY,
                                     (task_policy_t)&p, TASK_QOS_POLICY_COUNT);
  return kr_result(env, kr);
#else
  (void)info;
  return kr_result(env, -1);
#endif
}

// setQosClass(class, relativePriority): 0x21 user-interactive, 0x19
// user-initiated, 0x15 default, 0x11 utility, 0x09 background.  The two
// lowest run on the efficiency cores.
DECLARE(SetQosClass) {
#ifdef __APPLE__
  size_t argc = 2;
  napi_value argv[2];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  qos_class_t cls = (qos_class_t)(argc >= 1 ? arg_number(env, argv[0], QOS_CLASS_USER_INTERACTIVE)
                                            : QOS_CLASS_USER_INTERACTIVE);
  int rel = (int)(argc >= 2 ? arg_number(env, argv[1], 0) : 0);
  return kr_result(env, pthread_set_qos_class_self_np(cls, rel));
#else
  (void)info;
  return kr_result(env, -1);
#endif
}

// A demoted realtime thread retains its constraint but reports curPri below 97.
DECLARE(Info) {
  (void)info;
  napi_value out;
  napi_create_object(env, &out);
#ifdef __APPLE__
  mach_port_t th = mach_thread_self();

  thread_time_constraint_policy_data_t tc;
  mach_msg_type_number_t cnt = THREAD_TIME_CONSTRAINT_POLICY_COUNT;
  boolean_t dflt = FALSE;
  if (thread_policy_get(th, THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&tc,
                        &cnt, &dflt) == KERN_SUCCESS) {
    set_num(env, out, "periodUs", abs_to_us(tc.period));
    set_num(env, out, "computationUs", abs_to_us(tc.computation));
    set_num(env, out, "constraintUs", abs_to_us(tc.constraint));
    set_bool(env, out, "preemptible", tc.preemptible);
    set_bool(env, out, "timeConstraintDefault", dflt);
  }

  thread_extended_policy_data_t ex;
  cnt = THREAD_EXTENDED_POLICY_COUNT;
  dflt = FALSE;
  if (thread_policy_get(th, THREAD_EXTENDED_POLICY, (thread_policy_t)&ex,
                        &cnt, &dflt) == KERN_SUCCESS)
    set_bool(env, out, "timeshare", ex.timeshare);

  thread_latency_qos_policy_data_t lq;
  cnt = THREAD_LATENCY_QOS_POLICY_COUNT;
  dflt = FALSE;
  if (thread_policy_get(th, THREAD_LATENCY_QOS_POLICY, (thread_policy_t)&lq,
                        &cnt, &dflt) == KERN_SUCCESS)
    set_num(env, out, "latencyQosTier", lq.thread_latency_qos_tier);

  mach_port_deallocate(mach_task_self(), th);

  qos_class_t cls = QOS_CLASS_UNSPECIFIED;
  int rel = 0;
  if (pthread_get_qos_class_np(pthread_self(), &cls, &rel) == 0) {
    set_num(env, out, "qosClass", (double)cls);
    set_num(env, out, "qosRelative", (double)rel);
  }

  uint64_t tid = 0;
  struct proc_threadinfo pti;
  if (pthread_threadid_np(NULL, &tid) == 0 &&
      proc_pidinfo(getpid(), PROC_PIDTHREADID64INFO, tid, &pti, sizeof(pti)) == sizeof(pti)) {
    set_num(env, out, "curPri", pti.pth_curpri);
    set_num(env, out, "basePri", pti.pth_priority);
    set_num(env, out, "maxPri", pti.pth_maxpriority);
    set_num(env, out, "runState", pti.pth_run_state);
  }
  set_bool(env, out, "available", 1);
#else
  set_bool(env, out, "available", 0);
#endif
  return out;
}

static napi_value Init(napi_env env, napi_value exports) {
  struct { const char *name; napi_callback fn; } fns[] = {
    { "setRealtime",      SetRealtime },
    { "setTimeshare",     SetTimeshare },
    { "setPrecedence",    SetPrecedence },
    { "setLatencyQos",    SetLatencyQos },
    { "setThroughputQos", SetThroughputQos },
    { "setQosClass",      SetQosClass },
    { "setTaskLatencyQos",    SetTaskLatencyQos },
    { "setTaskThroughputQos", SetTaskThroughputQos },
    { "info",             Info },
  };
  for (unsigned i = 0; i < sizeof(fns) / sizeof(fns[0]); i++) {
    napi_value f;
    napi_create_function(env, fns[i].name, NAPI_AUTO_LENGTH, fns[i].fn, NULL, &f);
    napi_set_named_property(env, exports, fns[i].name, f);
  }
  return exports;
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
