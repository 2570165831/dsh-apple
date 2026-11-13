//
//  ISHGuestDieTest.m
//  DSHPortC
//
//  Fault injection: make the guest kernel call die() on a real guest task, so
//  the acceptance test can prove the replacement handler contains it instead of
//  the app dying.
//
//  Why this is not just `die("test")` from an arbitrary thread: the handler
//  parks whichever thread calls it. Called from the app's own serial queue that
//  would wedge every later command. Called from a thread that already owns a
//  guest task, it parks only a thread whose process was going to die anyway —
//  which is what happens in real life when the kernel faults inside a guest
//  process.
//
//  The path is genuine: this is the same die() in kernel/log.c that
//  kernel/task.c reaches from "task_thread returned". Nothing here is a
//  test-only kernel build.
//

#if DEBUG
#import "ISHGuest.h"

#include <pthread.h>
#include <stdlib.h>

#ifndef ISH_INTERNAL
#define ISH_INTERNAL 1
#endif

#include "kernel/init.h"
#include "kernel/calls.h"
#include "kernel/task.h"

// The kernel's own die(); declared rather than included so the deliberate call
// site is unambiguous about which function it invokes.
void die(const char *msg, ...);

// Defined in ISHGuest.m next to the handler they observe.
extern volatile int dsh_die_handler_call_count;
extern char dsh_die_handler_last_message[1024];

struct die_test_args {
    struct task *task;
};

static void *die_test_thread(void *raw) {
    struct die_test_args *args = raw;
    struct task *task = args->task;
    free(args);

    // A guest task is only meaningful to the kernel through the thread-local
    // `current` pointer, which is set by whichever thread runs the task. This
    // thread is that thread.
    current = task;

    die("dshportc acceptance test: deliberate kernel die()");
    // Unreachable with a correct handler: the handler must not return. Reaching
    // the line below means containment failed and log.c went on to abort().
    return NULL;
}

void dsh_trigger_die_on_guest_task(void) {
    struct task *savedCurrent = current;
    int err = become_new_init_child();
    if (err < 0) {
        current = savedCurrent;
        NSLog(@"dshportc: die test could not create a guest task: %d", err);
        return;
    }
    struct task *task = current;
    current = savedCurrent;

    struct die_test_args *args = calloc(1, sizeof(*args));
    if (args == NULL) {
        NSLog(@"dshportc: die test could not allocate its argument");
        return;
    }
    args->task = task;

    pthread_t thread;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    // Detached: the thread parks forever inside the die handler and nothing
    // will ever join it.
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    int createErr = pthread_create(&thread, &attr, die_test_thread, args);
    pthread_attr_destroy(&attr);
    if (createErr != 0) {
        free(args);
        NSLog(@"dshportc: die test could not start its thread: %d", createErr);
    }
}
#endif
